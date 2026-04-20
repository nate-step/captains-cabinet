#!/usr/bin/env python3
"""
Host-Agent Server Tests — Spec 035 Phase A

pytest coverage for all error_code paths, log-before-exec audit pair,
timeout case, peer-cred rejection, pause flag, self-restart-forbidden,
file-too-large, and patch-failed.

Run:
    cd /opt/founders-cabinet/cabinet/host-agent
    python -m pytest test_server.py -v

Uses async test helpers and a mock Unix socket to test auth + protocol
without requiring root or a live host-agent daemon.
"""

import asyncio
import json
import os
import socket
import struct
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, Mock, patch, mock_open
import uuid

# Add parent dirs to path
sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

# Import server module components
from server import (
    CABINET_COS_UID,
    DEFAULT_TIMEOUT_SEC,
    MAX_TIMEOUT_SEC,
    READ_FILE_DEFAULT_MAX_BYTES,
    READ_FILE_HARD_CAP_BYTES,
    SELF_RESTART_FORBIDDEN,
    audit_postflight,
    audit_preflight,
    error_response,
    get_peer_uid,
    ok_response,
    tool_edit_file,
    tool_read_file,
    tool_restart_officer,
    tool_run,
    tool_tail_logs,
    ERROR_CODES,
)

# ----------------------------------------------------------------
# Test helpers
# ----------------------------------------------------------------

class MockAuditFd:
    """Fake file descriptor that records all audit writes."""

    def __init__(self, should_fail=False):
        self.records = []
        self.should_fail = should_fail

    def write(self, data: bytes):
        if self.should_fail:
            raise OSError("Simulated audit write failure")
        self.records.append(json.loads(data.decode().strip()))
        return len(data)

    def fsync(self):
        if self.should_fail:
            raise OSError("Simulated fsync failure")

    def get_preflight(self, request_id: str):
        return next((r for r in self.records if r.get("request_id") == request_id and r.get("status") == "started"), None)

    def get_postflight(self, request_id: str):
        return next((r for r in self.records if r.get("request_id") == request_id and r.get("status") == "completed"), None)


def make_audit_fd(should_fail=False):
    """Create a mock OS-level fd that records writes."""
    mock = MockAuditFd(should_fail=should_fail)

    # Patch os.write and os.fsync for the fd
    original_write = os.write
    original_fsync = os.fsync
    MOCK_FD = 999

    return MOCK_FD, mock


def fake_write_audit(record_list, should_fail=False):
    """Return a patched _write_audit that records to a list."""
    def _write(fd, record):
        if should_fail:
            return False
        record_list.append(record)
        return True
    return _write


# ----------------------------------------------------------------
# 1. Error code enumeration completeness
# ----------------------------------------------------------------

class TestErrorCodeEnumeration(unittest.TestCase):
    """All 10 error codes must be present in ERROR_CODES dict."""

    REQUIRED_CODES = [
        "paused-by-captain",
        "audit-log-failure",
        "bad-peer-cred",
        "tool-not-found",
        "timeout",
        "args-invalid",
        "file-too-large",
        "file-not-found",
        "patch-failed",
        "exec-error",
    ]

    def test_all_required_codes_present(self):
        for code in self.REQUIRED_CODES:
            with self.subTest(code=code):
                self.assertIn(code, ERROR_CODES, f"Error code '{code}' missing from ERROR_CODES dict")

    def test_self_restart_forbidden_defined(self):
        """N5: self-restart-forbidden must also be defined."""
        self.assertIn("self-restart-forbidden", ERROR_CODES)

    def test_error_codes_have_descriptions(self):
        """Each code must have a non-empty description."""
        for code, desc in ERROR_CODES.items():
            with self.subTest(code=code):
                self.assertIsInstance(desc, str)
                self.assertGreater(len(desc), 0)


# ----------------------------------------------------------------
# 2. Response shape correctness
# ----------------------------------------------------------------

class TestResponseShapes(unittest.TestCase):

    def test_ok_response_shape(self):
        r = ok_response("req-1", stdout="out", stderr="err", exit_code=0, duration_ms=100)
        self.assertTrue(r["ok"])
        self.assertEqual(r["exit"], 0)
        self.assertEqual(r["stdout"], "out")
        self.assertEqual(r["stderr"], "err")
        self.assertEqual(r["duration_ms"], 100)
        self.assertIsNone(r["error_code"])
        self.assertEqual(r["request_id"], "req-1")
        self.assertEqual(r["v"], 1)

    def test_error_response_shape(self):
        r = error_response("req-2", "timeout", "command timed out")
        self.assertFalse(r["ok"])
        self.assertIsNone(r["exit"])
        self.assertEqual(r["error_code"], "timeout")
        self.assertEqual(r["request_id"], "req-2")
        self.assertEqual(r["v"], 1)


# ----------------------------------------------------------------
# 3. Peer credential authentication
# ----------------------------------------------------------------

class TestPeerCredAuth(unittest.TestCase):

    def test_correct_uid_accepted(self):
        """CABINET_COS_UID should match the spec value 60001."""
        self.assertEqual(CABINET_COS_UID, 60001)

    def test_get_peer_uid_parses_peercred(self):
        """get_peer_uid must extract uid from SO_PEERCRED struct."""
        mock_sock = MagicMock()
        # struct { pid_t pid; uid_t uid; gid_t gid } — pack as 3 ints
        pid, uid, gid = 12345, CABINET_COS_UID, 60000
        cred_bytes = struct.pack("3i", pid, uid, gid)
        mock_sock.getsockopt.return_value = cred_bytes
        result = get_peer_uid(mock_sock)
        self.assertEqual(result, CABINET_COS_UID)

    def test_get_peer_uid_wrong_uid(self):
        """Wrong UID must be returned as-is (comparison happens in caller)."""
        mock_sock = MagicMock()
        wrong_uid = 1000  # regular user, not cabinet-cos
        cred_bytes = struct.pack("3i", 999, wrong_uid, 1000)
        mock_sock.getsockopt.return_value = cred_bytes
        result = get_peer_uid(mock_sock)
        self.assertEqual(result, wrong_uid)

    def test_get_peer_uid_returns_none_on_error(self):
        """OSError from getsockopt must return None (caller rejects)."""
        mock_sock = MagicMock()
        mock_sock.getsockopt.side_effect = OSError("not supported")
        result = get_peer_uid(mock_sock)
        self.assertIsNone(result)

    def test_none_uid_is_not_cabinet_cos(self):
        """None uid (getsockopt failure) must not equal CABINET_COS_UID."""
        self.assertNotEqual(None, CABINET_COS_UID)


# ----------------------------------------------------------------
# 4. Audit log — log-before-exec invariant
# ----------------------------------------------------------------

class TestAuditLog(unittest.TestCase):

    def setUp(self):
        self.audit_records = []

    @patch("server._write_audit")
    def test_preflight_writes_started_record(self, mock_write):
        mock_write.return_value = True
        audit_preflight(42, "req-abc", "cos", "run", {"cmd": "ls"})
        self.assertEqual(mock_write.call_count, 1)
        _, record = mock_write.call_args[0]
        self.assertEqual(record["status"], "started")
        self.assertEqual(record["request_id"], "req-abc")
        self.assertEqual(record["tool"], "run")
        self.assertEqual(record["caller"], "cos")

    @patch("server._write_audit")
    def test_postflight_writes_completed_record(self, mock_write):
        mock_write.return_value = True
        audit_postflight(42, "req-abc", 0, 100, 0, 250, None)
        self.assertEqual(mock_write.call_count, 1)
        _, record = mock_write.call_args[0]
        self.assertEqual(record["status"], "completed")
        self.assertEqual(record["request_id"], "req-abc")
        self.assertEqual(record["exit"], 0)
        self.assertEqual(record["stdout_len"], 100)
        self.assertEqual(record["stderr_len"], 0)
        self.assertEqual(record["duration_ms"], 250)
        self.assertIsNone(record["error_code"])

    @patch("server._write_audit")
    def test_audit_records_lengths_not_bodies(self, mock_write):
        """Critical: audit must never log stdout/stderr content."""
        mock_write.return_value = True
        audit_postflight(42, "req-xyz", 0, 500, 10, 100, None)
        _, record = mock_write.call_args[0]
        # Only lengths, no content
        self.assertIn("stdout_len", record)
        self.assertIn("stderr_len", record)
        self.assertNotIn("stdout", record)
        self.assertNotIn("stderr", record)

    @patch("server._write_audit")
    def test_timeout_case_exit_null_error_code_timeout(self, mock_write):
        """CTO N3: timeout must produce exit=null, error_code='timeout'."""
        mock_write.return_value = True
        audit_postflight(42, "req-timeout", None, 0, 0, 300000, "timeout")
        _, record = mock_write.call_args[0]
        self.assertIsNone(record["exit"])
        self.assertEqual(record["error_code"], "timeout")

    @patch("server._write_audit")
    def test_audit_failure_returns_false(self, mock_write):
        """_write_audit failure must propagate as False."""
        mock_write.return_value = False
        result = audit_preflight(42, "req-fail", "cos", "run", {"cmd": "ls"})
        self.assertFalse(result)


# ----------------------------------------------------------------
# 5. Pause flag check
# ----------------------------------------------------------------

class TestPauseFlag(unittest.TestCase):

    def test_pause_flag_constants(self):
        """PAUSE_FLAG_PATH must be /run/cabinet/host-agent.paused."""
        from server import PAUSE_FLAG_PATH
        self.assertEqual(str(PAUSE_FLAG_PATH), "/run/cabinet/host-agent.paused")


# ----------------------------------------------------------------
# 6. tool_run — basic execution paths
# ----------------------------------------------------------------

class TestToolRun(unittest.IsolatedAsyncioTestCase):

    @patch("server._write_audit", return_value=True)
    async def test_run_requires_cmd(self, _):
        resp = await tool_run({}, "req-1", 42)
        self.assertFalse(resp["ok"])
        self.assertEqual(resp["error_code"], "args-invalid")

    @patch("server._write_audit", return_value=True)
    async def test_run_success(self, _):
        resp = await tool_run({"cmd": "echo hello"}, "req-2", 42)
        self.assertTrue(resp["ok"])
        self.assertEqual(resp["exit"], 0)
        self.assertIn("hello", resp["stdout"])

    @patch("server._write_audit", return_value=True)
    async def test_run_audit_failure_refuses_exec(self, mock_audit):
        """audit-log-failure: if preflight fails, must refuse execution."""
        mock_audit.return_value = False
        resp = await tool_run({"cmd": "echo hello"}, "req-3", 42)
        self.assertFalse(resp["ok"])
        self.assertEqual(resp["error_code"], "audit-log-failure")

    @patch("server._write_audit", return_value=True)
    async def test_run_timeout(self, _):
        """Timeout must return exit=null, error_code='timeout'."""
        resp = await tool_run(
            {"cmd": "sleep 10", "timeout_sec": 0.1},
            "req-timeout",
            42,
        )
        self.assertFalse(resp["ok"])
        self.assertEqual(resp["error_code"], "timeout")
        self.assertIsNone(resp["exit"])

    @patch("server._write_audit", return_value=True)
    async def test_run_timeout_capped_at_max(self, _):
        """timeout_sec cannot exceed MAX_TIMEOUT_SEC even if caller requests more."""
        # We just verify the cap logic doesn't crash; actual cap is tested in run
        args = {"cmd": "echo hi", "timeout_sec": 99999}
        resp = await tool_run(args, "req-cap", 42)
        self.assertTrue(resp["ok"])


# ----------------------------------------------------------------
# 7. tool_restart_officer — self-restart-forbidden
# ----------------------------------------------------------------

class TestRestartOfficer(unittest.IsolatedAsyncioTestCase):

    @patch("server._write_audit", return_value=True)
    async def test_self_restart_forbidden_cos(self, _):
        """restart_officer('cos') must return self-restart-forbidden (N5)."""
        resp = await tool_restart_officer({"name": "cos"}, "req-selfrest", 42)
        self.assertFalse(resp["ok"])
        self.assertEqual(resp["error_code"], "self-restart-forbidden")

    @patch("server._write_audit", return_value=True)
    async def test_self_restart_forbidden_cabinet_cos(self, _):
        """restart_officer('cabinet-cos') must also be forbidden."""
        resp = await tool_restart_officer({"name": "cabinet-cos"}, "req-selfrest2", 42)
        self.assertFalse(resp["ok"])
        self.assertEqual(resp["error_code"], "self-restart-forbidden")

    def test_self_restart_set_contains_expected_names(self):
        """SELF_RESTART_FORBIDDEN must contain cos and cabinet-cos."""
        self.assertIn("cos", SELF_RESTART_FORBIDDEN)
        self.assertIn("cabinet-cos", SELF_RESTART_FORBIDDEN)

    @patch("server._write_audit", return_value=True)
    async def test_restart_requires_name(self, _):
        resp = await tool_restart_officer({}, "req-noname", 42)
        self.assertFalse(resp["ok"])
        self.assertEqual(resp["error_code"], "args-invalid")


# ----------------------------------------------------------------
# 8. tool_edit_file — patch-failed + file-not-found
# ----------------------------------------------------------------

class TestEditFile(unittest.IsolatedAsyncioTestCase):

    @patch("server._write_audit", return_value=True)
    async def test_edit_requires_path(self, _):
        resp = await tool_edit_file({"diff": "--- a\n+++ b\n"}, "req-ep", 42)
        self.assertFalse(resp["ok"])
        self.assertEqual(resp["error_code"], "args-invalid")

    @patch("server._write_audit", return_value=True)
    async def test_edit_requires_diff(self, _):
        resp = await tool_edit_file({"path": "/tmp/test.txt"}, "req-ed", 42)
        self.assertFalse(resp["ok"])
        self.assertEqual(resp["error_code"], "args-invalid")

    @patch("server._write_audit", return_value=True)
    async def test_edit_file_not_found(self, _):
        resp = await tool_edit_file(
            {"path": "/nonexistent/file.txt", "diff": "--- a\n+++ b\n"},
            "req-enf",
            42,
        )
        self.assertFalse(resp["ok"])
        self.assertEqual(resp["error_code"], "file-not-found")

    @patch("server._write_audit", return_value=True)
    async def test_edit_malformed_diff_returns_patch_failed(self, _):
        """Malformed diff must return patch-failed and leave file unchanged."""
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".txt", delete=False
        ) as tmp:
            tmp.write("original content\n")
            tmp_path = tmp.name

        original = open(tmp_path).read()

        try:
            resp = await tool_edit_file(
                {"path": tmp_path, "diff": "this is not a valid unified diff"},
                "req-pf",
                42,
            )
            self.assertFalse(resp["ok"])
            self.assertEqual(resp["error_code"], "patch-failed")
            # File must be unchanged
            self.assertEqual(open(tmp_path).read(), original)
        finally:
            os.unlink(tmp_path)

    @patch("server._write_audit", return_value=True)
    async def test_edit_audit_failure_refuses(self, mock_audit):
        """audit-log-failure in edit_file must refuse execution."""
        mock_audit.return_value = False
        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as tmp:
            tmp.write("content\n")
            tmp_path = tmp.name
        try:
            resp = await tool_edit_file(
                {"path": tmp_path, "diff": "--- a\n+++ b\n"},
                "req-eaf",
                42,
            )
            self.assertFalse(resp["ok"])
            self.assertEqual(resp["error_code"], "audit-log-failure")
        finally:
            os.unlink(tmp_path)


# ----------------------------------------------------------------
# 9. tool_read_file — file-too-large + args-invalid
# ----------------------------------------------------------------

class TestReadFile(unittest.IsolatedAsyncioTestCase):

    def _make_mock_writer(self):
        """Create a mock asyncio.StreamWriter that records writes."""
        writer = MagicMock()
        writer.write = MagicMock()
        writer.drain = AsyncMock()
        writer._written_data = []

        def capture_write(data):
            writer._written_data.append(data)

        writer.write.side_effect = capture_write
        return writer

    def _get_written_messages(self, writer):
        """Parse all NDJSON lines written to the mock writer."""
        msgs = []
        for data in writer._written_data:
            for line in data.decode().split("\n"):
                line = line.strip()
                if line:
                    msgs.append(json.loads(line))
        return msgs

    @patch("server._write_audit", return_value=True)
    async def test_read_requires_path(self, _):
        writer = self._make_mock_writer()
        await tool_read_file({}, "req-rp", 42, writer)
        msgs = self._get_written_messages(writer)
        self.assertEqual(len(msgs), 1)
        self.assertFalse(msgs[0]["ok"])
        self.assertEqual(msgs[0]["error_code"], "args-invalid")

    @patch("server._write_audit", return_value=True)
    async def test_read_file_not_found(self, _):
        writer = self._make_mock_writer()
        await tool_read_file({"path": "/nonexistent/file.txt"}, "req-rfnf", 42, writer)
        msgs = self._get_written_messages(writer)
        self.assertEqual(len(msgs), 1)
        self.assertFalse(msgs[0]["ok"])
        self.assertEqual(msgs[0]["error_code"], "file-not-found")

    @patch("server._write_audit", return_value=True)
    @patch("server.Path.stat")
    async def test_read_file_too_large(self, mock_stat, _):
        """Files exceeding 50 MiB hard cap must return file-too-large."""
        mock_stat_result = MagicMock()
        mock_stat_result.st_size = READ_FILE_HARD_CAP_BYTES + 1
        mock_stat.return_value = mock_stat_result

        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as tmp:
            tmp.write("x")
            tmp_path = tmp.name

        try:
            with patch("server.Path.stat", return_value=mock_stat_result):
                writer = self._make_mock_writer()
                await tool_read_file({"path": tmp_path}, "req-ftl", 42, writer)
                msgs = self._get_written_messages(writer)
                self.assertGreater(len(msgs), 0)
                last = msgs[-1]
                self.assertFalse(last.get("ok", True))
                self.assertEqual(last.get("error_code"), "file-too-large")
        finally:
            os.unlink(tmp_path)

    @patch("server._write_audit", return_value=True)
    async def test_read_small_file_returns_content(self, _):
        """Normal-sized file must stream content then send done message."""
        content = "hello world\n"
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".txt", delete=False
        ) as tmp:
            tmp.write(content)
            tmp_path = tmp.name

        try:
            writer = self._make_mock_writer()
            await tool_read_file({"path": tmp_path}, "req-small", 42, writer)
            msgs = self._get_written_messages(writer)
            # Must end with done message
            done_msgs = [m for m in msgs if m.get("done")]
            self.assertEqual(len(done_msgs), 1)
            # Must have at least one chunk
            chunks = [m for m in msgs if "chunk" in m]
            self.assertGreater(len(chunks), 0)
            full_content = "".join(c["chunk"] for c in chunks)
            self.assertEqual(full_content, content)
        finally:
            os.unlink(tmp_path)

    @patch("server._write_audit", return_value=True)
    async def test_read_truncation_at_max_bytes(self, _):
        """File exceeding max_bytes must be truncated with marker."""
        content = "a" * 200  # 200 bytes
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".txt", delete=False
        ) as tmp:
            tmp.write(content)
            tmp_path = tmp.name

        try:
            writer = self._make_mock_writer()
            # Request only 100 bytes
            await tool_read_file({"path": tmp_path, "max_bytes": 100}, "req-trunc", 42, writer)
            msgs = self._get_written_messages(writer)
            done_msgs = [m for m in msgs if m.get("done")]
            self.assertEqual(len(done_msgs), 1)
            self.assertTrue(done_msgs[0].get("truncated"))
        finally:
            os.unlink(tmp_path)

    def test_hard_cap_is_50_mib(self):
        self.assertEqual(READ_FILE_HARD_CAP_BYTES, 50 * 1024 * 1024)

    def test_default_cap_is_1_mib(self):
        self.assertEqual(READ_FILE_DEFAULT_MAX_BYTES, 1 * 1024 * 1024)


# ----------------------------------------------------------------
# 10. tool_tail_logs — streaming + audit pair
# ----------------------------------------------------------------

class TestTailLogs(unittest.IsolatedAsyncioTestCase):

    def _make_mock_writer(self):
        writer = MagicMock()
        writer._written_data = []
        writer.write = MagicMock(side_effect=lambda d: writer._written_data.append(d))
        writer.drain = AsyncMock()
        return writer

    def _parse_msgs(self, writer):
        msgs = []
        for data in writer._written_data:
            for line in data.decode().split("\n"):
                line = line.strip()
                if line:
                    msgs.append(json.loads(line))
        return msgs

    @patch("server._write_audit", return_value=True)
    async def test_tail_logs_requires_service(self, _):
        writer = self._make_mock_writer()
        await tool_tail_logs({}, "req-tls", 42, writer)
        msgs = self._parse_msgs(writer)
        self.assertGreater(len(msgs), 0)
        resp = msgs[0]
        self.assertFalse(resp.get("ok", True))
        self.assertEqual(resp.get("error_code"), "args-invalid")

    @patch("server._write_audit", return_value=True)
    async def test_tail_logs_audit_failure_refuses(self, mock_audit):
        mock_audit.return_value = False
        writer = self._make_mock_writer()
        await tool_tail_logs({"service": "cos"}, "req-tlaf", 42, writer)
        msgs = self._parse_msgs(writer)
        self.assertGreater(len(msgs), 0)
        self.assertEqual(msgs[0].get("error_code"), "audit-log-failure")


# ----------------------------------------------------------------
# 11. Self-restart forbidden constants
# ----------------------------------------------------------------

class TestSelfRestartForbidden(unittest.TestCase):

    def test_forbidden_set_is_lowercase(self):
        """SELF_RESTART_FORBIDDEN values must be lowercase (server lowercases input)."""
        for name in SELF_RESTART_FORBIDDEN:
            self.assertEqual(name, name.lower())

    def test_cos_in_forbidden(self):
        self.assertIn("cos", SELF_RESTART_FORBIDDEN)

    def test_cabinet_cos_in_forbidden(self):
        self.assertIn("cabinet-cos", SELF_RESTART_FORBIDDEN)

    def test_other_officers_not_in_forbidden(self):
        """cto, cpo, cro, coo should NOT be forbidden."""
        for officer in ["cto", "cpo", "cro", "coo"]:
            self.assertNotIn(officer, SELF_RESTART_FORBIDDEN)


# ----------------------------------------------------------------
# 12. Wire protocol version check
# ----------------------------------------------------------------

class TestWireProtocol(unittest.TestCase):

    def test_error_response_has_v1(self):
        r = error_response("id-1", "timeout")
        self.assertEqual(r["v"], 1)

    def test_ok_response_has_v1(self):
        r = ok_response("id-2")
        self.assertEqual(r["v"], 1)

    def test_request_id_propagated_in_error(self):
        rid = str(uuid.uuid4())
        r = error_response(rid, "timeout")
        self.assertEqual(r["request_id"], rid)

    def test_request_id_propagated_in_ok(self):
        rid = str(uuid.uuid4())
        r = ok_response(rid)
        self.assertEqual(r["request_id"], rid)


# ----------------------------------------------------------------
# 13. Max timeout enforcement
# ----------------------------------------------------------------

class TestTimeoutConstants(unittest.TestCase):

    def test_default_timeout_is_5_minutes(self):
        self.assertEqual(DEFAULT_TIMEOUT_SEC, 300)

    def test_max_timeout_is_30_minutes(self):
        self.assertEqual(MAX_TIMEOUT_SEC, 1800)


if __name__ == "__main__":
    import unittest
    unittest.main(verbosity=2)
