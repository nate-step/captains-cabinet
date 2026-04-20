#!/usr/bin/env python3
"""
Cabinet Host-Agent Daemon — Spec 035 Phase A

Python asyncio Unix-socket daemon. Listens on /run/cabinet/host-agent.sock
(mode 0660, group cabinet). Runs as root so it can execute privileged operations
on behalf of the CoS container.

Authentication: SO_PEERCRED peer credentials. Accepts connections only from
the cabinet-cos user (UID 60001, deterministic UID set by bootstrap-host.sh).

Wire protocol: NDJSON (one JSON object per line, \\n delimited).
  Request:  {"v": 1, "tool": "<name>", "args": {...}, "request_id": "<uuid>"}
  Response: {"v": 1, "ok": true|false, "exit": <int|null>, "stdout": "<str>",
             "stderr": "<str>", "duration_ms": <int>, "error_code": "<str|null>",
             "request_id": "<uuid>"}

Streaming (tail_logs, large read_file):
  Chunk:    {"v": 1, "chunk": "...", "request_id": "<uuid>"}
  Terminal: {"v": 1, "done": true, "total_bytes": N, "request_id": "<uuid>"}

Audit log: /var/log/cabinet/cos-actions.jsonl (append-only, O_SYNC + fsync).
  IMPORTANT: Audit log records LENGTHS only — never stdout/stderr bodies.
  This is intentional (spec §3, CTO Y5): the response back to CoS carries full
  bodies; the audit log is a tamper-resistant record of WHAT ran, not WHAT it saw.

Error codes (all error_code values; CoS pattern-matches these strings, never prose):
"""

# Error code registry — single source of truth
ERROR_CODES = {
    "paused-by-captain":    "Pause flag /run/cabinet/host-agent.paused present; all calls blocked",
    "audit-log-failure":    "fsync of audit row failed; refusing to execute without audit trail",
    "bad-peer-cred":        "Connecting UID is not the cabinet-cos user (UID 60001)",
    "tool-not-found":       "Unknown tool name in request",
    "timeout":              "Command exceeded timeout_sec (SIGTERM sent; partial output in response)",
    "args-invalid":         "Request schema violation (missing required field or wrong type)",
    "file-too-large":       "read_file: file/requested bytes exceed hard system cap (50 MiB)",
    "file-not-found":       "read_file or edit_file: target path does not exist",
    "patch-failed":         "edit_file: git apply rejected the diff; original file unchanged",
    "exec-error":           "subprocess raised an exception before completing",
    "self-restart-forbidden": "restart_officer refused: CoS cannot self-restart via host-agent; use /cos restart from admin bot",
    "request-too-large":    "Request line exceeded 1 MiB framing cap (readline limit)",
}

import asyncio
import json
import logging
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

# ----------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------
SOCKET_PATH      = Path("/run/cabinet/host-agent.sock")
AUDIT_LOG_PATH   = Path("/var/log/cabinet/cos-actions.jsonl")
PAUSE_FLAG_PATH  = Path("/run/cabinet/host-agent.paused")
CABINET_ROOT     = Path("/opt/founders-cabinet/cabinet")

# cabinet-cos user — must match bootstrap-host.sh UID assignment
CABINET_COS_UID  = 60001

# Timeout defaults
DEFAULT_TIMEOUT_SEC = 300   # 5 minutes
MAX_TIMEOUT_SEC     = 1800  # 30 minutes (spec §1)

# read_file caps
READ_FILE_DEFAULT_MAX_BYTES = 1024 * 1024        # 1 MiB default
READ_FILE_HARD_CAP_BYTES    = 50 * 1024 * 1024  # 50 MiB absolute cap (CTO N6)

# Streaming chunk size
STREAM_CHUNK_SIZE = 64 * 1024  # 64 KiB chunks

# Self-restart guard — refuse restart_officer for these names
SELF_RESTART_FORBIDDEN = {"cos", "cabinet-cos"}

# ----------------------------------------------------------------
# Logging setup
# ----------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="[host-agent] %(levelname)s %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("host-agent")


# ----------------------------------------------------------------
# Audit log
# ----------------------------------------------------------------
_audit_fd: int | None = None


def _open_audit_log() -> int:
    """Open audit log with O_APPEND | O_SYNC for atomic append writes.
    Returns an OS-level file descriptor. The +a chattr flag is set by
    bootstrap-host.sh; this code assumes it's already there."""
    path = str(AUDIT_LOG_PATH)
    # O_APPEND | O_SYNC: every write is atomic and immediately durable
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_SYNC
    fd = os.open(path, flags, 0o640)
    return fd


def _write_audit(fd: int, record: dict) -> bool:
    """Write one JSON line to the audit log. Returns True on success.
    Caller must treat False as audit-log-failure and refuse the call."""
    try:
        line = json.dumps(record, default=str) + "\n"
        data = line.encode()
        os.write(fd, data)
        os.fsync(fd)
        return True
    except OSError as exc:
        log.error("Audit write failed: %s", exc)
        return False


def audit_preflight(
    fd: int,
    request_id: str,
    caller: str,
    tool: str,
    args: dict,
    container_id: str = "unknown",
) -> bool:
    """Write started record. MUST succeed before any command is run (log-before-exec).
    container_id: Docker container ID of the calling container (from request env or 'unknown').
    Per spec §3 audit format, this field tracks which container originated the call."""
    # Note: args are logged as-is (no body redaction for args in PoC; only stdout/stderr
    # bodies are never logged). Spec 035-hardening will add credential redaction.
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "request_id": request_id,
        "caller": caller,
        "container_id": container_id,
        "tool": tool,
        "args": args,
        "status": "started",
    }
    return _write_audit(fd, record)


def audit_postflight(
    fd: int,
    request_id: str,
    exit_code: int | None,
    stdout_len: int,
    stderr_len: int,
    duration_ms: int,
    error_code: str | None,
) -> None:
    """Write completed record. Call regardless of command outcome.
    NOTE: Lengths only — never stdout/stderr bodies (spec §3, CTO Y5)."""
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "request_id": request_id,
        "status": "completed",
        "exit": exit_code,
        "stdout_len": stdout_len,
        "stderr_len": stderr_len,
        "duration_ms": duration_ms,
        "error_code": error_code,
    }
    _write_audit(fd, record)


# ----------------------------------------------------------------
# Peer credential authentication
# ----------------------------------------------------------------
def get_peer_uid(sock: socket.socket) -> int | None:
    """Extract the connecting process's UID via SO_PEERCRED.
    Returns None if the call fails (non-Linux, unsupported socket type)."""
    try:
        # SO_PEERCRED returns struct { pid_t pid; uid_t uid; gid_t gid }
        cred = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _pid, uid, _gid = struct.unpack("3i", cred)
        return uid
    except (OSError, struct.error) as exc:
        log.error("SO_PEERCRED failed: %s", exc)
        return None


# ----------------------------------------------------------------
# Response helpers
# ----------------------------------------------------------------
def ok_response(
    request_id: str,
    stdout: str = "",
    stderr: str = "",
    exit_code: int | None = 0,
    duration_ms: int = 0,
) -> dict:
    return {
        "v": 1,
        "ok": True,
        "exit": exit_code,
        "stdout": stdout,
        "stderr": stderr,
        "duration_ms": duration_ms,
        "error_code": None,
        "request_id": request_id,
    }


def error_response(request_id: str, error_code: str, message: str = "") -> dict:
    return {
        "v": 1,
        "ok": False,
        "exit": None,
        "stdout": "",
        "stderr": message,
        "duration_ms": 0,
        "error_code": error_code,
        "request_id": request_id,
    }


def chunk_message(request_id: str, data: str) -> dict:
    return {"v": 1, "chunk": data, "request_id": request_id}


def done_message(request_id: str, total_bytes: int) -> dict:
    return {"v": 1, "done": True, "total_bytes": total_bytes, "request_id": request_id}


# ----------------------------------------------------------------
# Tool implementations
# ----------------------------------------------------------------

async def tool_run(args: dict, request_id: str, audit_fd: int) -> dict:
    """run(cmd, cwd, timeout_sec) — run a shell command as root."""
    cmd = args.get("cmd")
    cwd = args.get("cwd")
    timeout_sec = args.get("timeout_sec", DEFAULT_TIMEOUT_SEC)
    container_id = args.pop("_container_id", "unknown")

    if not cmd or not isinstance(cmd, str):
        return error_response(request_id, "args-invalid", "'cmd' (string) is required")

    timeout_sec = min(float(timeout_sec), MAX_TIMEOUT_SEC)

    # Pre-flight audit (log-before-exec)
    # Strip internal fields from audit args (never log _container_id etc.)
    audit_args = {k: v for k, v in args.items() if not k.startswith("_")}
    if not audit_preflight(audit_fd, request_id, "cos", "run", audit_args, container_id):
        return error_response(request_id, "audit-log-failure")

    start = time.monotonic()
    stdout_buf = ""
    stderr_buf = ""
    exit_code: int | None = None
    error_code: str | None = None

    try:
        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd or None,
        )
        try:
            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                proc.communicate(), timeout=timeout_sec
            )
            stdout_buf = stdout_bytes.decode(errors="replace")
            stderr_buf = stderr_bytes.decode(errors="replace")
            exit_code = proc.returncode
        except asyncio.TimeoutError:
            proc.kill()
            stdout_bytes, stderr_bytes = await proc.communicate()
            stdout_buf = stdout_bytes.decode(errors="replace")
            stderr_buf = stderr_bytes.decode(errors="replace")
            exit_code = None
            error_code = "timeout"
    except OSError as exc:
        stderr_buf = str(exc)
        error_code = "exec-error"

    duration_ms = int((time.monotonic() - start) * 1000)

    # Post-flight audit (lengths only — never bodies)
    audit_postflight(
        audit_fd, request_id,
        exit_code, len(stdout_buf), len(stderr_buf),
        duration_ms, error_code,
    )

    if error_code:
        return {
            "v": 1,
            "ok": False,
            "exit": exit_code,
            "stdout": stdout_buf,
            "stderr": stderr_buf,
            "duration_ms": duration_ms,
            "error_code": error_code,
            "request_id": request_id,
        }

    return ok_response(request_id, stdout_buf, stderr_buf, exit_code, duration_ms)


async def tool_rebuild_service(args: dict, request_id: str, audit_fd: int) -> dict:
    """rebuild_service(name) — docker compose build + up -d for a service."""
    name = args.get("name")
    container_id = args.pop("_container_id", "unknown")
    if not name or not isinstance(name, str):
        return error_response(request_id, "args-invalid", "'name' (string) is required")

    cmd = f"docker compose build {name} && docker compose up -d {name}"
    # Delegate to tool_run (handles audit pair, timeout, subprocess)
    # Include container_id so audit shows the correct origin
    new_args = {
        "cmd": cmd,
        "cwd": str(CABINET_ROOT),
        "timeout_sec": args.get("timeout_sec", DEFAULT_TIMEOUT_SEC),
        "_container_id": container_id,
    }
    return await tool_run(new_args, request_id, audit_fd)


async def tool_restart_officer(args: dict, request_id: str, audit_fd: int) -> dict:
    """restart_officer(name) — docker compose restart <name>.
    N5: Refuses if name is 'cos' or 'cabinet-cos' (self-restart-forbidden)."""
    name = args.get("name")
    if not name or not isinstance(name, str):
        return error_response(request_id, "args-invalid", "'name' (string) is required")

    container_id = args.pop("_container_id", "unknown")

    # Self-restart guard (CTO v2 review N5)
    if name.lower() in SELF_RESTART_FORBIDDEN:
        return error_response(
            request_id, "self-restart-forbidden",
            f"Cannot restart '{name}' via host-agent. Use /cos restart from the admin bot instead."
        )

    cmd = f"docker compose restart {name}"
    new_args = {
        "cmd": cmd,
        "cwd": str(CABINET_ROOT),
        "timeout_sec": args.get("timeout_sec", DEFAULT_TIMEOUT_SEC),
        "_container_id": container_id,
    }
    return await tool_run(new_args, request_id, audit_fd)


async def tool_tail_logs(
    args: dict,
    request_id: str,
    audit_fd: int,
    writer: asyncio.StreamWriter,
) -> None:
    """tail_logs(service, n) — streaming docker compose logs --tail=<n>.
    Sends chunked NDJSON, terminated by done message."""
    service = args.get("service")
    n = args.get("n", 100)
    container_id = args.pop("_container_id", "unknown")

    if not service or not isinstance(service, str):
        resp = error_response(request_id, "args-invalid", "'service' (string) is required")
        writer.write((json.dumps(resp) + "\n").encode())
        await writer.drain()
        return

    cmd = f"docker compose logs --tail={int(n)} {service}"

    # Pre-flight audit (log-before-exec)
    audit_args = {k: v for k, v in args.items() if not k.startswith("_")}
    if not audit_preflight(audit_fd, request_id, "cos", "tail_logs", audit_args, container_id):
        resp = error_response(request_id, "audit-log-failure")
        writer.write((json.dumps(resp) + "\n").encode())
        await writer.drain()
        return

    start = time.monotonic()
    total_bytes = 0
    exit_code: int | None = None
    error_code: str | None = None
    stdout_len = 0
    stderr_len = 0

    try:
        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(CABINET_ROOT),
        )
        timeout_sec = float(args.get("timeout_sec", DEFAULT_TIMEOUT_SEC))

        try:
            while True:
                chunk = await asyncio.wait_for(
                    proc.stdout.read(STREAM_CHUNK_SIZE), timeout=timeout_sec
                )
                if not chunk:
                    break
                text = chunk.decode(errors="replace")
                total_bytes += len(chunk)
                stdout_len += len(chunk)
                msg = chunk_message(request_id, text)
                writer.write((json.dumps(msg) + "\n").encode())
                await writer.drain()
            await proc.wait()
            exit_code = proc.returncode
            # Drain stderr for length tracking only
            stderr_bytes = await proc.stderr.read()
            stderr_len = len(stderr_bytes)
        except asyncio.TimeoutError:
            proc.kill()
            await proc.communicate()
            error_code = "timeout"
            exit_code = None

    except OSError as exc:
        error_code = "exec-error"
        stderr_len = len(str(exc))

    duration_ms = int((time.monotonic() - start) * 1000)
    audit_postflight(audit_fd, request_id, exit_code, stdout_len, stderr_len, duration_ms, error_code)

    done = done_message(request_id, total_bytes)
    if error_code:
        done["error_code"] = error_code
        done["ok"] = False
    writer.write((json.dumps(done) + "\n").encode())
    await writer.drain()


async def tool_edit_file(args: dict, request_id: str, audit_fd: int) -> dict:
    """edit_file(path, diff) — apply unified diff via git apply.
    On failure, original file is unchanged (git apply is transactional)."""
    path = args.get("path")
    diff = args.get("diff")
    container_id = args.pop("_container_id", "unknown")

    if not path or not isinstance(path, str):
        return error_response(request_id, "args-invalid", "'path' (string) is required")
    if not diff or not isinstance(diff, str):
        return error_response(request_id, "args-invalid", "'diff' (string) is required")

    target = Path(path)
    if not target.exists():
        return error_response(request_id, "file-not-found", f"{path} does not exist")

    # Pre-flight audit (log-before-exec)
    # Log diff_len not the diff body (spec §3: lengths only, never content)
    if not audit_preflight(audit_fd, request_id, "cos", "edit_file", {"path": path, "diff_len": len(diff)}, container_id):
        return error_response(request_id, "audit-log-failure")

    start = time.monotonic()
    stdout_buf = ""
    stderr_buf = ""
    exit_code: int | None = None
    error_code: str | None = None

    # Write diff to a temp file, then apply with git apply --unsafe-paths
    # git apply is transactional: on failure the file is unchanged.
    #
    # --directory choice (Q3 fix 2026-04-20): unified diffs carry paths
    # relative to the repo root (a/cabinet/.../server.py), not relative
    # to the target file's parent. For files inside a git repo, use the
    # repo's toplevel as --directory so multi-file patches apply to the
    # right locations. For bare files outside any repo, fall back to the
    # target's parent (single-file patch semantics).
    def _apply_directory(target_path: Path) -> str:
        try:
            probe = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"],
                cwd=str(target_path.parent),
                capture_output=True, text=True, timeout=5,
            )
            if probe.returncode == 0 and probe.stdout.strip():
                return probe.stdout.strip()
        except Exception:
            pass
        return str(target_path.parent)

    try:
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".patch", delete=False, encoding="utf-8"
        ) as tmp:
            tmp.write(diff)
            tmp_path = tmp.name

        try:
            proc = await asyncio.create_subprocess_exec(
                "git", "apply", "--unsafe-paths",
                "--directory", _apply_directory(target),
                tmp_path,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            timeout_sec = float(args.get("timeout_sec", DEFAULT_TIMEOUT_SEC))
            try:
                stdout_bytes, stderr_bytes = await asyncio.wait_for(
                    proc.communicate(), timeout=timeout_sec
                )
                stdout_buf = stdout_bytes.decode(errors="replace")
                stderr_buf = stderr_bytes.decode(errors="replace")
                exit_code = proc.returncode
                if exit_code != 0:
                    error_code = "patch-failed"
            except asyncio.TimeoutError:
                proc.kill()
                await proc.communicate()
                exit_code = None
                error_code = "timeout"
        finally:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass

    except OSError as exc:
        stderr_buf = str(exc)
        error_code = "exec-error"

    duration_ms = int((time.monotonic() - start) * 1000)
    audit_postflight(audit_fd, request_id, exit_code, len(stdout_buf), len(stderr_buf), duration_ms, error_code)

    if error_code:
        return {
            "v": 1,
            "ok": False,
            "exit": exit_code,
            "stdout": stdout_buf,
            "stderr": stderr_buf,
            "duration_ms": duration_ms,
            "error_code": error_code,
            "request_id": request_id,
        }

    return ok_response(request_id, stdout_buf, stderr_buf, exit_code, duration_ms)


async def tool_read_file(
    args: dict,
    request_id: str,
    audit_fd: int,
    writer: asyncio.StreamWriter,
) -> None:
    """read_file(path, max_bytes) — read file with size cap.
    Default: 1 MiB. Caller override allowed up to 50 MiB hard cap (CTO N6).
    Streams chunks for large reads, with truncation marker if cap exceeded."""
    path = args.get("path")
    max_bytes = args.get("max_bytes", READ_FILE_DEFAULT_MAX_BYTES)
    container_id = args.pop("_container_id", "unknown")

    if not path or not isinstance(path, str):
        resp = error_response(request_id, "args-invalid", "'path' (string) is required")
        writer.write((json.dumps(resp) + "\n").encode())
        await writer.drain()
        return

    target = Path(path)
    if not target.exists():
        resp = error_response(request_id, "file-not-found", f"{path} does not exist")
        writer.write((json.dumps(resp) + "\n").encode())
        await writer.drain()
        return

    # Enforce hard cap regardless of caller's max_bytes
    effective_max = min(int(max_bytes), READ_FILE_HARD_CAP_BYTES)

    # Check file size before reading — refuse if file exceeds hard cap
    try:
        file_size = target.stat().st_size
    except OSError as exc:
        resp = error_response(request_id, "exec-error", str(exc))
        writer.write((json.dumps(resp) + "\n").encode())
        await writer.drain()
        return

    audit_args = {"path": path, "max_bytes": max_bytes}  # lengths only, not content
    if file_size > READ_FILE_HARD_CAP_BYTES:
        # Pre-flight + immediate post-flight for the refusal (log-before-exec)
        if not audit_preflight(audit_fd, request_id, "cos", "read_file", audit_args, container_id):
            resp = error_response(request_id, "audit-log-failure")
        else:
            audit_postflight(audit_fd, request_id, None, 0, 0, 0, "file-too-large")
            resp = error_response(
                request_id, "file-too-large",
                f"{path} is {file_size} bytes, exceeds 50 MiB hard cap"
            )
        writer.write((json.dumps(resp) + "\n").encode())
        await writer.drain()
        return

    # Pre-flight audit (log-before-exec)
    if not audit_preflight(audit_fd, request_id, "cos", "read_file", audit_args, container_id):
        resp = error_response(request_id, "audit-log-failure")
        writer.write((json.dumps(resp) + "\n").encode())
        await writer.drain()
        return

    start = time.monotonic()
    total_bytes = 0
    truncated = False

    try:
        with open(target, "rb") as f:
            bytes_remaining = effective_max
            while bytes_remaining > 0:
                chunk_size = min(STREAM_CHUNK_SIZE, bytes_remaining)
                chunk = f.read(chunk_size)
                if not chunk:
                    break
                text = chunk.decode(errors="replace")
                total_bytes += len(chunk)
                bytes_remaining -= len(chunk)
                msg = chunk_message(request_id, text)
                writer.write((json.dumps(msg) + "\n").encode())
                await writer.drain()

            # Check if there's more data beyond what we read
            if f.read(1):
                truncated = True

    except OSError as exc:
        duration_ms = int((time.monotonic() - start) * 1000)
        audit_postflight(audit_fd, request_id, None, total_bytes, 0, duration_ms, "exec-error")
        resp = error_response(request_id, "exec-error", str(exc))
        writer.write((json.dumps(resp) + "\n").encode())
        await writer.drain()
        return

    duration_ms = int((time.monotonic() - start) * 1000)
    audit_postflight(audit_fd, request_id, 0, total_bytes, 0, duration_ms, None)

    done = done_message(request_id, total_bytes)
    if truncated:
        done["truncated"] = True
        done["truncated_at_bytes"] = effective_max
    writer.write((json.dumps(done) + "\n").encode())
    await writer.drain()


# ----------------------------------------------------------------
# Tool dispatch table
# ----------------------------------------------------------------
# Streaming tools are called differently (need writer param) — mark them
STREAMING_TOOLS = {"tail_logs", "read_file"}

TOOL_HANDLERS = {
    "run":              tool_run,
    "rebuild_service":  tool_rebuild_service,
    "restart_officer":  tool_restart_officer,
    "tail_logs":        tool_tail_logs,
    "edit_file":        tool_edit_file,
    "read_file":        tool_read_file,
}


# ----------------------------------------------------------------
# Connection handler
# ----------------------------------------------------------------
async def handle_connection(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    audit_fd: int,
) -> None:
    """Handle one client connection. Each connection is a single request.

    CRO stress test 2026-04-20 HIGH #2: the whole body is wrapped in
    try/finally so writer.close() ALWAYS runs regardless of which early
    return path fires. Previously, uncaught ValueError (readline limit),
    UnicodeDecodeError (invalid UTF-8 from json.loads), and RecursionError
    (deep JSON nesting) leaked the writer fd.
    """
    try:
        peer_addr = writer.get_extra_info("peername", "unknown")

        # --- Peer-credential authentication ---
        transport = writer.transport
        raw_sock = transport.get_extra_info("socket")
        if raw_sock is None:
            log.warning("No socket info available; rejecting connection")
            resp = error_response("unknown", "bad-peer-cred", "Cannot determine peer credentials")
            writer.write((json.dumps(resp) + "\n").encode())
            await writer.drain()
            return

        peer_uid = get_peer_uid(raw_sock)
        if peer_uid != CABINET_COS_UID:
            log.warning("Rejected connection from UID %s (expected %s)", peer_uid, CABINET_COS_UID)
            resp = error_response("unknown", "bad-peer-cred",
                                  f"UID {peer_uid} is not authorized (expected UID {CABINET_COS_UID})")
            writer.write((json.dumps(resp) + "\n").encode())
            await writer.drain()
            return

        # --- Read request line ---
        try:
            line = await asyncio.wait_for(reader.readline(), timeout=30.0)
        except asyncio.TimeoutError:
            log.warning("Timeout reading request from UID %s", peer_uid)
            return
        except ValueError as exc:
            # readline limit exceeded (LimitOverrunError subclasses ValueError)
            log.warning("Oversized request from UID %s: %s", peer_uid, exc)
            resp = error_response("unknown", "request-too-large",
                                  "Request line exceeded 1 MiB framing cap")
            writer.write((json.dumps(resp) + "\n").encode())
            await writer.drain()
            return

        line = line.strip()
        if not line:
            return

        # --- Parse JSON ---
        try:
            req = json.loads(line)
        except (json.JSONDecodeError, UnicodeDecodeError, RecursionError, ValueError) as exc:
            # JSONDecodeError: malformed JSON
            # UnicodeDecodeError: invalid UTF-8 (e.g., b'\xff\xfe')
            # RecursionError: pathological nesting depth
            # ValueError: generic fallback for json-lib variance
            log.warning("Malformed request from UID %s: %s", peer_uid, type(exc).__name__)
            resp = error_response("unknown", "args-invalid",
                                  f"{type(exc).__name__}: {exc}")
            writer.write((json.dumps(resp) + "\n").encode())
            await writer.drain()
            return

        # --- Extract fields ---
        request_id   = req.get("request_id") or str(uuid.uuid4())
        tool_name    = req.get("tool", "")
        args         = req.get("args") or {}
        version      = req.get("v", 1)
        container_id = req.get("container_id", "unknown") or "unknown"
        args["_container_id"] = container_id

        if version != 1:
            resp = error_response(request_id, "args-invalid",
                                  f"Unsupported protocol version: {version}")
            writer.write((json.dumps(resp) + "\n").encode())
            await writer.drain()
            return

        # --- Pause check ---
        if PAUSE_FLAG_PATH.exists():
            resp = error_response(request_id, "paused-by-captain",
                                  "Host-agent is paused. Use /cos resume from admin bot.")
            writer.write((json.dumps(resp) + "\n").encode())
            await writer.drain()
            return

        # --- Tool dispatch ---
        if tool_name not in TOOL_HANDLERS:
            resp = error_response(request_id, "tool-not-found", f"Unknown tool: {tool_name!r}")
            writer.write((json.dumps(resp) + "\n").encode())
            await writer.drain()
            return

        handler = TOOL_HANDLERS[tool_name]
        try:
            if tool_name in STREAMING_TOOLS:
                await handler(args, request_id, audit_fd, writer)
            else:
                resp = await handler(args, request_id, audit_fd)
                writer.write((json.dumps(resp) + "\n").encode())
                await writer.drain()
        except Exception as exc:
            log.exception("Unhandled exception in tool %s: %s", tool_name, exc)
            try:
                resp = error_response(request_id, "exec-error", str(exc))
                writer.write((json.dumps(resp) + "\n").encode())
                await writer.drain()
            except OSError:
                pass
    finally:
        # Single close point — guarantees no writer fd leaks regardless of
        # which early return / exception path above fired.
        try:
            writer.close()
            await writer.wait_closed()
        except Exception:
            pass


# ----------------------------------------------------------------
# Server setup
# ----------------------------------------------------------------
async def create_server(audit_fd: int) -> None:
    """Create the Unix socket server at SOCKET_PATH."""
    # Remove stale socket file if it exists
    if SOCKET_PATH.exists():
        SOCKET_PATH.unlink()

    def client_connected(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        asyncio.create_task(handle_connection(reader, writer, audit_fd))

    # limit=1 MiB matches the NDJSON framing cap documented in spec §1.
    # Default asyncio limit is 64 KiB, which is too small for large edit_file
    # diff bodies and causes readline() to raise ValueError via
    # LimitOverrunError instead of returning the framed line.
    # (CRO stress test 2026-04-20: HIGH #1.)
    server = await asyncio.start_unix_server(
        client_connected, path=str(SOCKET_PATH), limit=1024 * 1024
    )

    # Set socket permissions: mode 0660, group cabinet (GID 60000)
    try:
        os.chmod(str(SOCKET_PATH), 0o660)
        os.chown(str(SOCKET_PATH), 0, 60000)  # root:cabinet
        log.info("Socket permissions set: mode 0660, root:cabinet")
    except OSError as exc:
        log.warning("Could not set socket permissions: %s", exc)

    async with server:
        log.info("Host-agent listening on %s (UID auth: cabinet-cos=%d)", SOCKET_PATH, CABINET_COS_UID)
        await server.serve_forever()


# ----------------------------------------------------------------
# Entry point
# ----------------------------------------------------------------
def main() -> None:
    # Open audit log once at startup
    global _audit_fd
    try:
        _audit_fd = _open_audit_log()
        log.info("Audit log opened: %s", AUDIT_LOG_PATH)
    except OSError as exc:
        log.critical("Cannot open audit log %s: %s — aborting.", AUDIT_LOG_PATH, exc)
        sys.exit(1)

    try:
        asyncio.run(create_server(_audit_fd))
    except KeyboardInterrupt:
        log.info("Host-agent shutting down.")
    finally:
        if _audit_fd is not None:
            os.close(_audit_fd)


if __name__ == "__main__":
    main()
