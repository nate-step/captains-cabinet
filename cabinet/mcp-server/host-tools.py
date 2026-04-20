#!/usr/bin/env python3
"""
Cabinet Host-Tools MCP Module — Spec 035 Phase A

Exposes the 6 host-agent tools as MCP tools. Speaks NDJSON to the
host-agent Unix socket at /run/cabinet/host-agent.sock.

Scope: CoS ONLY.
  - In mcp-scope.yml, only the `cos` agent lists "host" in its mcps.
  - The pre-tool-use.sh hook enforces the scope list and blocks any other
    agent from calling these tools at tool-call time.
  - This module itself is registered as the "host" MCP server in the
    officers/cos/.mcp.json file (CoS-local .mcp.json, not the root one),
    so it is never loaded into any other officer's session.

Scoping mechanism:
  1. Root .mcp.json — global MCPs available to all (notion, linear, etc.)
  2. officers/cos/.mcp.json — CoS-only MCPs (this module).
     Other officer dirs do NOT have a .mcp.json with "host" in it.
  3. cabinet/mcp-scope.yml — pre-tool-use.sh allowlist; cos lists "host",
     all other agents do not.

Wire protocol: NDJSON over Unix socket.
  Request:  {"v": 1, "tool": "<name>", "args": {...}, "request_id": "<uuid>"}
  Response: {"v": 1, "ok": true|false, "exit": <int|null>, ...}
  Streaming: {"v": 1, "chunk": "...", "request_id": "<uuid>"} ... {"v": 1, "done": true, ...}

This module integrates into the existing cabinet MCP server pattern. It is
designed to be imported and its TOOLS list merged into the parent server's
TOOLS list when the server detects it is running as the CoS agent.
Alternatively it can run standalone as its own MCP server process.
"""

import json
import os
import socket
import sys
import uuid
from pathlib import Path
from typing import Any

SOCKET_PATH = Path("/run/cabinet/host-agent.sock")

# Streaming tools — responses are chunked before the done message
STREAMING_TOOLS = {"tail_logs", "read_file"}


# ----------------------------------------------------------------
# Socket communication helpers
# ----------------------------------------------------------------

def _send_request(tool: str, args: dict) -> dict | list[dict]:
    """Send a request to the host-agent and return the response(s).

    For non-streaming tools: returns a single dict (the response).
    For streaming tools: returns a list of dicts (chunks + done message).

    Raises ConnectionError if the socket is unavailable.
    Raises OSError on socket I/O errors.
    """
    request_id = str(uuid.uuid4())
    req = {
        "v": 1,
        "tool": tool,
        "args": args,
        "request_id": request_id,
    }
    payload = (json.dumps(req) + "\n").encode()

    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(int(args.get("timeout_sec", 310)))  # slightly over daemon max
        sock.connect(str(SOCKET_PATH))
    except (FileNotFoundError, ConnectionRefusedError, OSError) as exc:
        raise ConnectionError(
            f"Cannot connect to host-agent at {SOCKET_PATH}: {exc}. "
            "Is cabinet-host-agent.service running? Is the socket mounted?"
        ) from exc

    try:
        sock.sendall(payload)

        # Read response lines (NDJSON)
        buf = b""
        messages = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                    messages.append(msg)
                    # Non-streaming: stop after first message
                    if tool not in STREAMING_TOOLS:
                        return msg
                    # Streaming: stop at done message
                    if msg.get("done"):
                        return messages
                except json.JSONDecodeError:
                    continue

        # Fallback: return whatever we got
        if messages:
            return messages if tool in STREAMING_TOOLS else messages[0]
        return {"ok": False, "error_code": "exec-error", "stderr": "No response from host-agent"}

    finally:
        sock.close()


def _collect_stream(messages: list[dict]) -> str:
    """Reassemble streaming chunks into a single string."""
    parts = []
    for msg in messages:
        if "chunk" in msg:
            parts.append(msg["chunk"])
    return "".join(parts)


def _format_result(result: Any) -> str:
    """Format tool result as JSON string for MCP text content."""
    if isinstance(result, (dict, list)):
        return json.dumps(result, indent=2, default=str)
    return str(result)


# ----------------------------------------------------------------
# Tool handlers (called by MCP dispatch)
# ----------------------------------------------------------------

def host_run(args: dict) -> dict:
    """Run a shell command on the host as root."""
    required = ["cmd"]
    for field in required:
        if field not in args:
            return {"ok": False, "error_code": "args-invalid", "error": f"'{field}' is required"}
    try:
        return _send_request("run", args)
    except ConnectionError as exc:
        return {"ok": False, "error_code": "exec-error", "error": str(exc)}


def host_rebuild_service(args: dict) -> dict:
    """Run docker compose build + up -d for a named service."""
    if "name" not in args:
        return {"ok": False, "error_code": "args-invalid", "error": "'name' is required"}
    try:
        return _send_request("rebuild_service", args)
    except ConnectionError as exc:
        return {"ok": False, "error_code": "exec-error", "error": str(exc)}


def host_restart_officer(args: dict) -> dict:
    """Restart a named officer container. Refuses 'cos' (self-restart-forbidden)."""
    if "name" not in args:
        return {"ok": False, "error_code": "args-invalid", "error": "'name' is required"}
    try:
        return _send_request("restart_officer", args)
    except ConnectionError as exc:
        return {"ok": False, "error_code": "exec-error", "error": str(exc)}


def host_tail_logs(args: dict) -> dict:
    """Tail docker compose logs for a service (streaming, reassembled)."""
    if "service" not in args:
        return {"ok": False, "error_code": "args-invalid", "error": "'service' is required"}
    try:
        messages = _send_request("tail_logs", args)
        if isinstance(messages, list):
            done = messages[-1] if messages else {}
            content = _collect_stream(messages)
            return {
                "ok": not done.get("error_code"),
                "stdout": content,
                "total_bytes": done.get("total_bytes", len(content)),
                "error_code": done.get("error_code"),
            }
        # Non-streaming error response
        return messages
    except ConnectionError as exc:
        return {"ok": False, "error_code": "exec-error", "error": str(exc)}


def host_edit_file(args: dict) -> dict:
    """Apply a unified diff to a file on the host via git apply."""
    for field in ["path", "diff"]:
        if field not in args:
            return {"ok": False, "error_code": "args-invalid", "error": f"'{field}' is required"}
    try:
        return _send_request("edit_file", args)
    except ConnectionError as exc:
        return {"ok": False, "error_code": "exec-error", "error": str(exc)}


def host_read_file(args: dict) -> dict:
    """Read a file from the host filesystem (1 MiB default, 50 MiB hard cap)."""
    if "path" not in args:
        return {"ok": False, "error_code": "args-invalid", "error": "'path' is required"}
    try:
        messages = _send_request("read_file", args)
        if isinstance(messages, list):
            done = messages[-1] if messages else {}
            content = _collect_stream(messages)
            return {
                "ok": not done.get("error_code"),
                "content": content,
                "total_bytes": done.get("total_bytes", len(content)),
                "truncated": done.get("truncated", False),
                "truncated_at_bytes": done.get("truncated_at_bytes"),
                "error_code": done.get("error_code"),
            }
        # Non-streaming error (e.g. file-too-large, file-not-found)
        return messages
    except ConnectionError as exc:
        return {"ok": False, "error_code": "exec-error", "error": str(exc)}


# ----------------------------------------------------------------
# MCP tool definitions
# ----------------------------------------------------------------
TOOLS: list[dict[str, Any]] = [
    {
        "name": "host__run",
        "description": (
            "Run a shell command on the Cabinet host machine as root. "
            "Returns stdout, stderr, exit code, and duration. "
            "Scope: CoS only. Every call is audited to /var/log/cabinet/cos-actions.jsonl."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "cmd": {"type": "string", "description": "Shell command to run"},
                "cwd": {"type": "string", "description": "Working directory (optional)"},
                "timeout_sec": {
                    "type": "number",
                    "description": "Timeout in seconds (default 300, max 1800)",
                },
            },
            "required": ["cmd"],
            "additionalProperties": False,
        },
        "handler": host_run,
    },
    {
        "name": "host__rebuild_service",
        "description": (
            "Rebuild and restart a Docker Compose service on the host. "
            "Runs: docker compose build <name> && docker compose up -d <name>. "
            "Use for deploying code changes to a specific service. "
            "Scope: CoS only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Docker Compose service name"},
                "timeout_sec": {"type": "number", "description": "Timeout (default 300, max 1800)"},
            },
            "required": ["name"],
            "additionalProperties": False,
        },
        "handler": host_rebuild_service,
    },
    {
        "name": "host__restart_officer",
        "description": (
            "Restart a named officer container via docker compose restart. "
            "Cannot be used to restart 'cos' or 'cabinet-cos' (self-restart-forbidden). "
            "Use /cos restart from the admin Telegram bot to restart CoS. "
            "Scope: CoS only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Officer container name (not 'cos')"},
                "timeout_sec": {"type": "number", "description": "Timeout (default 300, max 1800)"},
            },
            "required": ["name"],
            "additionalProperties": False,
        },
        "handler": host_restart_officer,
    },
    {
        "name": "host__tail_logs",
        "description": (
            "Retrieve the last N lines of logs from a Docker Compose service. "
            "Returns the log content as a string. "
            "Scope: CoS only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "service": {"type": "string", "description": "Docker Compose service name"},
                "n": {"type": "integer", "description": "Number of log lines (default 100)"},
                "timeout_sec": {"type": "number", "description": "Timeout (default 300, max 1800)"},
            },
            "required": ["service"],
            "additionalProperties": False,
        },
        "handler": host_tail_logs,
    },
    {
        "name": "host__edit_file",
        "description": (
            "Apply a unified diff to a file on the host using git apply. "
            "On failure the original file is unchanged (git apply is transactional). "
            "Returns error_code 'patch-failed' if the diff does not apply cleanly. "
            "Scope: CoS only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute path to the file to edit"},
                "diff": {
                    "type": "string",
                    "description": "Unified diff to apply (git diff / diff -u format)",
                },
                "timeout_sec": {"type": "number", "description": "Timeout (default 300, max 1800)"},
            },
            "required": ["path", "diff"],
            "additionalProperties": False,
        },
        "handler": host_edit_file,
    },
    {
        "name": "host__read_file",
        "description": (
            "Read a file from the host filesystem. Default cap: 1 MiB. "
            "Caller can override max_bytes up to a 50 MiB hard cap. "
            "Returns error_code 'file-too-large' if the file exceeds the hard cap. "
            "Returns 'truncated: true' if the file was cut at max_bytes. "
            "Scope: CoS only."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Absolute path to read"},
                "max_bytes": {
                    "type": "integer",
                    "description": "Max bytes to return (default 1048576 = 1 MiB, hard cap 52428800 = 50 MiB)",
                },
            },
            "required": ["path"],
            "additionalProperties": False,
        },
        "handler": host_read_file,
    },
]


# ----------------------------------------------------------------
# MCP server — runs standalone as a stdio MCP server
# Integrates with the same JSON-RPC protocol as cabinet/mcp-server/server.py
# ----------------------------------------------------------------

SERVER_NAME    = "host-tools"
SERVER_VERSION = "0.1.0"
PROTOCOL_VERSION = "2024-11-05"


def make_tool_result(payload: Any) -> dict:
    return {"content": [{"type": "text", "text": _format_result(payload)}]}


def get_tool(name: str) -> dict | None:
    for t in TOOLS:
        if t["name"] == name:
            return t
    return None


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


def run_stdio() -> None:
    """Run as a standalone stdio MCP server."""
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
    # Check socket exists (warn, don't abort — host may not be bootstrapped yet)
    if not SOCKET_PATH.exists():
        sys.stderr.write(
            f"[host-tools] WARNING: Socket {SOCKET_PATH} does not exist. "
            "Is cabinet-host-agent.service running and the socket mounted?\n"
        )
    run_stdio()
