#!/usr/bin/env python3
"""
Cabinet MCP server — Phase 1 CP8 prototype.

Exposes a single tool: cabinet:identify() → {cabinet_id, captain_id, available_agents}.

Purpose: de-risk the Phase 2 inter-Cabinet MCP architecture. The tool signature
is the exact shape Phase 2 will use when a Cabinet needs to discover its
identity, the Captain it serves, and the agents it can route work to. Phase 1
runs this over stdio (simple, local-only, no network surface). Phase 2 moves
it to HTTP without changing the tool signature — only the transport.

Protocol: MCP over stdio, JSON-RPC 2.0. One request per line.

Usage (for manual smoke test):
    echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | python3 server.py

Configured callers: not yet. To register with Claude Code, add to .mcp.json:
    {"mcpServers": {"cabinet": {"command": "python3",
     "args": ["/opt/founders-cabinet/cabinet/mcp-server/server.py"]}}}

Captain decision 2026-04-16 CD5: stdio for prototype; HTTP-compatible signature.
"""

import json
import os
import re
import sys
from pathlib import Path

CABINET_ROOT = Path(os.environ.get("CABINET_ROOT", "/opt/founders-cabinet"))
MCP_SCOPE_PATH = CABINET_ROOT / "cabinet" / "mcp-scope.yml"
PRODUCT_YML = CABINET_ROOT / "instance" / "config" / "product.yml"
PLATFORM_YML = CABINET_ROOT / "instance" / "config" / "platform.yml"

SERVER_NAME = "cabinet"
SERVER_VERSION = "0.1.0"
PROTOCOL_VERSION = "2024-11-05"


def read_hired_agents():
    """Parse mcp-scope.yml and return the list of hired (not scaffold) agent slugs."""
    if not MCP_SCOPE_PATH.exists():
        return []
    text = MCP_SCOPE_PATH.read_text()
    agents = []
    section = None
    for line in text.splitlines():
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
    """Read a key from a flat or one-level-nested YAML file.

    - `section=None`: match `key:` only at column 0 (root-level).
    - `section="product"`: match `key:` only inside the `product:` block
      (entered at column 0, exited on the next column-0 key).

    This is deliberately more restrictive than "first match at any indent"
    — the prior implementation returned a random sibling key if two
    sections happened to share a name. Specifying the section makes the
    lookup deterministic and the caller's intent explicit.

    PyYAML would handle this in one line (`yaml.safe_load(...)[section][key]`).
    The container ships without PyYAML and without pip; this regex-based
    reader is the stdlib-only substitute. Swap for pyyaml when Phase 2
    brings the dependency.
    """
    if not path.exists():
        return default
    in_section = section is None  # root-level mode starts inside
    for line in path.read_text().splitlines():
        # Exit section when we hit another column-0 key
        if section is not None and re.match(r"^[A-Za-z]", line):
            head = line.split(":", 1)[0].strip()
            in_section = head == section
            continue
        if not in_section:
            continue
        # Root mode: only col-0 keys. Section mode: indented (>=1 space).
        if section is None:
            m = re.match(rf"^{re.escape(key)}:\s*(.*)$", line)
        else:
            m = re.match(rf"^\s+{re.escape(key)}:\s*(.*)$", line)
        if m:
            return m.group(1).strip().strip("\"'")
    return default


def cabinet_identify():
    """Return identity payload for this Cabinet."""
    cabinet_id = os.environ.get("CABINET_ID", "main")
    captain_name = read_simple_yaml_key(PRODUCT_YML, "captain_name", section="product")
    captain_id = os.environ.get("CAPTAIN_ID") or captain_name or "unknown"
    return {
        "cabinet_id": cabinet_id,
        "captain_id": captain_id,
        "available_agents": read_hired_agents(),
        "server": {"name": SERVER_NAME, "version": SERVER_VERSION},
    }


def make_tool_result(payload):
    """Wrap a dict payload in the MCP tools/call result envelope."""
    return {
        "content": [
            {"type": "text", "text": json.dumps(payload, indent=2, sort_keys=True)}
        ]
    }


def handle(req):
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
        # No response for notifications
        return None

    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "result": {
                "tools": [
                    {
                        "name": "identify",
                        "description": (
                            "Returns this Cabinet's identity: cabinet_id, captain_id, "
                            "available_agents (hired agent slugs). Call shape is "
                            "stable across Phase 1 (stdio) and Phase 2 (HTTP) — only "
                            "the transport changes."
                        ),
                        "inputSchema": {
                            "type": "object",
                            "properties": {},
                            "additionalProperties": False,
                        },
                    }
                ]
            },
        }

    if method == "tools/call":
        name = req.get("params", {}).get("name", "")
        if name == "identify":
            return {
                "jsonrpc": "2.0",
                "id": rid,
                "result": make_tool_result(cabinet_identify()),
            }
        return {
            "jsonrpc": "2.0",
            "id": rid,
            "error": {
                "code": -32601,
                "message": f"Tool not found: {name}",
            },
        }

    return {
        "jsonrpc": "2.0",
        "id": rid,
        "error": {"code": -32601, "message": f"Method not found: {method}"},
    }


def main():
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
