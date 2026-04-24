"""Library MCP Python client — FW-020.

Sync JSON-RPC 2.0 client over MCP stdio. Spawns the TypeScript Library MCP
server (cabinet/channels/library-mcp/index.ts) and speaks the same protocol
the TS client uses, so Python callers (ETL, cutover scripts) can read/write
Library Records without bypassing the public contract.

Transport: newline-delimited JSON over child-process stdin/stdout.
Lifecycle: context manager. initialize → notifications/initialized → tools/call
per MCP spec, then SIGTERM on __exit__.

Typical usage (ETL archive):

    from library_mcp_client import LibraryMcpClient
    with LibraryMcpClient(officer="cto") as client:
        rec = client.create_record(
            space="etl-snapshots",
            title="linear-SEN-247",
            content_markdown=json.dumps(raw_issue, indent=2, sort_keys=True),
            labels="linear,etl",
        )
        # rec == {"id": "42", "version": 1}

Env:
    LIBRARY_MCP_SERVER_PATH — override server path (default: the TS server
        shipped in cabinet/channels/library-mcp/index.ts).
    LIBRARY_MCP_TIMEOUT_SEC — per-call timeout (default 60s).
"""

from __future__ import annotations

import json
import logging
import os
import queue
import subprocess
import threading
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

_DEFAULT_SERVER_PATH = "/opt/founders-cabinet/cabinet/channels/library-mcp/index.ts"
_DEFAULT_TIMEOUT_SEC = 60.0
_PROTOCOL_VERSION = "2024-11-05"


class LibraryMcpError(Exception):
    """Base class for all Library MCP client errors."""


class LibraryMcpConnectionError(LibraryMcpError):
    """Subprocess died or stdio stream closed mid-request."""


class LibraryMcpProtocolError(LibraryMcpError):
    """Malformed JSON-RPC response, unexpected shape, or id mismatch."""


class LibraryMcpCallError(LibraryMcpError):
    """Server returned isError=true on a tool call."""


class LibraryMcpAccessError(LibraryMcpCallError):
    """Access denied by library.sh access_rules."""


class LibraryMcpTimeoutError(LibraryMcpError):
    """Request exceeded timeout without a response."""


class LibraryMcpClient:
    """Synchronous MCP client for the Library server.

    Context-manager only. One subprocess per client instance; reuse the
    instance for multiple calls to amortize the ~500ms bun startup cost.
    Not thread-safe — one caller per instance.
    """

    def __init__(
        self,
        officer: str = "system",
        server_path: Optional[str] = None,
        timeout_sec: Optional[float] = None,
    ):
        self._officer = officer
        self._server_path = server_path or os.environ.get(
            "LIBRARY_MCP_SERVER_PATH", _DEFAULT_SERVER_PATH
        )
        timeout_env = os.environ.get("LIBRARY_MCP_TIMEOUT_SEC")
        self._timeout_sec = (
            timeout_sec
            if timeout_sec is not None
            else (float(timeout_env) if timeout_env else _DEFAULT_TIMEOUT_SEC)
        )
        self._proc: Optional[subprocess.Popen[bytes]] = None
        self._next_id = 1
        self._stderr_drain_thread: Optional[threading.Thread] = None
        self._stdout_reader_thread: Optional[threading.Thread] = None
        # Reader thread posts (line_bytes | None-on-EOF) onto this queue; the
        # main thread dequeues with timeout to enforce per-call deadlines
        # without blocking forever on a hung subprocess.
        self._rx_queue: "queue.Queue[Optional[bytes]]" = queue.Queue()
        self._stop_reader = threading.Event()

    # -- lifecycle ---------------------------------------------------------

    def __enter__(self) -> "LibraryMcpClient":
        self._spawn()
        self._initialize()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.close()

    def _spawn(self) -> None:
        path = Path(self._server_path)
        if not path.is_file():
            raise LibraryMcpConnectionError(
                f"Library MCP server not found at {self._server_path}"
            )
        env = {**os.environ, "OFFICER_NAME": self._officer}
        try:
            self._proc = subprocess.Popen(
                ["bun", "run", str(path)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                bufsize=0,
            )
        except FileNotFoundError as exc:
            raise LibraryMcpConnectionError(
                "bun binary not found on PATH — install bun to use LibraryMcpClient"
            ) from exc
        self._stderr_drain_thread = threading.Thread(
            target=self._drain_stderr, daemon=True
        )
        self._stderr_drain_thread.start()
        self._stdout_reader_thread = threading.Thread(
            target=self._drain_stdout, daemon=True
        )
        self._stdout_reader_thread.start()

    def _drain_stdout(self) -> None:
        """Read NDJSON lines from stdout into the rx queue until EOF or stop."""
        assert self._proc is not None
        if self._proc.stdout is None:
            return
        # readline() blocks until a newline is received or the stream closes.
        # We post each raw line onto the queue; main thread parses + matches ids.
        try:
            for raw in iter(self._proc.stdout.readline, b""):
                if self._stop_reader.is_set():
                    break
                self._rx_queue.put(raw)
        except Exception as exc:  # noqa: BLE001 — pipe closure during shutdown
            logger.debug("[library-mcp stdout reader] %s", exc)
        finally:
            # Sentinel: None signals EOF to any blocked consumer
            self._rx_queue.put(None)

    def _drain_stderr(self) -> None:
        """Drain server stderr to Python logger so it doesn't block the pipe."""
        assert self._proc is not None
        if self._proc.stderr is None:
            return
        for raw in iter(self._proc.stderr.readline, b""):
            try:
                line = raw.decode("utf-8", errors="replace").rstrip("\r\n")
            except Exception:
                continue
            if line:
                logger.debug("[library-mcp stderr] %s", line)

    def close(self) -> None:
        proc = self._proc
        if proc is None:
            return
        self._stop_reader.set()
        try:
            if proc.stdin is not None and not proc.stdin.closed:
                try:
                    proc.stdin.close()
                except BrokenPipeError:
                    pass
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.terminate()
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=2)
        finally:
            self._proc = None

    # -- JSON-RPC wire -----------------------------------------------------

    def _initialize(self) -> None:
        resp = self._request(
            "initialize",
            {
                "protocolVersion": _PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {
                    "name": "library-mcp-python-client",
                    "version": "1.0.0",
                },
            },
        )
        if not isinstance(resp, dict) or "result" not in resp:
            raise LibraryMcpProtocolError(f"unexpected initialize response: {resp!r}")
        # notifications/initialized is a JSON-RPC notification (no id, no response)
        self._notify("notifications/initialized", {})

    def _request(self, method: str, params: Dict[str, Any]) -> Dict[str, Any]:
        """Send a JSON-RPC request; return parsed response dict."""
        if self._proc is None or self._proc.stdin is None or self._proc.stdout is None:
            raise LibraryMcpConnectionError("client not connected (use as context manager)")
        req_id = self._next_id
        self._next_id += 1
        msg = {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": method,
            "params": params,
        }
        self._send(msg)
        return self._read_response(expected_id=req_id)

    def _notify(self, method: str, params: Dict[str, Any]) -> None:
        """Send a JSON-RPC notification (no id, no response)."""
        if self._proc is None or self._proc.stdin is None:
            raise LibraryMcpConnectionError("client not connected")
        msg = {"jsonrpc": "2.0", "method": method, "params": params}
        self._send(msg)

    def _send(self, msg: Dict[str, Any]) -> None:
        assert self._proc is not None and self._proc.stdin is not None
        payload = (json.dumps(msg) + "\n").encode("utf-8")
        try:
            self._proc.stdin.write(payload)
            self._proc.stdin.flush()
        except BrokenPipeError as exc:
            raise LibraryMcpConnectionError(
                "stdin closed — server likely exited; check stderr in logs"
            ) from exc

    def _read_response(self, expected_id: int) -> Dict[str, Any]:
        """Dequeue NDJSON lines until we see one matching expected_id.

        Background reader thread drains stdout into self._rx_queue. We loop
        against a monotonic deadline and discard:
        - blank lines (server stray newlines)
        - JSON-RPC notifications (no id field — MCP servers may emit
          notifications/message, tools/list_changed, etc. mid-session)
        - stale responses (id < expected_id — leftovers from a prior
          timed-out request that finally arrived after the client moved on)

        A response with id > expected_id is a genuine protocol violation
        (client is single-caller; server should never reply to a request
        we haven't sent yet).
        """
        deadline = time.monotonic() + self._timeout_sec
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise LibraryMcpTimeoutError(
                    f"no response within {self._timeout_sec}s (id={expected_id})"
                )
            try:
                raw = self._rx_queue.get(timeout=remaining)
            except queue.Empty:
                raise LibraryMcpTimeoutError(
                    f"no response within {self._timeout_sec}s (id={expected_id})"
                )
            if raw is None:
                raise LibraryMcpConnectionError(
                    "stdout closed before response arrived "
                    f"(id={expected_id}); server likely exited"
                )
            line = raw.rstrip(b"\r\n")
            if not line:
                continue  # blank line

            try:
                resp = json.loads(line.decode("utf-8"))
            except json.JSONDecodeError as exc:
                raise LibraryMcpProtocolError(
                    f"malformed JSON from server: {line!r}"
                ) from exc

            if not isinstance(resp, dict):
                raise LibraryMcpProtocolError(f"non-object response: {resp!r}")

            resp_id = resp.get("id")
            if resp_id is None:
                # JSON-RPC notification — no id, no response expected.
                logger.debug(
                    "library-mcp: discarding notification %s", resp.get("method")
                )
                continue
            if isinstance(resp_id, int) and resp_id < expected_id:
                # Stale response from a prior timed-out call — client has
                # already given up on it, discard without poisoning the stream.
                logger.warning(
                    "library-mcp: discarding stale response id=%d (expected %d)",
                    resp_id,
                    expected_id,
                )
                continue
            if resp_id != expected_id:
                raise LibraryMcpProtocolError(
                    f"id mismatch: expected {expected_id}, got {resp_id!r}"
                )
            if "error" in resp:
                err = resp["error"]
                raise LibraryMcpCallError(
                    f"JSON-RPC error: {err.get('message', err)} (code={err.get('code')})"
                )
            return resp

    # -- tool calls --------------------------------------------------------

    def _call_tool(self, name: str, arguments: Dict[str, Any]) -> Any:
        """Dispatch tools/call and unwrap content[0].text → JSON object."""
        resp = self._request(
            "tools/call",
            {"name": name, "arguments": arguments},
        )
        result = resp.get("result")
        if not isinstance(result, dict):
            raise LibraryMcpProtocolError(
                f"tools/call returned non-object result: {result!r}"
            )
        content = result.get("content")
        if not isinstance(content, list) or not content:
            raise LibraryMcpProtocolError(
                f"tools/call result.content empty or malformed: {content!r}"
            )
        first = content[0]
        if not isinstance(first, dict) or first.get("type") != "text":
            raise LibraryMcpProtocolError(
                f"tools/call result.content[0] not a text block: {first!r}"
            )
        text = first.get("text", "")
        if result.get("isError"):
            # Server encodes errors as {type:"text", text:"Error: <msg>"} + isError:true
            if "access denied" in text.lower():
                raise LibraryMcpAccessError(text)
            raise LibraryMcpCallError(text)
        # Server returns JSON-encoded payloads in text; parse them
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise LibraryMcpProtocolError(
                f"tool {name} returned non-JSON text: {text!r}"
            ) from exc

    def create_record(
        self,
        space: str,
        title: str,
        content_markdown: str = "",
        schema_data: Optional[Dict[str, Any]] = None,
        labels: str = "",
    ) -> Dict[str, Any]:
        """Create a new record in a Space; returns {'id': str, 'version': int}."""
        return self._call_tool(
            "library_create_record",
            {
                "space_id_or_name": space,
                "title": title,
                "content_markdown": content_markdown,
                "schema_data": json.dumps(schema_data or {}),
                "labels": labels,
            },
        )

    def list_records(self, space: str, limit: int = 50) -> List[Dict[str, Any]]:
        """List active records in a Space (newest first)."""
        return self._call_tool(
            "library_list_records",
            {"space_id_or_name": space, "limit": limit},
        )

    def search(
        self,
        query: str,
        space: Optional[str] = None,
        labels: str = "",
        limit: int = 10,
    ) -> List[Dict[str, Any]]:
        """Semantic search via voyage-4-large cosine similarity."""
        return self._call_tool(
            "library_search",
            {
                "query": query,
                "space": space or "",
                "labels": labels,
                "limit": limit,
            },
        )

    def get_record(self, record_id: str) -> Dict[str, Any]:
        """Fetch record + version history chain by id."""
        return self._call_tool("library_get_record", {"record_id": record_id})

    def list_spaces(self) -> List[Dict[str, Any]]:
        """List all Library Spaces."""
        return self._call_tool("library_list_spaces", {})

    def create_space(
        self,
        name: str,
        description: str = "",
        schema_json: Optional[Dict[str, Any]] = None,
        starter_template: str = "blank",
        access_rules: Optional[Dict[str, Any]] = None,
    ) -> Dict[str, Any]:
        """Create or upsert a Space; returns {'id': str, 'name': str}."""
        return self._call_tool(
            "library_create_space",
            {
                "name": name,
                "description": description,
                "schema_json": json.dumps(schema_json or {}),
                "starter_template": starter_template,
                "access_rules": json.dumps(access_rules or {}),
            },
        )


def ensure_space(
    client: LibraryMcpClient,
    name: str,
    description: str,
    schema_json: Optional[Dict[str, Any]] = None,
    starter_template: str = "blank",
    access_rules: Optional[Dict[str, Any]] = None,
) -> str:
    """Idempotent: return space id; create if missing. Module-level helper."""
    spaces = client.list_spaces()
    for sp in spaces:
        if sp.get("name") == name:
            return str(sp.get("id"))
    created = client.create_space(
        name=name,
        description=description,
        schema_json=schema_json,
        starter_template=starter_template,
        access_rules=access_rules,
    )
    return str(created.get("id"))
