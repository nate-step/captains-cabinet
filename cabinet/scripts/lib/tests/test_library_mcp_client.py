"""FW-020 — Library MCP Python adapter tests.

Covers:
  * LibraryMcpClient lifecycle: initialize → notifications/initialized → tools/call → close
  * Each public method: create_record, list_records, search, get_record,
    list_spaces, create_space
  * Error paths: isError=true (generic + access-denied), malformed JSON,
    id mismatch, subprocess death, timeout
  * ensure_space helper: idempotent space lookup + create-on-miss
  * etl-common archive_to_library: MCP mode (LIBRARY_MCP_ENABLED=true) routes
    to client.create_record; JSONL fallback on MCP error; ARCHIVE_TO_LIBRARY=false
    short-circuit; dry_run no-op

Transport is mocked via a fake Popen that scripts JSON-RPC reads/writes on
a pair of io.BytesIO pipes. No real bun subprocess is spawned.

Runs:
    python3 -m pytest cabinet/scripts/lib/tests/test_library_mcp_client.py
"""
from __future__ import annotations

import io
import json
import os
import sys
import threading
import time
import types
from pathlib import Path
from typing import Any, Dict, List, Optional
from unittest.mock import patch

import pytest


# ---------------------------------------------------------------------------
# Module loading (hyphenated filename — reuse conftest-style loader)
# ---------------------------------------------------------------------------

_LIB_DIR = Path(__file__).parent.parent.resolve()
if str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))

import importlib.util as _ilu  # noqa: E402


def _load(modname: str, relpath: str):
    spec = _ilu.spec_from_file_location(modname, _LIB_DIR / relpath)
    mod = _ilu.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


lmc = _load("library_mcp_client", "library-mcp-client.py")
etl_common = _load("etl_common", "etl-common.py")


# ---------------------------------------------------------------------------
# Fake subprocess — scripts responses keyed by request method
# ---------------------------------------------------------------------------


class _BlockingStdout:
    """Thread-safe buffer with blocking readline — mimics a real pipe.

    A plain BytesIO returns b"" immediately when empty; the client's
    `iter(readline, b"")` treats that as EOF and exits the reader thread
    before the main thread has enqueued any response. This wrapper makes
    readline() block on a Condition until bytes arrive or close() is
    called, matching the semantics of a real subprocess stdout pipe.
    """

    def __init__(self) -> None:
        self._buf = bytearray()
        self._cond = threading.Condition()
        self._closed = False

    def readline(self) -> bytes:
        with self._cond:
            while True:
                nl = self._buf.find(b"\n")
                if nl != -1:
                    line = bytes(self._buf[: nl + 1])
                    del self._buf[: nl + 1]
                    return line
                if self._closed:
                    # EOF: flush any trailing bytes without newline, then empty
                    if self._buf:
                        line = bytes(self._buf)
                        self._buf.clear()
                        return line
                    return b""
                self._cond.wait()

    def write(self, data: bytes) -> int:
        with self._cond:
            if self._closed:
                raise BrokenPipeError("_BlockingStdout closed")
            self._buf.extend(data)
            self._cond.notify_all()
        return len(data)

    def close(self) -> None:
        with self._cond:
            self._closed = True
            self._cond.notify_all()

    # Compatibility shims for tests that reach inside (e.g. the malformed-JSON
    # test that seeks-appends raw bytes). Our buffer is streaming, not seekable:
    # seek is a no-op; tell returns the current unread length.
    def tell(self) -> int:
        return len(self._buf)

    def seek(self, pos: int, whence: int = 0) -> None:  # noqa: ARG002
        return


class FakePopen:
    """Mimics subprocess.Popen for MCP stdio testing.

    stdin is a `_CaptureStdin` wrapper the client writes to (we parse each
    outbound NDJSON request and push the scripted response onto stdout).
    stdout is a `_BlockingStdout` so the client's background reader thread
    blocks on readline() until we enqueue a response (matches real pipe
    semantics; a BytesIO would return b"" immediately and kill the reader).

    Responses are a list of dicts OR a callable mapping request dict → response.
    If callable, it is invoked per outbound request (in-order) so tests can
    assert server state transitions.
    """

    def __init__(
        self,
        responses: List[Any],
        *,
        die_after: Optional[int] = None,
        delay_sec: float = 0.0,
    ):
        self._responses = list(responses)
        self._die_after = die_after
        self._delay_sec = delay_sec
        self._requests_received = 0
        self._initial_bytes = _BlockingStdout()
        self.stdin = _CaptureStdin(self)
        self.stdout = self._initial_bytes
        self.stderr = _BlockingStdout()
        self._terminated = False
        self._killed = False
        self._exit_code: Optional[int] = None
        self.pid = 99999

    def _enqueue_response(self, req: Dict[str, Any]) -> None:
        """Called when a line is written to stdin — pushes next response onto stdout."""
        self._requests_received += 1
        if self._die_after is not None and self._requests_received > self._die_after:
            self._exit_code = 1
            # Close stdout so reader thread's readline returns b"" → sentinel None
            self._initial_bytes.close()
            return
        if not self._responses:
            return
        resp = self._responses.pop(0)
        if callable(resp):
            resp = resp(req)
        if resp is None:
            return  # notification — no response expected
        if self._delay_sec > 0:
            time.sleep(self._delay_sec)
        self._initial_bytes.write((json.dumps(resp) + "\n").encode("utf-8"))

    def wait(self, timeout: Optional[float] = None) -> int:
        # Signal EOF so reader thread can unblock during close()
        self._initial_bytes.close()
        self.stderr.close()
        return self._exit_code if self._exit_code is not None else 0

    def terminate(self) -> None:
        self._terminated = True
        self._exit_code = 0
        self._initial_bytes.close()
        self.stderr.close()

    def kill(self) -> None:
        self._killed = True
        self._exit_code = -9
        self._initial_bytes.close()
        self.stderr.close()


class _CaptureStdin:
    """Stdin wrapper that invokes FakePopen._enqueue_response on each write."""

    def __init__(self, parent: FakePopen):
        self._parent = parent
        self._buf = bytearray()
        self.closed = False

    def write(self, data: bytes) -> int:
        if self.closed:
            raise BrokenPipeError("stdin closed")
        self._buf.extend(data)
        # Process any complete lines
        while True:
            nl = self._buf.find(b"\n")
            if nl == -1:
                break
            line = bytes(self._buf[:nl])
            del self._buf[: nl + 1]
            try:
                msg = json.loads(line.decode("utf-8"))
            except json.JSONDecodeError:
                continue
            self._parent._enqueue_response(msg)
        return len(data)

    def flush(self) -> None:
        pass

    def close(self) -> None:
        self.closed = True


# ---------------------------------------------------------------------------
# Helper fixtures
# ---------------------------------------------------------------------------

def _make_ok_initialize() -> Dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {
            "protocolVersion": "2024-11-05",
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "library-mcp", "version": "1.0.0"},
        },
    }


def _ok_call_response(req_id: int, payload: Any) -> Dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "content": [{"type": "text", "text": json.dumps(payload)}],
        },
    }


def _error_call_response(req_id: int, message: str) -> Dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "result": {
            "content": [{"type": "text", "text": f"Error: {message}"}],
            "isError": True,
        },
    }


def _make_client_with_popen(fake: FakePopen) -> lmc.LibraryMcpClient:
    """Spawn a client with subprocess.Popen + Path.is_file patched.

    Patches both so tests work in environments where the real MCP server
    path (/opt/...) isn't present — crucial for portable CI runs.
    """
    popen_patcher = patch.object(lmc.subprocess, "Popen", return_value=fake)
    isfile_patcher = patch.object(lmc.Path, "is_file", return_value=True)
    popen_patcher.start()
    isfile_patcher.start()
    client = lmc.LibraryMcpClient(officer="test")
    # Initialize via __enter__ (which calls _spawn + _initialize)
    client.__enter__()
    client._test_patcher = popen_patcher  # type: ignore[attr-defined]
    client._isfile_patcher = isfile_patcher  # type: ignore[attr-defined]
    return client


def _teardown_client(client: lmc.LibraryMcpClient) -> None:
    try:
        client.close()
    except Exception:
        pass
    for attr in ("_test_patcher", "_isfile_patcher"):
        patcher = getattr(client, attr, None)
        if patcher is not None:
            try:
                patcher.stop()
            except RuntimeError:
                pass  # already stopped


# ---------------------------------------------------------------------------
# Lifecycle — initialize + notification + tools/call + close
# ---------------------------------------------------------------------------

def test_initialize_sends_correct_request_and_parses_response():
    # Response #1: initialize response. No response for notifications/initialized.
    fake = FakePopen([_make_ok_initialize(), None])
    client = _make_client_with_popen(fake)
    try:
        # After __enter__, client should have sent initialize + notifications/initialized
        # Received a valid response.
        assert client._next_id == 2, "next_id should advance past initialize (id=1)"
    finally:
        _teardown_client(client)


def test_initialize_sends_protocol_version_and_client_info():
    captured_requests: List[Dict[str, Any]] = []

    def capture(req):
        captured_requests.append(req)
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        return None

    fake = FakePopen([capture, capture])
    client = _make_client_with_popen(fake)
    try:
        init_req = next(r for r in captured_requests if r.get("method") == "initialize")
        assert init_req["jsonrpc"] == "2.0"
        assert init_req["id"] == 1
        assert init_req["params"]["protocolVersion"] == "2024-11-05"
        assert init_req["params"]["clientInfo"]["name"] == "library-mcp-python-client"

        notif = next(
            r for r in captured_requests if r.get("method") == "notifications/initialized"
        )
        assert "id" not in notif, "notifications MUST NOT carry an id (JSON-RPC spec)"
    finally:
        _teardown_client(client)


def test_close_terminates_subprocess_gracefully():
    fake = FakePopen([_make_ok_initialize(), None])
    client = _make_client_with_popen(fake)
    client.close()
    # Fake wait() returns 0 for a clean close; stdin should be closed
    assert fake.stdin.closed
    # Idempotent — calling close again should not raise
    client.close()


# ---------------------------------------------------------------------------
# tools/call — each public method
# ---------------------------------------------------------------------------

def test_create_record_sends_correct_tools_call():
    captured: List[Dict[str, Any]] = []

    def responder(req):
        captured.append(req)
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        if req.get("method") == "tools/call":
            return _ok_call_response(req["id"], {"id": "42", "version": 1})
        return None

    fake = FakePopen([responder, responder, responder])
    client = _make_client_with_popen(fake)
    try:
        result = client.create_record(
            space="etl-snapshots",
            title="linear-SEN-247",
            content_markdown="raw json body",
            schema_data={"source": "linear"},
            labels="linear,etl",
        )
        assert result == {"id": "42", "version": 1}
        call_req = next(r for r in captured if r.get("method") == "tools/call")
        args = call_req["params"]["arguments"]
        assert call_req["params"]["name"] == "library_create_record"
        assert args["space_id_or_name"] == "etl-snapshots"
        assert args["title"] == "linear-SEN-247"
        assert args["content_markdown"] == "raw json body"
        assert json.loads(args["schema_data"]) == {"source": "linear"}
        assert args["labels"] == "linear,etl"
    finally:
        _teardown_client(client)


def test_list_records_returns_parsed_list():
    payload = [{"id": "1", "title": "a"}, {"id": "2", "title": "b"}]

    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        return _ok_call_response(req["id"], payload)

    fake = FakePopen([responder] * 3)
    client = _make_client_with_popen(fake)
    try:
        result = client.list_records(space="etl-snapshots", limit=10)
        assert result == payload
    finally:
        _teardown_client(client)


def test_search_sends_query_with_all_optional_args():
    captured: List[Dict[str, Any]] = []

    def responder(req):
        captured.append(req)
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        return _ok_call_response(req["id"], [])

    fake = FakePopen([responder] * 3)
    client = _make_client_with_popen(fake)
    try:
        client.search(query="test", space="etl-snapshots", labels="linear", limit=5)
        call = next(r for r in captured if r.get("method") == "tools/call")
        args = call["params"]["arguments"]
        assert args["query"] == "test"
        assert args["space"] == "etl-snapshots"
        assert args["labels"] == "linear"
        assert args["limit"] == 5
    finally:
        _teardown_client(client)


def test_get_record_returns_full_record():
    payload = {"id": "42", "title": "linear-SEN-247", "version": 1, "history": []}

    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        return _ok_call_response(req["id"], payload)

    fake = FakePopen([responder] * 3)
    client = _make_client_with_popen(fake)
    try:
        assert client.get_record("42") == payload
    finally:
        _teardown_client(client)


def test_list_spaces_empty_result():
    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        return _ok_call_response(req["id"], [])

    fake = FakePopen([responder] * 3)
    client = _make_client_with_popen(fake)
    try:
        assert client.list_spaces() == []
    finally:
        _teardown_client(client)


def test_create_space_returns_id_and_name():
    payload = {"id": "5", "name": "etl-snapshots"}

    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        return _ok_call_response(req["id"], payload)

    fake = FakePopen([responder] * 3)
    client = _make_client_with_popen(fake)
    try:
        result = client.create_space(
            name="etl-snapshots",
            description="Test",
            schema_json={"fields": []},
        )
        assert result == payload
    finally:
        _teardown_client(client)


# ---------------------------------------------------------------------------
# Error paths
# ---------------------------------------------------------------------------

def test_is_error_raises_call_error():
    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        return _error_call_response(req["id"], "Record not found: 999")

    fake = FakePopen([responder] * 3)
    client = _make_client_with_popen(fake)
    try:
        with pytest.raises(lmc.LibraryMcpCallError) as exc_info:
            client.get_record("999")
        assert "Record not found" in str(exc_info.value)
    finally:
        _teardown_client(client)


def test_access_denied_raises_access_error_subclass():
    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        return _error_call_response(req["id"], "access denied — officer cto cannot write to space 'business-brain'")

    fake = FakePopen([responder] * 3)
    client = _make_client_with_popen(fake)
    try:
        with pytest.raises(lmc.LibraryMcpAccessError) as exc_info:
            client.create_record(space="business-brain", title="x")
        # Access error is a subclass of Call error
        assert isinstance(exc_info.value, lmc.LibraryMcpCallError)
    finally:
        _teardown_client(client)


def test_id_mismatch_raises_protocol_error():
    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        # Return wrong id (id=99 instead of echoing req id)
        return {
            "jsonrpc": "2.0",
            "id": 99,
            "result": {"content": [{"type": "text", "text": "{}"}]},
        }

    fake = FakePopen([responder] * 3)
    client = _make_client_with_popen(fake)
    try:
        with pytest.raises(lmc.LibraryMcpProtocolError) as exc_info:
            client.list_spaces()
        assert "id mismatch" in str(exc_info.value)
    finally:
        _teardown_client(client)


def test_malformed_json_raises_protocol_error():
    fake = FakePopen([_make_ok_initialize(), None])
    client = _make_client_with_popen(fake)
    try:
        # Inject malformed bytes directly into stdout
        pos = fake._initial_bytes.tell()
        fake._initial_bytes.seek(0, io.SEEK_END)
        fake._initial_bytes.write(b"not valid json\n")
        fake._initial_bytes.seek(pos)
        # Also seed a dummy response-placeholder so _enqueue_response doesn't overwrite
        fake._responses = [None]
        with pytest.raises(lmc.LibraryMcpProtocolError) as exc_info:
            client.list_spaces()
        assert "malformed JSON" in str(exc_info.value)
    finally:
        _teardown_client(client)


def test_tool_result_content_not_json_raises_protocol_error():
    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        return {
            "jsonrpc": "2.0",
            "id": req["id"],
            "result": {"content": [{"type": "text", "text": "not-json-here"}]},
        }

    fake = FakePopen([responder] * 3)
    client = _make_client_with_popen(fake)
    try:
        with pytest.raises(lmc.LibraryMcpProtocolError) as exc_info:
            client.list_spaces()
        assert "non-JSON text" in str(exc_info.value)
    finally:
        _teardown_client(client)


def test_subprocess_death_mid_request_raises_connection_error():
    # die_after=1 means: after 1 request (the initialize), the "server" stops
    # responding. The next tools/call will see stdout EOF.
    fake = FakePopen([_make_ok_initialize(), None], die_after=2)
    client = _make_client_with_popen(fake)
    try:
        with pytest.raises(lmc.LibraryMcpConnectionError) as exc_info:
            client.list_spaces()
        assert "closed" in str(exc_info.value).lower()
    finally:
        _teardown_client(client)


def test_timeout_raises_timeout_error_and_stale_reply_is_discarded():
    """A late reply from a timed-out call must not poison the next call.

    Covers: H-1 (stale-reply drain). On timeout the server-eventual reply
    sits in rx_queue; the next _read_response must discard responses whose
    id is < expected_id rather than raising id-mismatch protocol errors.

    The late reply must be SCHEDULED (via Timer), not synchronously slept,
    because the responder runs inside _CaptureStdin.write() on the client's
    main thread — a sync sleep would block stdin.write itself, not delay
    the server's reply.
    """
    state = {"delay_once": True}
    fake_ref: Dict[str, Any] = {}

    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        if state["delay_once"]:
            state["delay_once"] = False
            late_resp = _ok_call_response(req["id"], [])
            threading.Timer(0.3, lambda: fake_ref["f"]._initial_bytes.write(
                (json.dumps(late_resp) + "\n").encode("utf-8")
            )).start()
            return None
        return _ok_call_response(req["id"], [{"id": "late", "name": "after-timeout"}])

    fake = FakePopen([responder] * 5)
    fake_ref["f"] = fake
    popen_patcher = patch.object(lmc.subprocess, "Popen", return_value=fake)
    isfile_patcher = patch.object(lmc.Path, "is_file", return_value=True)
    popen_patcher.start()
    isfile_patcher.start()
    try:
        client = lmc.LibraryMcpClient(officer="test", timeout_sec=0.1)
        client.__enter__()
        try:
            with pytest.raises(lmc.LibraryMcpTimeoutError):
                client.list_spaces()
            # Give the delayed first response time to arrive in rx_queue
            time.sleep(0.4)
            # Next call must discard the stale id and return the fresh response.
            result = client.list_spaces()
            assert result == [{"id": "late", "name": "after-timeout"}]
        finally:
            client.close()
    finally:
        popen_patcher.stop()
        isfile_patcher.stop()


def test_notification_from_server_is_discarded():
    """Server-initiated notification (no id) must not raise id-mismatch.

    Covers: H-2. MCP spec allows the server to emit notifications
    (notifications/message, tools/list_changed). Client must discard and
    keep reading until it sees the expected response id.
    """
    state = {"injected": False}

    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        if not state["injected"]:
            state["injected"] = True
            # Inject an unsolicited notification directly onto stdout, then
            # the real response on the same call. Client must skip notif
            # and land on the real id.
            notif = {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info"}}
            fake._initial_bytes.write((json.dumps(notif) + "\n").encode("utf-8"))
        return _ok_call_response(req["id"], [{"id": "1", "name": "ok"}])

    fake = FakePopen([responder] * 3)
    client = _make_client_with_popen(fake)
    try:
        result = client.list_spaces()
        assert result == [{"id": "1", "name": "ok"}]
    finally:
        _teardown_client(client)


def test_jsonrpc_error_response_raises_call_error():
    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        return {
            "jsonrpc": "2.0",
            "id": req["id"],
            "error": {"code": -32601, "message": "Method not found"},
        }

    fake = FakePopen([responder] * 3)
    client = _make_client_with_popen(fake)
    try:
        with pytest.raises(lmc.LibraryMcpCallError) as exc_info:
            client.list_spaces()
        assert "Method not found" in str(exc_info.value)
    finally:
        _teardown_client(client)


# ---------------------------------------------------------------------------
# ensure_space helper — idempotent space lookup
# ---------------------------------------------------------------------------

def test_ensure_space_returns_existing_id_without_creating():
    create_called = [False]

    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        if req["params"]["name"] == "library_list_spaces":
            return _ok_call_response(
                req["id"],
                [{"id": "5", "name": "etl-snapshots", "description": ""}],
            )
        if req["params"]["name"] == "library_create_space":
            create_called[0] = True
            return _ok_call_response(req["id"], {"id": "99", "name": "NEW"})
        return None

    fake = FakePopen([responder] * 5)
    client = _make_client_with_popen(fake)
    try:
        space_id = lmc.ensure_space(client, name="etl-snapshots", description="x")
        assert space_id == "5"
        assert create_called[0] is False, "ensure_space must NOT create when space exists"
    finally:
        _teardown_client(client)


def test_ensure_space_creates_when_missing():
    create_called = [False]

    def responder(req):
        if req.get("method") == "initialize":
            return _make_ok_initialize()
        if req.get("method") == "notifications/initialized":
            return None
        if req["params"]["name"] == "library_list_spaces":
            return _ok_call_response(req["id"], [{"id": "1", "name": "other"}])
        if req["params"]["name"] == "library_create_space":
            create_called[0] = True
            return _ok_call_response(req["id"], {"id": "7", "name": "etl-snapshots"})
        return None

    fake = FakePopen([responder] * 5)
    client = _make_client_with_popen(fake)
    try:
        space_id = lmc.ensure_space(client, name="etl-snapshots", description="x")
        assert space_id == "7"
        assert create_called[0] is True
    finally:
        _teardown_client(client)


# ---------------------------------------------------------------------------
# archive_to_library integration — MCP vs JSONL routing
# ---------------------------------------------------------------------------

def _reset_etl_mcp_state():
    etl_common._mcp_client = None
    etl_common._mcp_space_ensured = False


def test_archive_to_library_dry_run_is_noop(tmp_path, monkeypatch):
    _reset_etl_mcp_state()
    monkeypatch.chdir(tmp_path)
    called = []
    monkeypatch.setattr(etl_common, "_get_mcp_client", lambda: called.append("mcp"))
    etl_common.archive_to_library(
        conn=None,
        source_record={"external_ref": "X-1", "external_source": "linear"},
        dry_run=True,
    )
    assert called == []


def test_archive_to_library_disabled_env_is_noop(tmp_path, monkeypatch):
    _reset_etl_mcp_state()
    monkeypatch.chdir(tmp_path)
    monkeypatch.setenv("ARCHIVE_TO_LIBRARY", "false")
    called = []
    monkeypatch.setattr(etl_common, "_get_mcp_client", lambda: called.append("mcp"))
    etl_common.archive_to_library(
        conn=None,
        source_record={"external_ref": "X-1", "external_source": "linear"},
    )
    assert called == []


def test_archive_to_library_jsonl_default(tmp_path, monkeypatch):
    _reset_etl_mcp_state()
    monkeypatch.setenv("ARCHIVE_TO_LIBRARY", "true")
    monkeypatch.delenv("LIBRARY_MCP_ENABLED", raising=False)
    # Point archive_dir at tmp_path by monkeypatching Path resolution
    # (etl-common computes base = parents[3]; easier to capture tmp via chdir not reliable —
    # we mock the output write directly to check the JSONL path is taken).
    written = []
    real_open = Path.open

    def fake_open(self, *args, **kwargs):
        if "039-migration-snapshots" in str(self):
            written.append(self)
            # Redirect to tmp to avoid polluting real archive dir
            real_target = tmp_path / self.name
            return real_target.open(*args, **kwargs)
        return real_open(self, *args, **kwargs)

    monkeypatch.setattr(Path, "open", fake_open)
    monkeypatch.setattr(
        Path,
        "mkdir",
        lambda self, *a, **kw: None if "039-migration-snapshots" in str(self) else Path.mkdir(self, *a, **kw),
    )

    etl_common.archive_to_library(
        conn=None,
        source_record={
            "external_ref": "SEN-247",
            "external_source": "linear",
            "title": "Test",
        },
    )
    assert len(written) == 1
    assert "linear-SEN-247.json" in str(written[0])


def test_archive_to_library_mcp_mode_calls_create_record(tmp_path, monkeypatch):
    _reset_etl_mcp_state()
    monkeypatch.setenv("ARCHIVE_TO_LIBRARY", "true")
    monkeypatch.setenv("LIBRARY_MCP_ENABLED", "true")

    # Fake client that records the create_record call
    class FakeClient:
        def __init__(self):
            self.create_calls: List[Dict[str, Any]] = []
            self.list_spaces_called = False
            self.created_spaces: List[str] = []

        def list_spaces(self):
            self.list_spaces_called = True
            return [{"id": "5", "name": "etl-snapshots"}]  # already exists

        def create_space(self, **kwargs):
            self.created_spaces.append(kwargs["name"])
            return {"id": "99", "name": kwargs["name"]}

        def create_record(self, **kwargs):
            self.create_calls.append(kwargs)
            return {"id": "77", "version": 1}

    fake = FakeClient()
    monkeypatch.setattr(etl_common, "_get_mcp_client", lambda: fake)

    etl_common.archive_to_library(
        conn=None,
        source_record={
            "external_ref": "FW-024",
            "external_source": "github-issues",
            "title": "Test",
        },
    )
    assert len(fake.create_calls) == 1
    call = fake.create_calls[0]
    assert call["space"] == "etl-snapshots"
    assert call["title"] == "github-issues-FW-024"
    assert call["labels"] == "github-issues"
    # content_markdown is the JSON-serialized record
    body = json.loads(call["content_markdown"])
    assert body["external_ref"] == "FW-024"
    # Space was NOT created (already existed)
    assert fake.created_spaces == []
    assert fake.list_spaces_called


def test_archive_to_library_mcp_mode_creates_space_when_missing(tmp_path, monkeypatch):
    _reset_etl_mcp_state()
    monkeypatch.setenv("ARCHIVE_TO_LIBRARY", "true")
    monkeypatch.setenv("LIBRARY_MCP_ENABLED", "true")

    class FakeClient:
        def __init__(self):
            self.create_calls: List[Dict[str, Any]] = []
            self.created_spaces: List[str] = []

        def list_spaces(self):
            return [{"id": "1", "name": "briefs"}]  # etl-snapshots missing

        def create_space(self, **kwargs):
            self.created_spaces.append(kwargs["name"])
            return {"id": "99", "name": kwargs["name"]}

        def create_record(self, **kwargs):
            self.create_calls.append(kwargs)
            return {"id": "77", "version": 1}

    fake = FakeClient()
    monkeypatch.setattr(etl_common, "_get_mcp_client", lambda: fake)

    etl_common.archive_to_library(
        conn=None,
        source_record={"external_ref": "SEN-1", "external_source": "linear"},
    )
    assert fake.created_spaces == ["etl-snapshots"]
    assert len(fake.create_calls) == 1


def test_archive_to_library_mcp_error_falls_back_to_jsonl(tmp_path, monkeypatch):
    _reset_etl_mcp_state()
    monkeypatch.setenv("ARCHIVE_TO_LIBRARY", "true")
    monkeypatch.setenv("LIBRARY_MCP_ENABLED", "true")

    class BrokenClient:
        def list_spaces(self):
            raise lmc.LibraryMcpConnectionError("server died")

        def create_space(self, **kwargs):
            raise AssertionError("should not be called")

        def create_record(self, **kwargs):
            raise AssertionError("should not be called")

    monkeypatch.setattr(etl_common, "_get_mcp_client", lambda: BrokenClient())

    # Capture the JSONL fallback write
    written = []
    real_open = Path.open

    def fake_open(self, *args, **kwargs):
        if "039-migration-snapshots" in str(self):
            written.append(self)
            return (tmp_path / self.name).open(*args, **kwargs)
        return real_open(self, *args, **kwargs)

    monkeypatch.setattr(Path, "open", fake_open)
    monkeypatch.setattr(
        Path,
        "mkdir",
        lambda self, *a, **kw: None if "039-migration-snapshots" in str(self) else Path.mkdir(self, *a, **kw),
    )

    etl_common.archive_to_library(
        conn=None,
        source_record={"external_ref": "SEN-1", "external_source": "linear"},
    )
    assert len(written) == 1, "MCP error must trigger JSONL fallback"


def test_archive_to_library_path_escape_sanitized(tmp_path, monkeypatch):
    _reset_etl_mcp_state()
    monkeypatch.setenv("ARCHIVE_TO_LIBRARY", "true")
    monkeypatch.setenv("LIBRARY_MCP_ENABLED", "true")

    class FakeClient:
        def __init__(self):
            self.create_calls: List[Dict[str, Any]] = []

        def list_spaces(self):
            return [{"id": "5", "name": "etl-snapshots"}]

        def create_space(self, **kwargs):
            return {"id": "99", "name": kwargs["name"]}

        def create_record(self, **kwargs):
            self.create_calls.append(kwargs)
            return {"id": "77", "version": 1}

    fake = FakeClient()
    monkeypatch.setattr(etl_common, "_get_mcp_client", lambda: fake)

    etl_common.archive_to_library(
        conn=None,
        source_record={
            "external_ref": "../../etc/passwd",
            "external_source": "linear",
        },
    )
    # The title should have path-escape chars replaced with underscores
    title = fake.create_calls[0]["title"]
    assert ".." not in title
    assert "/" not in title
    # And the leading dash should be stripped (flag-injection fence)
    assert not title.startswith("-")
