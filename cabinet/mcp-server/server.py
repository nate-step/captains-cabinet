#!/usr/bin/env python3
"""
Cabinet MCP server — Phase 2 CP2 expansion + FW-005 HTTP transport.

Exposes inter-Cabinet tools for the Phase 2 Cabinet Suite (Work + Personal
Cabinets linked via this MCP). Phase 1 shipped identify() as a de-risk
prototype; Phase 2 adds presence(), availability(), send_message(), and
request_handoff(). FW-005 adds HTTP transport so two Docker-deployed Cabinets
can talk without shared filesystems.

Transport selection:
    CABINET_MCP_TRANSPORT=stdio   (default — backward compatible with all
                                   existing stdio callers and Claude Code .mcp.json)
    CABINET_MCP_TRANSPORT=http    Starts aiohttp-free HTTP listener on
                                   CABINET_MCP_PORT (default 7471) alongside
                                   stdio NOT replacing it. Both transports serve
                                   the identical tool surface.

HTTP bearer auth:
    Every HTTP request must carry:
        Authorization: Bearer <secret>
    The secret is read from the env var named by `shared_secret_ref` in
    peers.yml for the calling Cabinet. If the header is absent or wrong,
    the server returns 401 — no tool execution occurs.

    To share a secret with a peer, both sides set the same env var name
    in shared_secret_ref and populate it in their .env files. Secret is
    NEVER written to peers.yml or any tracked file.

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
FW-005 Captain directive: HTTP transport (Option 2) for Phase 2 completion.
"""

import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

CABINET_ROOT = Path(os.environ.get("CABINET_ROOT", "/opt/founders-cabinet"))
MCP_SCOPE_PATH = CABINET_ROOT / "cabinet" / "mcp-scope.yml"
PRODUCT_YML = CABINET_ROOT / "instance" / "config" / "product.yml"
PLATFORM_YML = CABINET_ROOT / "instance" / "config" / "platform.yml"
PEERS_YML = CABINET_ROOT / "instance" / "config" / "peers.yml"
CALENDAR_YML = CABINET_ROOT / "instance" / "config" / "calendar.yml"

SERVER_NAME = "cabinet"
SERVER_VERSION = "0.4.0"  # bumped for FW-079 cost_summary tool
PROTOCOL_VERSION = "2024-11-05"

# Transport config
TRANSPORT = os.environ.get("CABINET_MCP_TRANSPORT", "stdio").strip().lower()
HTTP_PORT = int(os.environ.get("CABINET_MCP_PORT", "7471"))

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
    """Return this Cabinet's capacity (preset name).

    FW-060 fix: lookup chain is env → active-preset file → platform.yml → default.
    The active-preset file is the deployment's source-of-truth (it's what
    load-preset.sh reads to assemble the runtime), so a Personal Cabinet
    naturally returns 'personal' without needing platform.yml or env tweaks.
    Env var stays first so operators can override at container-start.
    """
    env = os.environ.get("CABINET_CAPACITY", "").strip()
    if env:
        return env
    # active-preset is a single-line file containing just the preset name.
    active_preset_path = CABINET_ROOT / "instance" / "config" / "active-preset"
    try:
        preset = active_preset_path.read_text(encoding="utf-8").strip()
        if preset:
            return preset
    except OSError:
        pass
    return read_simple_yaml_key(PLATFORM_YML, "capacity", default="work")


def peer_by_id(peer_id: str) -> dict[str, Any] | None:
    for p in read_peers():
        if p.get("id") == peer_id:
            return p
    return None


# ---------------------------------------------------------------
# Bearer auth helpers (HTTP transport only)
# ---------------------------------------------------------------

def _get_all_valid_secrets() -> list[str]:
    """Collect valid bearer secrets from all peers with a shared_secret_ref.
    A request is authed if it matches ANY peer's secret — the specific peer
    is not identified at the auth layer (tool-level consent checks handle that)."""
    secrets: list[str] = []
    for peer in read_peers():
        ref = peer.get("shared_secret_ref", "")
        if ref:
            val = os.environ.get(ref, "").strip()
            if val:
                secrets.append(val)
    return secrets


def verify_bearer(auth_header: str | None) -> bool:
    """Return True if auth_header matches a configured peer secret.

    Security rules:
    - When peer secrets ARE configured: Bearer token must match one of them
      (hmac.compare_digest to prevent timing attacks). Missing or wrong token
      → False → caller returns 401.
    - When NO peer secrets are configured (fresh Cabinet, no shared_secret_ref
      set in peers.yml or env vars): server is in "open mode" — all requests
      are allowed with a loud warning on stderr. This covers the dev/bootstrap
      case where the admin has not yet set up secrets.

    Returns False (not 401 directly) — caller decides HTTP response code.
    """
    valid_secrets = _get_all_valid_secrets()
    if not valid_secrets:
        # No secrets configured: HTTP transport is open — log a warning on
        # every request so the operator can see auth is not enforced.
        sys.stderr.write(
            "[cabinet-mcp] WARNING: HTTP transport has no shared_secret_ref secrets "
            "configured. All requests accepted. Set shared_secret_ref + env var in "
            "peers.yml to enable bearer auth.\n"
        )
        return True

    # Secrets are configured — enforce bearer token.
    if not auth_header:
        return False
    if not auth_header.startswith("Bearer "):
        return False
    provided = auth_header[len("Bearer "):]
    import hmac
    for secret in valid_secrets:
        if hmac.compare_digest(provided.encode(), secret.encode()):
            return True
    return False


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

    # FW-005 relay-inbound delivery path: the cross-Cabinet relay (cabinet-mcp-relay.py)
    # POSTs queued outbound entries to the peer's HTTP sidecar by re-calling send_message
    # with to_cabinet=<destination cabinet id>. From the receiver's perspective, that
    # value equals its own this_cabinet_id() — meaning "deliver this incoming message
    # locally", NOT "queue this for outbound to a peer." The original peer_by_id check
    # below would reject (cabinet not in its own peer list) and the relay would lose
    # the message. Detect self-delivery here and route to a local trigger stream.
    if to_cabinet == this_cabinet_id():
        from_cabinet = params.get("from_cabinet") or params.get("_relay_origin_cabinet") or "unknown"
        # Default delivery target: CoS — coordinates cross-Cabinet inbound by design
        # (matches "Officer → Officer (Redis push)" pattern in CLAUDE.md). Future
        # extension: honor an explicit `to_role` param when relays carry it.
        target_role = params.get("to_role", "cos")
        try:
            out = subprocess.run(
                [
                    "redis-cli", "-h", REDIS_HOST, "-p", REDIS_PORT,
                    "XADD", f"cabinet:triggers:{target_role}", "*",
                    "source", "cross-cabinet",
                    "from_cabinet", from_cabinet,
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
            sys.stderr.write(f"[cabinet-mcp] send_message DELIVERED inbound to_role={target_role} from_cabinet={from_cabinet} from_agent={from_agent} msg_id={msg_id}\n")
            return {"status": "delivered", "to_role": target_role, "message_id": msg_id}
        except (subprocess.TimeoutExpired, FileNotFoundError) as e:
            return {"status": "error", "message": f"redis unreachable: {e}"}

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
# Cost summary helpers (FW-079 — Pool Phase 3)
# ---------------------------------------------------------------

# Slug validation: lowercase alphanumeric + hyphen, starting with alnum, max 32 chars.
_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")
_MAX_DAYS = 90

# Dimensions tracked per HSET field suffix (stop-hook.sh FW-072 source).
# Note: cost_micro and cache_write/cache_read each contain underscores, so
# the canonical dim suffix can be 1 or 2 underscore-separated tokens.
# We check for longest-match dim suffixes first (cost_micro before micro, etc.)
_DIMS = ("cost_micro", "cache_write", "cache_read", "input", "output")
# Set for fast membership test
_DIMS_SET = frozenset(_DIMS)


def _valid_slug(s: str) -> bool:
    return bool(_SLUG_RE.match(s))


def _redis_hgetall(key: str) -> dict[str, str]:
    """Run HGETALL on a Redis key; return field→value dict (strings). Empty on error."""
    try:
        out = subprocess.run(
            ["redis-cli", "-h", REDIS_HOST, "-p", REDIS_PORT, "HGETALL", key],
            capture_output=True, text=True, timeout=3,
        )
        lines = out.stdout.strip().splitlines()
        result: dict[str, str] = {}
        it = iter(lines)
        for field in it:
            try:
                val = next(it)
            except StopIteration:
                break
            result[field] = val
        return result
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return {}


def _parse_cost_hset(raw: dict[str, str], officer_filter: str | None, project_filter: str | None) -> dict:
    """Parse a single day's HSET fields into structured rollup buckets.

    Field shapes (from stop-hook.sh FW-072):
      Legacy (no project):  <officer>_<dim>            e.g. cto_cost_micro
      Pool   (with project): <officer>_<project>_<dim>  e.g. cto_sensed_cost_micro

    Returns dict with keys:
      by_officer_project: { "<officer>:<project|null>": {dim: int, ...} }
    Malformed fields (not matching known dimensions) are silently skipped.
    """
    buckets: dict[str, dict[str, int]] = {}

    for field, val_str in raw.items():
        # Determine whether field is legacy or pool shape.
        #
        # Key insight: known dims can be multi-token (cost_micro, cache_write, cache_read).
        # Officer and project slugs use hyphens only (not underscores), so splitting on `_`
        # cleanly separates officer, optional project, and dim suffix.
        #
        # Strategy: try longest-match dim suffix first (2-token dims before 1-token dims).
        #   Shapes:
        #     Legacy:  <officer>_<dim1>               e.g. cto_input         (2 parts)
        #              <officer>_<dim1>_<dim2>         e.g. cto_cost_micro    (3 parts)
        #     Pool:    <officer>_<project>_<dim1>      e.g. cto_sensed_input  (3 parts)
        #              <officer>_<project>_<dim1>_<dim2> e.g. cto_sensed_cost_micro (4 parts)
        #
        # We try to match dim suffix as 2-token compound first, then 1-token.
        # Remaining prefix determines officer (and optional project).
        parts = field.split("_")
        dim: str | None = None
        prefix_parts: list[str] = []

        # Try 2-token dim suffix (e.g. cost_micro, cache_write, cache_read)
        if len(parts) >= 3 and "_".join(parts[-2:]) in _DIMS_SET:
            dim = "_".join(parts[-2:])
            prefix_parts = parts[:-2]
        elif len(parts) >= 2 and parts[-1] in _DIMS_SET:
            dim = parts[-1]
            prefix_parts = parts[:-1]
        else:
            # Malformed or unrecognised field — skip silently.
            continue

        # prefix_parts contains [officer] or [officer, project]
        if len(prefix_parts) == 1:
            officer = prefix_parts[0]
            project = None
        elif len(prefix_parts) == 2:
            officer = prefix_parts[0]
            project = prefix_parts[1]
        else:
            # Unexpected shape — skip.
            continue

        # Validate officer and project slugs from HSET field to drop malformed entries.
        if not _valid_slug(officer):
            continue
        if project is not None and not _valid_slug(project):
            continue

        # Apply filters (None means "all").
        if officer_filter and officer != officer_filter:
            continue
        if project_filter is not None and project != project_filter:
            continue

        try:
            val = int(val_str)
        except (ValueError, TypeError):
            continue

        key = f"{officer}:{project}"
        if key not in buckets:
            buckets[key] = {d: 0 for d in _DIMS}
        buckets[key][dim] += val

    return buckets


def tool_cost_summary(params: dict) -> dict:
    """Per-(officer, project) cost rollup from Redis daily HSET (FW-079 / Pool Phase 3).

    Reads cabinet:cost:tokens:daily:<date> HSET written by stop-hook.sh (FW-072).
    Field shapes:
      Legacy: <officer>_<dim>
      Pool:   <officer>_<project>_<dim>
    Multi-day aggregation sums across all requested dates.
    """
    # --- Parameter extraction + validation ---
    import datetime

    raw_date = params.get("date") or None
    raw_officer = params.get("officer") or None
    raw_project = params.get("project")           # None = all; explicit None or missing = all
    raw_days = params.get("days", 1)

    # Validate date
    today_str = datetime.date.today().strftime("%Y-%m-%d")
    if raw_date is None:
        end_date_str = today_str
    else:
        try:
            datetime.date.fromisoformat(raw_date)
            end_date_str = raw_date
        except (ValueError, TypeError):
            return {"status": "error", "message": f"Invalid date: {raw_date!r}. Use YYYY-MM-DD."}

    # Validate days
    try:
        days = int(raw_days)
    except (ValueError, TypeError):
        days = 1
    days = max(1, min(days, _MAX_DAYS))

    # Validate slugs
    if raw_officer is not None and not _valid_slug(str(raw_officer)):
        return {"status": "error", "message": f"Invalid officer slug: {raw_officer!r}. Must match ^[a-z0-9][a-z0-9-]{{0,31}}$."}
    if raw_project is not None and not _valid_slug(str(raw_project)):
        return {"status": "error", "message": f"Invalid project slug: {raw_project!r}. Must match ^[a-z0-9][a-z0-9-]{{0,31}}$."}

    officer_filter = str(raw_officer) if raw_officer is not None else None
    project_filter = str(raw_project) if raw_project is not None else None

    # Build date range
    end_date = datetime.date.fromisoformat(end_date_str)
    start_date = end_date - datetime.timedelta(days=days - 1)

    # Aggregate across date range
    combined: dict[str, dict[str, int]] = {}
    for i in range(days):
        d = start_date + datetime.timedelta(days=i)
        date_key = f"cabinet:cost:tokens:daily:{d.strftime('%Y-%m-%d')}"
        raw = _redis_hgetall(date_key)
        day_buckets = _parse_cost_hset(raw, officer_filter, project_filter)
        for op_key, dims in day_buckets.items():
            if op_key not in combined:
                combined[op_key] = {dim: 0 for dim in _DIMS}
            for dim, val in dims.items():
                combined[op_key][dim] += val

    # Build rollup aggregates
    by_officer: dict[str, dict[str, int]] = {}
    by_project: dict[str, dict[str, int]] = {}
    by_officer_project: dict[str, dict] = {}

    for op_key, dims in combined.items():
        officer, project = op_key.split(":", 1)
        project_display = project if project != "None" else None

        # by_officer_project
        by_officer_project[op_key] = {
            "cost_micro": dims["cost_micro"],
            "cost_usd": round(dims["cost_micro"] / 1_000_000, 6),
            "tokens_in": dims["input"],
            "tokens_out": dims["output"],
            "tokens_cache_write": dims["cache_write"],
            "tokens_cache_read": dims["cache_read"],
            "officer": officer,
            "project": project_display,
        }

        # by_officer (accumulate)
        if officer not in by_officer:
            by_officer[officer] = {d: 0 for d in _DIMS}
        for dim in _DIMS:
            by_officer[officer][dim] += dims[dim]

        # by_project (accumulate; use string "null" key for None so JSON is clean)
        proj_key = project_display if project_display is not None else "null"
        if proj_key not in by_project:
            by_project[proj_key] = {d: 0 for d in _DIMS}
        for dim in _DIMS:
            by_project[proj_key][dim] += dims[dim]

    # Normalise by_officer and by_project into final shape
    def _normalise_bucket(b: dict[str, int]) -> dict:
        return {
            "cost_micro": b["cost_micro"],
            "cost_usd": round(b["cost_micro"] / 1_000_000, 6),
            "tokens_in": b["input"],
            "tokens_out": b["output"],
            "tokens_cache_write": b["cache_write"],
            "tokens_cache_read": b["cache_read"],
        }

    total_cost_micro = sum(v["cost_micro"] for v in by_officer.values())

    return {
        "date_range": {
            "start": start_date.strftime("%Y-%m-%d"),
            "end": end_date.strftime("%Y-%m-%d"),
        },
        "total_cost_micro": total_cost_micro,
        "total_cost_usd": round(total_cost_micro / 1_000_000, 6),
        "by_officer": {o: _normalise_bucket(b) for o, b in by_officer.items()},
        "by_project": {p: _normalise_bucket(b) for p, b in by_project.items()},
        "by_officer_project": by_officer_project,
        "filters": {
            "officer": officer_filter,
            "project": project_filter,
            "days": days,
        },
    }


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
    {
        "name": "cost_summary",
        "description": (
            "Return per-(officer, project) cost rollup from Redis daily HSET "
            "(FW-079 / Pool Phase 3). Reads cabinet:cost:tokens:daily:<date> written "
            "by stop-hook.sh FW-072. Supports both legacy field shape (<officer>_<dim>) "
            "and pool field shape (<officer>_<project>_<dim>). Multi-day aggregation "
            "available via `days` param (max 90). Results include total_cost_usd, "
            "by_officer, by_project, and by_officer_project breakdowns."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": {
                    "type": "string",
                    "description": "ISO date YYYY-MM-DD. Defaults to today UTC.",
                },
                "officer": {
                    "type": "string",
                    "description": "Filter to single officer slug (e.g. 'cto'). Omit for all officers.",
                },
                "project": {
                    "type": "string",
                    "description": "Filter to single project slug (e.g. 'sensed'). Omit for all projects.",
                },
                "days": {
                    "type": "integer",
                    "description": "Number of days backwards from `date` to aggregate. Default 1, max 90.",
                    "default": 1,
                },
            },
            "additionalProperties": False,
        },
        "handler": tool_cost_summary,
        "federation_allowed": True,
    },
]


def get_tool(name: str) -> dict | None:
    for t in TOOLS:
        if t["name"] == name:
            return t
    return None


# ---------------------------------------------------------------
# JSON-RPC dispatch (shared by both transports)
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


# ---------------------------------------------------------------
# Stdio transport (unchanged from Phase 2 — fully backward compat)
# ---------------------------------------------------------------

def run_stdio() -> None:
    """Read JSON-RPC from stdin, write responses to stdout. One message per line."""
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


# ---------------------------------------------------------------
# HTTP transport (FW-005 — stdlib only, no aiohttp/fastapi needed)
# ---------------------------------------------------------------

class CabinetMCPHandler(BaseHTTPRequestHandler):
    """HTTP handler for Cabinet MCP JSON-RPC over POST /mcp.

    Security model:
    - Only POST /mcp is accepted; all other paths return 404.
    - Bearer token checked against shared_secret_ref env vars from peers.yml.
    - Missing/wrong Bearer → 401 with structured JSON body.
    - Tool dispatch is identical to stdio path (same `handle()` function).
    - All errors return structured JSON, never crash the server.
    """

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write(f"[cabinet-mcp-http] {format % args}\n")

    def _send_json(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self) -> None:
        if self.path != "/mcp":
            self._send_json(404, {"error": "not_found", "path": self.path})
            return

        # --- Bearer auth ---
        auth_header = self.headers.get("Authorization")
        if not verify_bearer(auth_header):
            self._send_json(401, {
                "error": "unauthorized",
                "message": "Missing or invalid Authorization: Bearer <secret>",
            })
            sys.stderr.write(
                f"[cabinet-mcp-http] 401 from {self.client_address[0]} — bad/missing bearer\n"
            )
            return

        # --- Read body ---
        # Catch OSError (ConnectionResetError / BrokenPipeError subclasses) alongside
        # parse errors — if the client disconnects mid-send, self.rfile.read() raises
        # OSError, which without this catch would propagate up to serve_forever and
        # log a traceback per request. Per Opus 4.7 pre-commit review.
        try:
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length).decode()
            req = json.loads(raw)
        except (ValueError, json.JSONDecodeError) as exc:
            self._send_json(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": f"Parse error: {exc}"}})
            return
        except OSError as exc:
            # Client disconnected mid-request — log and return. Can't send a
            # response body to a dead connection, but try 400 in case the socket
            # is still half-open; ignore any write failure.
            sys.stderr.write(f"[cabinet-mcp-http] client disconnected during body read: {exc}\n")
            try:
                self._send_json(400, {"error": "read_failed", "message": str(exc)})
            except OSError:
                pass
            return

        # --- Dispatch ---
        try:
            resp = handle(req)
        except Exception as exc:
            self._send_json(500, {"jsonrpc": "2.0", "id": req.get("id"), "error": {"code": -32603, "message": str(exc)}})
            return

        if resp is None:
            # Notification — no response body per JSON-RPC spec, but HTTP requires a
            # reply. Return 200 with empty object so clients can JSON-parse safely.
            self._send_json(200, {})
            return

        self._send_json(200, resp)

    def do_GET(self) -> None:
        """Health-check endpoint for Docker / inter-Cabinet liveness probes."""
        if self.path == "/health":
            self._send_json(200, {
                "status": "ok",
                "cabinet_id": this_cabinet_id(),
                "transport": "http",
                "server": {"name": SERVER_NAME, "version": SERVER_VERSION},
            })
        else:
            self._send_json(404, {"error": "not_found"})


def run_http(port: int) -> None:
    """Start the HTTP server in the current thread (called from a daemon thread).

    Uses ThreadingHTTPServer so a slow tool handler (e.g. 2-second Redis timeout
    in tool_presence when a peer is down) does not serialize the entire server
    and block concurrent requests. Per Opus 4.7 pre-commit review — swapping
    HTTPServer → ThreadingHTTPServer is a one-line fix that prevents head-of-line
    blocking on any single blocking tool call.
    """
    server = ThreadingHTTPServer(("0.0.0.0", port), CabinetMCPHandler)
    sys.stderr.write(
        f"[cabinet-mcp] HTTP transport listening on 0.0.0.0:{port} "
        f"(POST /mcp, GET /health). Cabinet ID: {this_cabinet_id()}\n"
    )
    server.serve_forever()


# ---------------------------------------------------------------
# Entry point — transport selection
# ---------------------------------------------------------------

def main() -> None:
    """Select transport based on CABINET_MCP_TRANSPORT env var.

    stdio (default):
        Runs the stdio loop — identical to pre-FW-005 behavior.
        Backward compatible with all existing Claude Code .mcp.json configs.

    http:
        Starts the HTTP listener on CABINET_MCP_PORT (default 7471) in a
        daemon thread, then also runs the stdio loop so the process stays
        alive AND remains usable by any stdio caller in the same container.

    Both transports serve the same tool surface via the same handle() function.
    """
    if TRANSPORT == "http":
        t = threading.Thread(target=run_http, args=(HTTP_PORT,), daemon=True)
        t.start()
        sys.stderr.write(f"[cabinet-mcp] Transport: http+stdio (port={HTTP_PORT})\n")
    else:
        if TRANSPORT not in ("stdio", ""):
            sys.stderr.write(
                f"[cabinet-mcp] WARNING: unknown CABINET_MCP_TRANSPORT={TRANSPORT!r}, "
                "falling back to stdio\n"
            )
        sys.stderr.write("[cabinet-mcp] Transport: stdio\n")

    run_stdio()


if __name__ == "__main__":
    main()
