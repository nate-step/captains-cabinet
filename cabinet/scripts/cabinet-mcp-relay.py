#!/usr/bin/env python3
"""Cabinet MCP outbox relay — Phase 2 completion of FW-005 send_message.

Drains `cabinet:inbox:<peer_id>` on the local Redis (= sender's outbox to that peer)
and forwards each message to the peer Cabinet's HTTP MCP endpoint. On successful
delivery (HTTP 200 + JSON-RPC result), XDELs the entry. Failed deliveries stay in
the queue for the next run.

Designed for cron execution from inside the officer container (or the mcp-server
sidecar). Uses stdlib only — no external Python deps required.

Run:
    REDIS_URL=redis://redis:6379 \\
    CABINET_ID=work \\
    python3 cabinet/scripts/cabinet-mcp-relay.py

Cron suggestion (every minute):
    * * * * * cd /opt/founders-cabinet && \\
              python3 cabinet/scripts/cabinet-mcp-relay.py >> \\
              memory/logs/cabinet-mcp-relay.log 2>&1

Behavior:
- Reads instance/config/peers.yml to find peer endpoints + shared_secret_refs.
- Skips peers with consented_by_captain != true.
- Skips peers where send_message is not in allowed_tools.
- For each peer, XRANGE the local cabinet:inbox:<peer_id>, POST each entry to the
  peer's /mcp endpoint as a tools/call cabinet.send_message JSON-RPC request,
  XDEL on HTTP 200 success.
- Idempotent: re-running the relay re-attempts unsent entries. Per-message ids
  carry the original Redis stream ID so dedup is the peer's responsibility.
- Bearer auth via the env var named in shared_secret_ref. Missing env var = skip
  the peer with a warning.

Logs to stderr (cron-friendly). Exit 0 always — never block the next run.
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

CABINET_ROOT = Path(os.environ.get("CABINET_ROOT", "/opt/founders-cabinet"))
PEERS_YML = CABINET_ROOT / "instance" / "config" / "peers.yml"
THIS_CABINET_ID = os.environ.get("CABINET_ID", "work")
REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379")
HTTP_TIMEOUT_S = int(os.environ.get("CABINET_RELAY_HTTP_TIMEOUT", "10"))
MAX_PER_PEER_PER_RUN = int(os.environ.get("CABINET_RELAY_MAX_BATCH", "50"))


def log(msg: str) -> None:
    sys.stderr.write(f"[cabinet-mcp-relay] {msg}\n")


def parse_redis_url(url: str) -> tuple[str, str]:
    parsed = urlparse(url)
    return parsed.hostname or "redis", str(parsed.port or 6379)


REDIS_HOST, REDIS_PORT = parse_redis_url(REDIS_URL)


def redis_cmd(*args: str) -> str | None:
    """Run redis-cli with the given args; return stdout or None on failure.

    Uses subprocess so we don't pull in redis-py as a dep. The mcp-server uses
    the same approach for its XADD path, so we match its style.
    """
    import subprocess
    try:
        out = subprocess.run(
            ["redis-cli", "-h", REDIS_HOST, "-p", REDIS_PORT, *args],
            capture_output=True, text=True, timeout=10,
        )
        if out.returncode != 0:
            log(f"redis-cli failed args={args[0]} rc={out.returncode} err={out.stderr.strip()[:200]}")
            return None
        return out.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError) as e:
        log(f"redis-cli unreachable: {e}")
        return None


def parse_peers_yml() -> dict[str, dict[str, Any]]:
    """Minimal peers.yml parser — same shape as server.py's read_peers().

    Avoids a PyYAML dep; only needs to handle the schema in instance/config/peers.yml.
    Returns {peer_id: {role, endpoint, capacity, trust_level, consented_by_captain,
    shared_secret_ref, allowed_tools, ...}} on success. Empty dict on parse failure.
    """
    if not PEERS_YML.exists():
        log(f"peers.yml not found at {PEERS_YML}")
        return {}
    peers: dict[str, dict[str, Any]] = {}
    current_peer: str | None = None
    current_block: dict[str, Any] = {}
    in_peers = False
    in_allowed_tools = False
    in_notes = False
    notes_buffer: list[str] = []
    notes_indent = -1

    def flush() -> None:
        if current_peer is None:
            return
        if notes_buffer:
            current_block["notes"] = "\n".join(notes_buffer).strip()
        peers[current_peer] = dict(current_block)

    with PEERS_YML.open() as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            stripped = line.strip()

            # Comments + blanks
            if stripped.startswith("#") or not stripped:
                if in_notes and stripped == "":
                    notes_buffer.append("")
                continue

            # Top-level "peers:" key
            if stripped == "peers:":
                in_peers = True
                continue
            if not in_peers:
                continue

            # Peer entry header: "  peer_id:" — exactly 2 leading spaces, ends with ":"
            if line.startswith("  ") and not line.startswith("    ") and stripped.endswith(":"):
                flush()
                current_peer = stripped[:-1]
                current_block = {"id": current_peer}
                in_allowed_tools = False
                in_notes = False
                notes_buffer = []
                continue

            if current_peer is None:
                continue

            # 4-space indented field of the current peer
            if line.startswith("    ") and not line.startswith("      "):
                in_allowed_tools = False
                if in_notes:
                    in_notes = False
                if ":" in stripped:
                    key, _, val = stripped.partition(":")
                    key = key.strip()
                    val = val.strip()
                    if key == "allowed_tools":
                        current_block["allowed_tools"] = []
                        in_allowed_tools = True
                        continue
                    if key == "notes":
                        in_notes = True
                        notes_buffer = []
                        if val and val != ">" and val != "|":
                            notes_buffer.append(val)
                        continue
                    if val.lower() in ("true", "false"):
                        current_block[key] = val.lower() == "true"
                    else:
                        current_block[key] = val.strip('"').strip("'")
                continue

            # 6+ space indent: list items or notes continuation
            if line.startswith("      "):
                if in_allowed_tools and stripped.startswith("- "):
                    current_block["allowed_tools"].append(stripped[2:].strip())
                    continue
                if in_notes:
                    notes_buffer.append(stripped)
                    continue

    flush()
    return peers


def post_to_peer(peer: dict[str, Any], payload: dict[str, Any]) -> tuple[bool, str]:
    """POST a JSON-RPC request to the peer's /mcp endpoint with bearer auth.

    Returns (success, error_message). success=True iff HTTP 200, no JSON-RPC
    top-level error, AND the inner tool result's status is in the success set
    (queued | delivered). Anything else (unknown_peer, refused, error) leaves
    the message in queue for retry on next run.
    """
    secret_ref = peer.get("shared_secret_ref", "")
    secret = os.environ.get(secret_ref) if secret_ref else None
    if not secret:
        return False, f"shared_secret_ref={secret_ref!r} not set in env — skipping"

    endpoint = peer.get("endpoint", "")
    if not endpoint or not endpoint.startswith(("http://", "https://")):
        return False, f"non-http endpoint={endpoint!r} — skipping"

    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {secret}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            if resp.status != 200:
                return False, f"http_status={resp.status}"
            resp_body = resp.read().decode("utf-8", errors="replace")
            try:
                resp_json = json.loads(resp_body)
            except json.JSONDecodeError:
                return False, f"non_json_response={resp_body[:200]!r}"
            if "error" in resp_json:
                return False, f"jsonrpc_error={resp_json['error']}"
            # FW-005 relay defense: HTTP 200 + JSON-RPC result is not enough — the
            # tool may return `status=unknown_peer` or `refused` inside the result
            # envelope. Parse the MCP content[0].text payload and only declare
            # success when the inner status is in the success set. Anything else
            # stays in queue for retry.
            inner_status = "unknown"
            try:
                content = (resp_json.get("result") or {}).get("content") or []
                if content and isinstance(content[0], dict):
                    inner_text = content[0].get("text", "{}")
                    inner = json.loads(inner_text)
                    inner_status = inner.get("status", "unknown")
            except (json.JSONDecodeError, IndexError, AttributeError):
                inner_status = "parse_failed"
            success_states = {"queued", "delivered"}
            if inner_status not in success_states:
                return False, f"send_message_status={inner_status}"
            return True, ""
    except urllib.error.HTTPError as e:
        return False, f"http_error={e.code} body={e.read().decode('utf-8', 'replace')[:200]}"
    except urllib.error.URLError as e:
        return False, f"url_error={e.reason}"
    except TimeoutError:
        return False, f"timeout after {HTTP_TIMEOUT_S}s"


def parse_xrange_entry(stream_lines: list[str]) -> list[tuple[str, dict[str, str]]]:
    """Parse XRANGE output into [(stream_id, {field: value, ...})].

    redis-cli text output for XRANGE:
        1) "1234567890-0"
        2)  1) "field1"
            2) "value1"
            3) "field2"
            4) "value2"

    We get this as raw lines and re-tokenize. This is brittle vs RESP but
    works for the simple field-value pairs we use.
    """
    entries: list[tuple[str, dict[str, str]]] = []
    i = 0
    n = len(stream_lines)
    while i < n:
        line = stream_lines[i].strip()
        if not line:
            i += 1
            continue
        # Stream ID line — e.g. "1234567890-0" or starts with a digit
        if line and (line[0].isdigit() or '-' in line):
            stream_id = line
            i += 1
            fields: dict[str, str] = {}
            # Subsequent lines are alternating field/value pairs until the next ID
            while i < n:
                peek = stream_lines[i].strip()
                if not peek:
                    i += 1
                    continue
                if peek and peek[0].isdigit() and "-" in peek and not peek.startswith(("from", "content", "ts", "reply", "to_")):
                    break
                if i + 1 >= n:
                    break
                fname = stream_lines[i].strip()
                fval = stream_lines[i + 1].strip()
                fields[fname] = fval
                i += 2
            entries.append((stream_id, fields))
        else:
            i += 1
    return entries


def drain_peer(peer_id: str, peer: dict[str, Any]) -> int:
    """Drain cabinet:inbox:<peer_id> by posting to the peer. Returns delivered count."""
    if not peer.get("consented_by_captain"):
        return 0
    if "send_message" not in peer.get("allowed_tools", []):
        return 0

    inbox = f"cabinet:inbox:{peer_id}"
    raw = redis_cmd("XRANGE", inbox, "-", "+", "COUNT", str(MAX_PER_PEER_PER_RUN))
    if not raw or not raw.strip():
        return 0

    entries = parse_xrange_entry(raw.splitlines())
    if not entries:
        return 0

    delivered = 0
    for stream_id, fields in entries:
        payload = {
            "jsonrpc": "2.0",
            "id": stream_id,
            "method": "tools/call",
            "params": {
                "name": "send_message",
                "arguments": {
                    "to_cabinet": peer_id,
                    "from_agent": fields.get("from_agent", "unknown"),
                    "content": fields.get("content", ""),
                    "reply_to": fields.get("reply_to") or None,
                    "_relay_origin_id": stream_id,
                    "_relay_origin_cabinet": fields.get("from_cabinet", THIS_CABINET_ID),
                    "_relay_origin_ts": fields.get("ts", ""),
                },
            },
        }
        ok, err = post_to_peer(peer, payload)
        if not ok:
            log(f"deliver-fail peer={peer_id} id={stream_id} err={err}")
            continue
        del_out = redis_cmd("XDEL", inbox, stream_id)
        if del_out is None:
            log(f"deliver-ok-but-xdel-fail peer={peer_id} id={stream_id}")
            continue
        delivered += 1
        log(f"deliver-ok peer={peer_id} id={stream_id}")

    return delivered


def main() -> None:
    peers = parse_peers_yml()
    if not peers:
        log("no peers found in peers.yml — nothing to relay")
        return
    started = time.time()
    total_delivered = 0
    for peer_id, peer in peers.items():
        try:
            delivered = drain_peer(peer_id, peer)
            total_delivered += delivered
        except Exception as e:
            log(f"peer={peer_id} relay raised {type(e).__name__}: {e}")
    elapsed = time.time() - started
    log(f"run-complete delivered={total_delivered} peers={len(peers)} elapsed={elapsed:.2f}s cabinet={THIS_CABINET_ID}")


if __name__ == "__main__":
    main()
