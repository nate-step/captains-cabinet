#!/usr/bin/env python3
"""
Cabinet MCP server — Phase 2 CP2 expansion.

Exposes inter-Cabinet tools for the Phase 2 Cabinet Suite (Work + Personal
Cabinets linked via this MCP). Phase 1 shipped identify() as a de-risk
prototype; Phase 2 adds presence(), availability(), send_message(), and
request_handoff(). Transport stays stdio; tool signatures are HTTP-ready
for Phase 3 Federation.

Tools by capacity:

    identify          — any capacity            (identity self-query)
    presence          — any capacity            (liveness of a peer Cabinet)
    availability      — any capacity            (calendar busy windows)
    send_message      — any capacity            (content crosses Cabinets; enforced by peers.yml + trust policy)
    request_handoff   — any capacity            (transfer a context to another Cabinet)

Phase-3-forward: Personal-capacity Cabinets refuse any tool marked
`federation_allowed=False` once Federation tools are introduced (they
don't exist yet — Phase 3 is intent-only per cabinet-v2.md Part 5).
The guard is in place today so that infrastructure is never the
blocker.

Captain decision 2026-04-16 CD5: stdio for prototype; HTTP-compatible.
Captain authorization 2026-04-17: autonomous Phase 2 build-out.
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

CABINET_ROOT = Path(os.environ.get("CABINET_ROOT", "/opt/founders-cabinet"))
MCP_SCOPE_PATH = CABINET_ROOT / "cabinet" / "mcp-scope.yml"
PRODUCT_YML = CABINET_ROOT / "instance" / "config" / "product.yml"
PLATFORM_YML = CABINET_ROOT / "instance" / "config" / "platform.yml"
PEERS_YML = CABINET_ROOT / "instance" / "config" / "peers.yml"
CALENDAR_YML = CABINET_ROOT / "instance" / "config" / "calendar.yml"

SERVER_NAME = "cabinet"
SERVER_VERSION = "0.2.0"  # bumped for Phase 2 tool expansion
PROTOCOL_VERSION = "2024-11-05"

# Redis connection — match the convention used by the rest of the repo
# (post-tool-use.sh, officer-supervisor.sh, list-officers.sh etc.)
REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = os.environ.get("REDIS_PORT", "6379")


# ---------------------------------------------------------------
# Config readers (PyYAML not available; regex-based stdlib substitutes)
# ---------------------------------------------------------------

def read_hired_agents() -> list[str]:
    """Parse mcp-scope.yml `agents:` section. Single source of truth per Phase 1 polish."""
    if not MCP_SCOPE_PATH.exists():
        return []
    agents: list[str] = []
    section = None
    for line in MCP_SCOPE_PATH.read_text().splitlines():
        if re.match(r"^(agents|scaffolds):\s*$", line):
            section = line.split(":", 1)[0]
            continue
        if re.match(r"^[A-Za-z]", line) and not re.match(
            r"^(agents|scaffolds):\s*$", line
        ):
            section = None
            continue
        if section == "agents" and re.match(r"^  [A-Za-z][A-Za-z0-9_-]*:\s*$", line):
            agents.append(line.strip().rstrip(":"))
    return agents


def read_simple_yaml_key(
    path: Path, key: str, default: str = "", section: str | None = None
) -> str:
    """Section-scoped flat-yaml key reader. See Phase 1 polish commit e1c63ea."""
    if not path.exists():
        return default
    in_section = section is None
    for line in path.read_text().splitlines():
        if section is not None and re.match(r"^[A-Za-z]", line):
            head = line.split(":", 1)[0].strip()
            in_section = head == section
            continue
        if not in_section:
            continue
        if section is None:
            m = re.match(rf"^{re.escape(key)}:\s*(.*)$", line)
        else:
            m = re.match(rf"^\s+{re.escape(key)}:\s*(.*)$", line)
        if m:
            return m.group(1).strip().strip("\"'")
    return default


def read_peers() -> list[dict[str, Any]]:
    """Read instance/config/peers.yml. Each peer dict carries keys:
    id, role, endpoint, capacity, trust_level, consented_by_captain,
    allowed_tools (list), optional peer_version / shared_secret_ref / notes.

    Parser matches load-preset.sh and pre-tool-use.sh §10 parser exactly:
    tracks `last_list_key` so yaml-list-continuation (`- item`) lines
    attach to whatever list key came above, not hardcoded to
    allowed_tools. This is the Phase 2 CP8-review fix — the server's
    parser was drifting from the loader's, which would have silently
    refused send_message/request_handoff the moment Captain flipped
    consent (list read as empty string, tool-in-list check fails)."""
    if not PEERS_YML.exists():
        return []
    peers: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    last_list_key: str | None = None
    for raw in PEERS_YML.read_text().splitlines():
        line = raw.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue
        if re.match(r"^peers:\s*$", line):
            continue
        m = re.match(r"^  ([A-Za-z][A-Za-z0-9_-]*):\s*$", line)
        if m:
            if current is not None:
                peers.append(current)
            current = {"id": m.group(1)}
            last_list_key = None
            continue
        if current is None:
            continue
        mk = re.match(r"^\s{4,}([a-z_]+):\s*(.*)$", line)
        if mk:
            key, val = mk.group(1), mk.group(2).strip().strip("\"'")
            if val.startswith("[") and val.endswith("]"):
                items = [x.strip() for x in val[1:-1].split(",") if x.strip()]
                current[key] = items
                last_list_key = key
            elif val.lower() in ("true", "false"):
                current[key] = val.lower() == "true"
                last_list_key = None
            elif val == "":
                # Empty value: either a list-will-follow or a folded-scalar
                current[key] = [] if key == "allowed_tools" else ""
                last_list_key = key if key == "allowed_tools" else None
            else:
                current[key] = val
                last_list_key = None
        elif last_list_key is not None:
            lm = re.match(r"^\s{4,}- (.+)$", line)
            if lm:
                item = lm.group(1).strip().strip("\"'")
                current.setdefault(last_list_key, [])
                if isinstance(current[last_list_key], list):
                    current[last_list_key].append(item)
    if current is not None:
        peers.append(current)
    return peers


# ---------------------------------------------------------------
# Identity / Capacity / Guards
# ---------------------------------------------------------------

def this_cabinet_id() -> str:
    return os.environ.get("CABINET_ID", "main")


def this_cabinet_capacity() -> str:
    """Return this Cabinet's capacity — defaults to work for backward compat.
    Reads from platform.yml `capacity:` key or $CABINET_CAPACITY env."""
    env = os.environ.get("CABINET_CAPACITY", "").strip()
    if env:
        return env
    return read_simple_yaml_key(PLATFORM_YML, "capacity", default="work")


def peer_by_id(peer_id: str) -> dict[str, Any] | None:
    for p in read_peers():
        if p.get("id") == peer_id:
            return p
    return None


# ---------------------------------------------------------------
# Tool handlers
# ---------------------------------------------------------------

def tool_identify(_params: dict) -> dict:
    """Self-identity query (Phase 1 shape, unchanged)."""
    captain_name = read_simple_yaml_key(PRODUCT_YML, "captain_name", section="product")
    return {
        "cabinet_id": this_cabinet_id(),
        "captain_id": os.environ.get("CAPTAIN_ID") or captain_name or "unknown",
        "capacity": this_cabinet_capacity(),
        "available_agents": read_hired_agents(),
        "server": {"name": SERVER_NAME, "version": SERVER_VERSION},
    }


def tool_presence(params: dict) -> dict:
    """Is a peer Cabinet online? Reads the Redis heartbeat key convention
    used elsewhere in the repo: `cabinet:heartbeat:<peer_id>`. Returns
    last-seen timestamp (ISO) or null. No network probe of the peer's
    actual endpoint until Phase 2 HTTP transport ships."""
    peer_id = params.get("peer_id", "")
    if not peer_id:
        return {"status": "error", "message": "peer_id required"}
    peer = peer_by_id(peer_id)
    if not peer:
        return {
            "status": "unknown_peer",
            "peer_id": peer_id,
            "this_cabinet_id": this_cabinet_id(),
            "known_peers": [p["id"] for p in read_peers()],
        }
    try:
        out = subprocess.run(
            ["redis-cli", "-h", REDIS_HOST, "-p", REDIS_PORT, "GET", f"cabinet:heartbeat:{peer_id}"],
            capture_output=True, text=True, timeout=2,
        )
        last_seen = out.stdout.strip()
        if last_seen and last_seen != "(nil)":
            return {"status": "online", "peer_id": peer_id, "last_seen": last_seen, "this_cabinet_id": this_cabinet_id()}
        return {"status": "offline", "peer_id": peer_id, "last_seen": None, "this_cabinet_id": this_cabinet_id()}
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return {"status": "unavailable", "peer_id": peer_id, "reason": "redis_unreachable", "this_cabinet_id": this_cabinet_id()}


def tool_availability(params: dict) -> dict:
    """Return Captain's busy windows in [start, end]. Reads
    instance/config/calendar.yml if present — Phase 2 defers calendar-source
    integration (Google Calendar, CalDAV, Apple Calendar) to Captain's CD_P3
    pick. Until then: returns `unavailable_no_source` OR reads a manual
    entries list from calendar.yml.

    Input schema: {start: ISO8601, end: ISO8601}
    Output: {status, busy: [{start, end, label?}] | null}
    """
    start = params.get("start", "")
    end = params.get("end", "")
    if not start or not end:
        return {"status": "error", "message": "start and end (ISO 8601) required"}

    if not CALENDAR_YML.exists():
        return {
            "status": "unavailable_no_source",
            "message": (
                "No calendar source configured. Populate instance/config/calendar.yml "
                "with a `source:` key (manual|google|caldav|apple) and source-specific "
                "config, OR add `manual_busy:` list of {start,end,label} entries."
            ),
        }

    # Minimal manual-source implementation: read calendar.yml `manual_busy:` entries.
    # Full source integrations (Google, CalDAV, Apple) are deferred pending CD_P3.
    busy: list[dict] = []
    text = CALENDAR_YML.read_text()
    in_manual = False
    entry: dict = {}
    for line in text.splitlines():
        if line.strip() == "manual_busy:":
            in_manual = True
            continue
        if re.match(r"^[A-Za-z]", line):
            in_manual = False
            continue
        if not in_manual:
            continue
        if line.strip().startswith("- "):
            if entry:
                busy.append(entry)
            entry = {}
            kv = line.strip()[2:]
            if ":" in kv:
                k, v = kv.split(":", 1)
                entry[k.strip()] = v.strip().strip("\"'")
        elif ":" in line:
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                k, v = stripped.split(":", 1)
                entry[k.strip()] = v.strip().strip("\"'")
    if entry:
        busy.append(entry)
    # Filter by window
    windowed = [b for b in busy if b.get("start", "") < end and b.get("end", "") > start]
    return {"status": "ok", "source": "manual", "busy": windowed}


def tool_send_message(params: dict) -> dict:
    """Queue an inter-Cabinet message. Phase 2 prototype: writes to a Redis
    stream `cabinet:inbox:<to_cabinet>` — the target Cabinet's consumer
    reads it the same way officers read Redis Channel triggers.

    Input schema: {to_cabinet, from_agent, content, [reply_to]}
    Output: {status, message_id}
    Enforcement: peers.yml consented_by_captain must be true AND 'send_message'
    must be in the target's allowed_tools; this is pre-tool-use hook territory
    (CP4). Server-side also double-checks consent here as defense-in-depth.
    """
    to_cabinet = params.get("to_cabinet", "")
    from_agent = params.get("from_agent", "")
    content = params.get("content", "")
    reply_to = params.get("reply_to")
    if not (to_cabinet and from_agent and content):
        return {"status": "error", "message": "to_cabinet, from_agent, content required"}
    peer = peer_by_id(to_cabinet)
    if not peer:
        return {"status": "unknown_peer", "peer_id": to_cabinet}
    if not peer.get("consented_by_captain"):
        return {"status": "refused", "reason": "peer_not_consented"}
    if "send_message" not in peer.get("allowed_tools", []):
        return {"status": "refused", "reason": "send_message_not_in_peer_allowed_tools"}

    try:
        out = subprocess.run(
            [
                "redis-cli", "-h", REDIS_HOST, "-p", REDIS_PORT,
                "XADD", f"cabinet:inbox:{to_cabinet}", "*",
                "from_cabinet", this_cabinet_id(),
                "from_agent", from_agent,
                "content", content,
                "reply_to", str(reply_to or ""),
                "ts", str(int(time.time())),
            ],
            capture_output=True, text=True, timeout=5,
        )
        msg_id = out.stdout.strip()
        if not msg_id or msg_id.startswith("(error"):
            return {"status": "error", "message": f"redis XADD failed: {out.stderr}"}
        sys.stderr.write(f"[cabinet-mcp] send_message queued to={to_cabinet} from={from_agent} msg_id={msg_id}\n")
        return {"status": "queued", "to_cabinet": to_cabinet, "message_id": msg_id}
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return {"status": "error", "message": f"redis unreachable: {e}"}


def tool_request_handoff(params: dict) -> dict:
    """Ask a peer Cabinet to accept ownership of a context. Use case:
    Captain's Work Cabinet notices a conversation has crossed into personal
    territory; it requests the Personal Cabinet take over. Same queue
    mechanic as send_message but with a structured reason + expectation
    that the peer's CoS routes it to the right coach.

    Input: {to_cabinet, context_slug, reason, [from_agent]}
    Output: {status, handoff_id}
    """
    to_cabinet = params.get("to_cabinet", "")
    context_slug = params.get("context_slug", "")
    reason = params.get("reason", "")
    from_agent = params.get("from_agent", "cos")
    if not (to_cabinet and context_slug and reason):
        return {"status": "error", "message": "to_cabinet, context_slug, reason required"}
    peer = peer_by_id(to_cabinet)
    if not peer:
        return {"status": "unknown_peer", "peer_id": to_cabinet}
    if not peer.get("consented_by_captain"):
        return {"status": "refused", "reason": "peer_not_consented"}
    if "request_handoff" not in peer.get("allowed_tools", []):
        return {"status": "refused", "reason": "request_handoff_not_in_peer_allowed_tools"}

    try:
        out = subprocess.run(
            [
                "redis-cli", "-h", REDIS_HOST, "-p", REDIS_PORT,
                "XADD", f"cabinet:inbox:{to_cabinet}", "*",
                "from_cabinet", this_cabinet_id(),
                "from_agent", from_agent,
                "kind", "handoff_request",
                "context_slug", context_slug,
                "reason", reason,
                "ts", str(int(time.time())),
            ],
            capture_output=True, text=True, timeout=5,
        )
        handoff_id = out.stdout.strip()
        sys.stderr.write(f"[cabinet-mcp] request_handoff queued to={to_cabinet} ctx={context_slug} id={handoff_id}\n")
        return {"status": "queued", "to_cabinet": to_cabinet, "handoff_id": handoff_id}
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        return {"status": "error", "message": f"redis unreachable: {e}"}


# ---------------------------------------------------------------
# Tool registry
# ---------------------------------------------------------------

# Each tool: name, description, inputSchema, handler, federation_allowed
# federation_allowed=False means personal-capacity Cabinets refuse the call
# once Federation tools are introduced (Phase 3). All Phase 2 tools are
# federation-safe because they're bilateral Cabinet-to-Cabinet only.

TOOLS: list[dict[str, Any]] = [
    {
        "name": "identify",
        "description": (
            "Return this Cabinet's identity: cabinet_id, captain_id, capacity, "
            "available_agents. Call shape is stable across Phase 1 (stdio) and "
            "Phase 2/3 (HTTP) — only the transport changes."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "handler": tool_identify,
        "federation_allowed": True,
    },
    {
        "name": "presence",
        "description": (
            "Is a peer Cabinet online? Returns last-seen timestamp via the "
            "Redis heartbeat key. Use before send_message to avoid queuing "
            "messages to a Cabinet that's been offline for hours."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"peer_id": {"type": "string"}},
            "required": ["peer_id"],
            "additionalProperties": False,
        },
        "handler": tool_presence,
        "federation_allowed": True,
    },
    {
        "name": "availability",
        "description": (
            "Return Captain's busy windows in a time range [start, end] (ISO 8601). "
            "Reads instance/config/calendar.yml — currently supports a manual_busy "
            "list; live calendar integrations (Google Calendar, CalDAV, Apple) are "
            "deferred pending Captain decision CD_P3. Returns status=unavailable_no_source "
            "when no calendar.yml is present."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "start": {"type": "string", "description": "ISO 8601"},
                "end": {"type": "string", "description": "ISO 8601"},
            },
            "required": ["start", "end"],
            "additionalProperties": False,
        },
        "handler": tool_availability,
        "federation_allowed": True,
    },
    {
        "name": "send_message",
        "description": (
            "Queue a message to a peer Cabinet's inbox (cabinet:inbox:<peer_id> Redis "
            "stream). Peer must be in peers.yml with consented_by_captain=true AND "
            "'send_message' in its allowed_tools list; otherwise the call is refused."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "to_cabinet": {"type": "string"},
                "from_agent": {"type": "string"},
                "content": {"type": "string"},
                "reply_to": {"type": "string"},
            },
            "required": ["to_cabinet", "from_agent", "content"],
            "additionalProperties": False,
        },
        "handler": tool_send_message,
        "federation_allowed": True,
    },
    {
        "name": "request_handoff",
        "description": (
            "Ask a peer Cabinet to take ownership of a context. Typical use: Work "
            "Cabinet hands a personal-state conversation to Personal Cabinet. Same "
            "queue mechanic as send_message; queued with kind='handoff_request'. "
            "Peer consent + allowed_tools enforcement applies."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "to_cabinet": {"type": "string"},
                "context_slug": {"type": "string"},
                "reason": {"type": "string"},
                "from_agent": {"type": "string"},
            },
            "required": ["to_cabinet", "context_slug", "reason"],
            "additionalProperties": False,
        },
        "handler": tool_request_handoff,
        "federation_allowed": True,
    },
]


def get_tool(name: str) -> dict | None:
    for t in TOOLS:
        if t["name"] == name:
            return t
    return None


# ---------------------------------------------------------------
# JSON-RPC dispatch
# ---------------------------------------------------------------

def make_tool_result(payload: Any) -> dict:
    return {"content": [{"type": "text", "text": json.dumps(payload, indent=2, sort_keys=True, default=str)}]}


def handle(req: dict) -> dict | None:
    method = req.get("method", "")
    rid = req.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            },
        }

    if method in ("notifications/initialized", "initialized"):
        return None

    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "tools": [
                    {
                        "name": t["name"],
                        "description": t["description"],
                        "inputSchema": t["inputSchema"],
                    }
                    for t in TOOLS
                ]
            },
        }

    if method == "tools/call":
        params = req.get("params", {})
        name = params.get("name", "")
        args = params.get("arguments", {}) or {}
        tool = get_tool(name)
        if not tool:
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "error": {"code": -32601, "message": f"Tool not found: {name}"},
            }
        # Capacity guard (Phase 3-forward). If this Cabinet is personal and
        # the tool is flagged federation_allowed=False, refuse. All Phase 2
        # tools are federation_allowed=True; guard is infrastructure, not
        # today's block.
        if not tool.get("federation_allowed", True) and this_cabinet_capacity() == "personal":
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "result": make_tool_result({
                    "status": "refused",
                    "reason": "personal_capacity_refuses_federation_tool",
                    "tool": name,
                }),
            }
        try:
            payload = tool["handler"](args)
        except Exception as exc:
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "error": {"code": -32603, "message": f"Tool '{name}' failed: {exc}"},
            }
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": make_tool_result(payload),
        }

    return {
        "jsonrpc": "2.0",
        "id": rid,
        "error": {"code": -32601, "message": f"Method not found: {method}"},
    }


def main() -> None:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as exc:
            err = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": f"Parse error: {exc}"},
            }
            sys.stdout.write(json.dumps(err) + "\n")
            sys.stdout.flush()
            continue
        resp = handle(req)
        if resp is None:
            continue
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
