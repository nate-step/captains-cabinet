#!/usr/bin/env python3
"""Unit tests for cabinet/mcp-server/host-tools.py (Spec 035 Phase A).

host-tools.py is the CoS-only MCP module that brokers root-level host
operations to the host-agent daemon over a Unix socket. Six tools sit
in front of _send_request(); the runbook and adversary review both flag
args-validation + connection-error handling + streaming reassembly as
the surface most likely to regress silently (the host-agent itself has
coverage in host-agent/test_server.py).

This harness exercises every branch we CAN hit without a real socket:
  - 4 pure helpers (_collect_stream, _format_result, make_tool_result,
    get_tool) — trivial but pinned so refactors don't break protocol shape
  - 6 handler args-validation short-circuits (one per host_* tool) — the
    whole point of the module, since any missing-field regression would
    leak undefined args through to host-agent and generate useless errors
  - ConnectionError path on non-streaming + streaming handlers — the
    'socket missing' case is how CoS notices the host-agent is down
  - Streaming aggregation for tail_logs + read_file — _collect_stream's
    output is the user-facing payload, easy to mis-wire
  - Protocol dispatcher (handle): initialize, tools/list, tools/call
    success + handler-raise + unknown-tool, unknown-method, notifications
  - TOOLS catalog shape: 6 tools, each with name/description/inputSchema/
    handler — keeps MCP contract stable

Hyphen in 'host-tools.py' forbids plain import; we use importlib.util
the same way host-tools.py itself loads modules elsewhere in the repo.

Runs as a standalone script (matches test_server.py pattern) — no pytest
dependency, invoked by CI via `python3 file.py`. Exit 0 on all-pass,
exit 1 on any failure.
"""
from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path


_MODULE_PATH = Path(__file__).parent / "host-tools.py"


def _load_module():
    """Load host-tools.py via importlib (hyphen prevents plain import)."""
    spec = importlib.util.spec_from_file_location("host_tools_under_test", _MODULE_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ht = _load_module()


# ── Pure helpers ──────────────────────────────────────────────────────────────

class CollectStreamTests(unittest.TestCase):
    def test_empty_list(self):
        self.assertEqual(ht._collect_stream([]), "")

    def test_single_chunk(self):
        self.assertEqual(ht._collect_stream([{"chunk": "hello"}]), "hello")

    def test_multi_chunk_concatenation(self):
        msgs = [{"chunk": "one "}, {"chunk": "two "}, {"chunk": "three"}]
        self.assertEqual(ht._collect_stream(msgs), "one two three")

    def test_skips_non_chunk_messages(self):
        """'done' messages (end of stream) must NOT be treated as content."""
        msgs = [
            {"chunk": "line1\n"},
            {"chunk": "line2\n"},
            {"done": True, "total_bytes": 12},
        ]
        self.assertEqual(ht._collect_stream(msgs), "line1\nline2\n")


class FormatResultTests(unittest.TestCase):
    def test_dict_becomes_json(self):
        out = ht._format_result({"ok": True, "exit": 0})
        self.assertEqual(json.loads(out), {"ok": True, "exit": 0})

    def test_list_becomes_json(self):
        out = ht._format_result([1, 2, 3])
        self.assertEqual(json.loads(out), [1, 2, 3])

    def test_string_passthrough(self):
        self.assertEqual(ht._format_result("already a string"), "already a string")

    def test_int_becomes_string(self):
        self.assertEqual(ht._format_result(42), "42")


class MakeToolResultTests(unittest.TestCase):
    def test_envelope_shape(self):
        """MCP text content wrapper — dict with 'content' list of type/text parts."""
        result = ht.make_tool_result({"ok": True})
        self.assertIn("content", result)
        self.assertEqual(len(result["content"]), 1)
        self.assertEqual(result["content"][0]["type"], "text")
        self.assertEqual(json.loads(result["content"][0]["text"]), {"ok": True})


class GetToolTests(unittest.TestCase):
    def test_known_tool(self):
        tool = ht.get_tool("host__run")
        self.assertIsNotNone(tool)
        self.assertEqual(tool["name"], "host__run")
        self.assertTrue(callable(tool["handler"]))

    def test_unknown_tool(self):
        self.assertIsNone(ht.get_tool("host__does_not_exist"))


# ── TOOLS catalog shape ──────────────────────────────────────────────────────

class ToolsCatalogTests(unittest.TestCase):
    """All 6 tools must be present with complete MCP-tool shape."""

    EXPECTED = {
        "host__run", "host__rebuild_service", "host__restart_officer",
        "host__tail_logs", "host__edit_file", "host__read_file",
    }

    def test_six_tools(self):
        names = {t["name"] for t in ht.TOOLS}
        self.assertEqual(names, self.EXPECTED)

    def test_each_tool_has_required_fields(self):
        for t in ht.TOOLS:
            with self.subTest(tool=t.get("name", "?")):
                self.assertIn("name", t)
                self.assertIn("description", t)
                self.assertIn("inputSchema", t)
                self.assertIn("handler", t)
                self.assertTrue(callable(t["handler"]))
                self.assertEqual(t["inputSchema"]["type"], "object")


# ── Handler args-validation ──────────────────────────────────────────────────

class ArgsValidationTests(unittest.TestCase):
    """Every host_* handler short-circuits on missing required args BEFORE
    touching the socket. This is the invariant that keeps malformed calls
    from reaching the host-agent, where they would generate opaque errors."""

    def test_run_requires_cmd(self):
        r = ht.host_run({})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "args-invalid")
        self.assertIn("cmd", r["error"])

    def test_rebuild_service_requires_name(self):
        r = ht.host_rebuild_service({})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "args-invalid")
        self.assertIn("name", r["error"])

    def test_restart_officer_requires_name(self):
        r = ht.host_restart_officer({})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "args-invalid")
        self.assertIn("name", r["error"])

    def test_tail_logs_requires_service(self):
        r = ht.host_tail_logs({})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "args-invalid")
        self.assertIn("service", r["error"])

    def test_edit_file_requires_path(self):
        r = ht.host_edit_file({"diff": "--- a\n+++ b\n"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "args-invalid")
        self.assertIn("path", r["error"])

    def test_edit_file_requires_diff(self):
        r = ht.host_edit_file({"path": "/tmp/f"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "args-invalid")
        self.assertIn("diff", r["error"])

    def test_read_file_requires_path(self):
        r = ht.host_read_file({})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "args-invalid")
        self.assertIn("path", r["error"])


# ── ConnectionError path (socket missing / host-agent down) ──────────────────

class ConnectionErrorTests(unittest.TestCase):
    """When _send_request raises ConnectionError (socket missing or daemon
    down), every handler must translate it to an 'exec-error' payload so
    callers get a structured response instead of an exception."""

    def setUp(self):
        self._orig = ht._send_request

    def tearDown(self):
        ht._send_request = self._orig

    def _raise(self, *a, **kw):
        raise ConnectionError("test: socket missing")

    def test_run_translates_connection_error(self):
        ht._send_request = self._raise
        r = ht.host_run({"cmd": "true"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "exec-error")
        self.assertIn("socket missing", r["error"])

    def test_rebuild_service_translates_connection_error(self):
        ht._send_request = self._raise
        r = ht.host_rebuild_service({"name": "web"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "exec-error")

    def test_restart_officer_translates_connection_error(self):
        ht._send_request = self._raise
        r = ht.host_restart_officer({"name": "cto"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "exec-error")

    def test_tail_logs_translates_connection_error(self):
        """Streaming handler must ALSO catch ConnectionError (not just
        the non-streaming branch)."""
        ht._send_request = self._raise
        r = ht.host_tail_logs({"service": "web"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "exec-error")

    def test_edit_file_translates_connection_error(self):
        ht._send_request = self._raise
        r = ht.host_edit_file({"path": "/tmp/f", "diff": "--- a\n+++ b\n"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "exec-error")

    def test_read_file_translates_connection_error(self):
        ht._send_request = self._raise
        r = ht.host_read_file({"path": "/tmp/f"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "exec-error")


# ── Streaming aggregation (tail_logs + read_file) ────────────────────────────

class StreamingAggregationTests(unittest.TestCase):
    """tail_logs + read_file must collapse chunk lists into a single string
    payload with total_bytes + error_code carried from the 'done' message."""

    def setUp(self):
        self._orig = ht._send_request

    def tearDown(self):
        ht._send_request = self._orig

    def test_tail_logs_aggregates_chunks(self):
        ht._send_request = lambda tool, args: [
            {"chunk": "2026-04-24 web starting\n"},
            {"chunk": "2026-04-24 web ready\n"},
            {"done": True, "total_bytes": 44},
        ]
        r = ht.host_tail_logs({"service": "web"})
        self.assertTrue(r["ok"])
        self.assertEqual(r["stdout"], "2026-04-24 web starting\n2026-04-24 web ready\n")
        self.assertEqual(r["total_bytes"], 44)
        self.assertIsNone(r["error_code"])

    def test_tail_logs_passes_through_non_streaming_error(self):
        """If the daemon rejects the call before streaming starts (e.g.
        unknown service), it returns a dict not a list — must pass through
        unmodified."""
        ht._send_request = lambda tool, args: {
            "ok": False, "error_code": "unknown-service", "error": "no such svc"
        }
        r = ht.host_tail_logs({"service": "ghost"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "unknown-service")

    def test_read_file_aggregates_chunks_and_truncation_flag(self):
        ht._send_request = lambda tool, args: [
            {"chunk": "hello world\n"},
            {
                "done": True,
                "total_bytes": 12,
                "truncated": True,
                "truncated_at_bytes": 12,
            },
        ]
        r = ht.host_read_file({"path": "/tmp/big"})
        self.assertTrue(r["ok"])
        self.assertEqual(r["content"], "hello world\n")
        self.assertEqual(r["total_bytes"], 12)
        self.assertTrue(r["truncated"])
        self.assertEqual(r["truncated_at_bytes"], 12)

    def test_read_file_error_code_carries_through(self):
        """file-too-large / file-not-found come through the 'done' message."""
        ht._send_request = lambda tool, args: [
            {"done": True, "total_bytes": 0, "error_code": "file-not-found"},
        ]
        r = ht.host_read_file({"path": "/tmp/nope"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "file-not-found")

    def test_read_file_passes_through_non_streaming_error(self):
        """file-too-large arrives as a non-list error dict when the daemon
        rejects it pre-stream."""
        ht._send_request = lambda tool, args: {
            "ok": False, "error_code": "file-too-large", "error": "52428801 > 52428800"
        }
        r = ht.host_read_file({"path": "/etc/huge"})
        self.assertFalse(r["ok"])
        self.assertEqual(r["error_code"], "file-too-large")


# ── Protocol dispatcher (handle) ─────────────────────────────────────────────

class ProtocolHandleTests(unittest.TestCase):
    """MCP JSON-RPC handler: initialize, tools/list, tools/call,
    notifications/initialized, unknown method."""

    def test_initialize_returns_capabilities(self):
        resp = ht.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize"})
        self.assertEqual(resp["id"], 1)
        self.assertEqual(resp["result"]["protocolVersion"], ht.PROTOCOL_VERSION)
        self.assertIn("tools", resp["result"]["capabilities"])
        self.assertEqual(resp["result"]["serverInfo"]["name"], ht.SERVER_NAME)

    def test_initialized_notification_returns_none(self):
        """Notifications are one-way and must NOT produce a response."""
        self.assertIsNone(ht.handle({"jsonrpc": "2.0", "method": "notifications/initialized"}))
        self.assertIsNone(ht.handle({"jsonrpc": "2.0", "method": "initialized"}))

    def test_tools_list_returns_six_tools(self):
        resp = ht.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        tools = resp["result"]["tools"]
        self.assertEqual(len(tools), 6)
        names = {t["name"] for t in tools}
        self.assertEqual(names, ToolsCatalogTests.EXPECTED)
        # Handler field must NOT leak into the wire shape (MCP only expects
        # name/description/inputSchema)
        for t in tools:
            self.assertNotIn("handler", t)

    def test_tools_call_unknown_tool_returns_32601(self):
        resp = ht.handle({
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "host__bogus", "arguments": {}},
        })
        self.assertEqual(resp["error"]["code"], -32601)
        self.assertIn("host__bogus", resp["error"]["message"])

    def test_tools_call_success_wraps_in_envelope(self):
        """Known tool + valid args → tool result wrapped in make_tool_result
        envelope. Using host_run with missing 'cmd' means args-validation
        fires (no socket needed) and the resulting dict gets wrapped."""
        resp = ht.handle({
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": {"name": "host__run", "arguments": {}},  # missing 'cmd'
        })
        # The handler short-circuits to {ok: False, error_code: args-invalid, ...}
        # which is wrapped in the MCP envelope (it's a handler-returned payload,
        # not an exception)
        self.assertIn("result", resp)
        payload = json.loads(resp["result"]["content"][0]["text"])
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error_code"], "args-invalid")

    def test_tools_call_handler_exception_returns_32603(self):
        """If a handler raises, handle() catches and returns -32603."""
        # Monkey-patch host_run's entry in TOOLS to raise
        orig_handler = ht.get_tool("host__run")["handler"]
        def boom(args):
            raise RuntimeError("synthetic crash")
        ht.get_tool("host__run")["handler"] = boom
        try:
            resp = ht.handle({
                "jsonrpc": "2.0", "id": 5, "method": "tools/call",
                "params": {"name": "host__run", "arguments": {"cmd": "true"}},
            })
            self.assertEqual(resp["error"]["code"], -32603)
            self.assertIn("synthetic crash", resp["error"]["message"])
        finally:
            ht.get_tool("host__run")["handler"] = orig_handler

    def test_unknown_method_returns_32601(self):
        resp = ht.handle({"jsonrpc": "2.0", "id": 6, "method": "does/not/exist"})
        self.assertEqual(resp["error"]["code"], -32601)
        self.assertIn("does/not/exist", resp["error"]["message"])


# ── Entrypoint ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    # Match test_server.py: standalone runner, no pytest dep. Exit non-zero
    # on failure so CI picks up regressions.
    result = unittest.main(exit=False, verbosity=2).result
    sys.exit(0 if result.wasSuccessful() else 1)
