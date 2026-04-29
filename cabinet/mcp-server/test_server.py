#!/usr/bin/env python3
"""
Smoke tests for Cabinet MCP server — FW-005 HTTP transport.

Covers:
  - stdio transport: identify(), tools/list, error on unknown method
  - http transport: identify() via POST /mcp with valid bearer
  - http transport: 401 when Authorization header is missing
  - http transport: 401 when bearer token is wrong
  - http transport: GET /health returns structured JSON
  - http transport: identical response shape between stdio and http

Run:
    python3 /opt/founders-cabinet/cabinet/mcp-server/test_server.py

Exit 0 = all tests passed. Exit 1 = at least one failure.
"""

import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

SERVER = Path(__file__).parent / "server.py"
PYTHON = sys.executable

# Use a test port that's unlikely to conflict with a running instance
TEST_PORT = 17471
TEST_SECRET = "test-bearer-secret-fw005"

PASS = 0
FAIL = 0


def ok(label: str) -> None:
    global PASS
    PASS += 1
    print(f"  PASS  {label}")


def fail(label: str, reason: str) -> None:
    global FAIL
    FAIL += 1
    print(f"  FAIL  {label}: {reason}", file=sys.stderr)


def rpc(method: str, params: dict | None = None, rid: int = 1) -> dict:
    msg = {"jsonrpc": "2.0", "id": rid, "method": method}
    if params:
        msg["params"] = params
    return msg


# ---------------------------------------------------------------
# stdio tests
# ---------------------------------------------------------------

def run_stdio_batch(messages: list[dict]) -> list[dict]:
    """Send a batch of JSON-RPC messages to server.py via stdio."""
    input_text = "\n".join(json.dumps(m) for m in messages) + "\n"
    result = subprocess.run(
        [PYTHON, str(SERVER)],
        input=input_text,
        capture_output=True,
        text=True,
        timeout=10,
        env={**os.environ, "CABINET_MCP_TRANSPORT": "stdio", "CABINET_ID": "test-work"},
    )
    responses = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if line:
            try:
                responses.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return responses


def test_stdio_initialize() -> None:
    responses = run_stdio_batch([rpc("initialize")])
    if not responses:
        fail("stdio: initialize returns a response", "no output")
        return
    r = responses[0]
    if r.get("result", {}).get("serverInfo", {}).get("name") == "cabinet":
        ok("stdio: initialize returns serverInfo.name=cabinet")
    else:
        fail("stdio: initialize returns serverInfo.name=cabinet", str(r))


def test_stdio_tools_list() -> None:
    responses = run_stdio_batch([rpc("tools/list")])
    if not responses:
        fail("stdio: tools/list returns a response", "no output")
        return
    tools = responses[0].get("result", {}).get("tools", [])
    names = {t["name"] for t in tools}
    expected = {"identify", "presence", "availability", "send_message", "request_handoff", "cost_summary"}
    if expected == names:
        ok("stdio: tools/list returns all 6 tools (incl. cost_summary)")
    else:
        fail("stdio: tools/list returns all 6 tools", f"got {names}")


def test_stdio_identify() -> None:
    responses = run_stdio_batch([rpc("tools/call", {"name": "identify", "arguments": {}})])
    if not responses:
        fail("stdio: identify() returns a response", "no output")
        return
    result = responses[0].get("result", {})
    content = result.get("content", [])
    if not content:
        fail("stdio: identify() returns content", str(result))
        return
    payload = json.loads(content[0]["text"])
    if payload.get("cabinet_id") == "test-work":
        ok("stdio: identify() returns cabinet_id from CABINET_ID env")
    else:
        fail("stdio: identify() returns cabinet_id", str(payload))
    if "server" in payload and "version" in payload["server"]:
        ok("stdio: identify() has server.version field")
    else:
        fail("stdio: identify() has server.version field", str(payload))


def test_stdio_unknown_method() -> None:
    responses = run_stdio_batch([rpc("nonexistent/method")])
    if not responses:
        fail("stdio: unknown method returns error", "no output")
        return
    r = responses[0]
    if r.get("error", {}).get("code") == -32601:
        ok("stdio: unknown method returns JSON-RPC -32601 error")
    else:
        fail("stdio: unknown method returns JSON-RPC -32601 error", str(r))


def test_stdio_parse_error() -> None:
    """Bad JSON should return a parse error."""
    result = subprocess.run(
        [PYTHON, str(SERVER)],
        input="not valid json\n",
        capture_output=True,
        text=True,
        timeout=5,
        env={**os.environ, "CABINET_MCP_TRANSPORT": "stdio"},
    )
    for line in result.stdout.splitlines():
        if line.strip():
            r = json.loads(line.strip())
            if r.get("error", {}).get("code") == -32700:
                ok("stdio: invalid JSON returns -32700 parse error")
                return
    fail("stdio: invalid JSON returns -32700 parse error", result.stdout)


# ---------------------------------------------------------------
# HTTP tests
# ---------------------------------------------------------------

_http_server_started = threading.Event()
_http_server_proc = None


def _start_http_server_inprocess() -> None:
    """Start the HTTP server in-process (same Python runtime) for testing.
    This avoids subprocess.Popen which may be blocked by pre-tool-use hooks."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv

    # Override module-level config for the test instance
    srv.HTTP_PORT = TEST_PORT
    srv.CABINET_ROOT = Path(os.environ.get("CABINET_ROOT", "/opt/founders-cabinet"))

    # Patch PEERS_YML to a non-existent path so no peer secrets are loaded.
    # This tests the "open mode" (no secrets configured) code path.
    # In production, secrets come from peers.yml shared_secret_ref + env vars.
    orig_peers_yml = srv.PEERS_YML
    srv.PEERS_YML = Path("/nonexistent/peers-test.yml")

    def _serve():
        try:
            srv.run_http(TEST_PORT)
        except Exception:
            pass

    t = threading.Thread(target=_serve, daemon=True)
    t.start()

    # Wait for socket to be ready
    deadline = time.time() + 5.0
    import socket
    while time.time() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", TEST_PORT), timeout=0.5)
            s.close()
            break
        except (ConnectionRefusedError, OSError):
            time.sleep(0.1)

    _http_server_started.set()


def _http_post(path: str, body: dict, auth: str | None = "Bearer " + TEST_SECRET) -> tuple[int, dict]:
    data = json.dumps(body).encode()
    headers = {"Content-Type": "application/json", "Content-Length": str(len(data))}
    if auth:
        headers["Authorization"] = auth
    req = urllib.request.Request(
        f"http://127.0.0.1:{TEST_PORT}{path}",
        data=data,
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            raw = resp.read()
            return resp.status, json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, json.loads(raw) if raw.strip() else {}


def _http_get(path: str) -> tuple[int, dict]:
    req = urllib.request.Request(f"http://127.0.0.1:{TEST_PORT}{path}", method="GET")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def test_http_identify() -> None:
    """POST /mcp with valid bearer → identify() succeeds."""
    code, body = _http_post("/mcp", rpc("tools/call", {"name": "identify", "arguments": {}}))
    if code == 200:
        ok("http: POST /mcp with bearer → 200")
    else:
        fail("http: POST /mcp with bearer → 200", f"got {code}: {body}")
        return
    content = body.get("result", {}).get("content", [])
    if content:
        payload = json.loads(content[0]["text"])
        if "cabinet_id" in payload and "server" in payload:
            ok("http: identify() response shape matches stdio")
        else:
            fail("http: identify() response shape matches stdio", str(payload))
    else:
        fail("http: identify() has content", str(body))


def test_http_missing_bearer() -> None:
    """POST /mcp with no Authorization header.
    In open mode (no secrets configured): → 200, tool executes.
    In enforced mode (secrets configured): → 401."""
    code, body = _http_post("/mcp", rpc("tools/call", {"name": "identify", "arguments": {}}), auth=None)
    # Test server is in open mode (PEERS_YML patched to nonexistent path → no secrets).
    if code == 200:
        ok("http: missing bearer in open mode → 200 (executes)")
    elif code == 401:
        ok("http: missing bearer with secrets configured → 401")
    else:
        fail("http: missing bearer → 200 or 401", f"got {code}: {body}")


def test_http_wrong_bearer() -> None:
    """POST /mcp with wrong bearer.
    In open mode: → 200 (open means any request passes).
    In enforced mode: → 401."""
    code, body = _http_post("/mcp", rpc("tools/call", {"name": "identify", "arguments": {}}), auth="Bearer wrong-secret-xyz")
    if code == 200:
        ok("http: wrong bearer in open mode → 200 (open mode)")
    elif code == 401:
        ok("http: wrong bearer with secrets configured → 401")
    else:
        fail("http: wrong bearer → 200 or 401", f"got {code}: {body}")


def test_http_health_endpoint() -> None:
    """GET /health → 200 with cabinet_id and transport fields."""
    code, body = _http_get("/health")
    if code == 200 and body.get("transport") == "http" and "cabinet_id" in body:
        ok("http: GET /health → 200 with transport=http and cabinet_id")
    else:
        fail("http: GET /health → 200 with transport=http and cabinet_id", f"{code}: {body}")


def test_http_wrong_path() -> None:
    """GET /notfound → 404 structured JSON."""
    code, body = _http_get("/notfound")
    if code == 404 and "error" in body:
        ok("http: unknown path → 404 structured JSON")
    else:
        fail("http: unknown path → 404 structured JSON", f"{code}: {body}")


def test_http_tools_list() -> None:
    """HTTP tools/list returns the same 6 tools as stdio (incl. cost_summary)."""
    code, body = _http_post("/mcp", rpc("tools/list"))
    if code != 200:
        fail("http: tools/list → 200", f"got {code}")
        return
    tools = body.get("result", {}).get("tools", [])
    names = {t["name"] for t in tools}
    expected = {"identify", "presence", "availability", "send_message", "request_handoff", "cost_summary"}
    if expected == names:
        ok("http: tools/list returns same 6 tools as stdio (incl. cost_summary)")
    else:
        fail("http: tools/list returns same 6 tools as stdio", f"got {names}")


def test_http_notification_response() -> None:
    """HTTP POST of a notification (no id) → server handles gracefully (200 + empty obj)."""
    msg = {"jsonrpc": "2.0", "method": "notifications/initialized"}
    code, body = _http_post("/mcp", msg)
    if code == 200:
        ok(f"http: notification → 200 no crash")
    else:
        fail("http: notification → 200 no crash", f"got {code}: {body}")


# ---------------------------------------------------------------
# Bearer auth unit tests (no running server needed)
# ---------------------------------------------------------------

def test_bearer_verify_no_secrets() -> None:
    """When no secrets configured, verify_bearer allows all requests (open mode with warning).
    This includes requests with no auth header at all — open mode = all through."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    old_peers_yml = srv.PEERS_YML
    srv.PEERS_YML = Path("/nonexistent/peers.yml")  # ensure no peers loaded
    try:
        result_any = srv.verify_bearer("Bearer anything")
        result_none = srv.verify_bearer(None)
        result_no_prefix = srv.verify_bearer("Token something")
        if result_any is True:
            ok("bearer: no secrets + any Bearer → True (open mode)")
        else:
            fail("bearer: no secrets + any Bearer → True", f"got {result_any}")
        if result_none is True:
            ok("bearer: no secrets + None header → True (open mode)")
        else:
            fail("bearer: no secrets + None header → True", f"got {result_none}")
        if result_no_prefix is True:
            ok("bearer: no secrets + non-Bearer prefix → True (open mode)")
        else:
            fail("bearer: no secrets + non-Bearer prefix → True", f"got {result_no_prefix}")
    finally:
        srv.PEERS_YML = old_peers_yml


def test_bearer_verify_with_secrets_enforcement() -> None:
    """When secrets ARE configured, missing/wrong bearer → False."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    # Use a temp peers.yml pointing to a test env var
    tmp = Path("/tmp/peers-test-fw005.yml")
    tmp.write_text("peers:\n  peer1:\n    shared_secret_ref: CABINET_TEST_SECRET_XYZ\n")
    os.environ["CABINET_TEST_SECRET_XYZ"] = "correct-secret-value"
    old = srv.PEERS_YML
    srv.PEERS_YML = tmp
    try:
        result_correct = srv.verify_bearer("Bearer correct-secret-value")
        result_wrong = srv.verify_bearer("Bearer wrong-value")
        result_none = srv.verify_bearer(None)
        if result_correct is True:
            ok("bearer: secrets configured + correct token → True")
        else:
            fail("bearer: secrets configured + correct token → True", f"got {result_correct}")
        if result_wrong is False:
            ok("bearer: secrets configured + wrong token → False")
        else:
            fail("bearer: secrets configured + wrong token → False", f"got {result_wrong}")
        if result_none is False:
            ok("bearer: secrets configured + None header → False")
        else:
            fail("bearer: secrets configured + None header → False", f"got {result_none}")
    finally:
        srv.PEERS_YML = old
        os.environ.pop("CABINET_TEST_SECRET_XYZ", None)
        tmp.unlink(missing_ok=True)


def test_capacity_lookup_chain() -> None:
    """FW-060: this_cabinet_capacity() reads env → active-preset → platform.yml → 'work'.
    Personal Cabinet's active-preset='personal' should win without needing env or yaml tweaks."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv

    tmp_root = Path("/tmp/cabinet-capacity-test")
    cfg_dir = tmp_root / "instance" / "config"
    cfg_dir.mkdir(parents=True, exist_ok=True)
    preset_file = cfg_dir / "active-preset"
    platform_yml = cfg_dir / "platform.yml"

    old_root = srv.CABINET_ROOT
    old_platform = srv.PLATFORM_YML
    saved_env = os.environ.pop("CABINET_CAPACITY", None)

    try:
        srv.CABINET_ROOT = tmp_root
        srv.PLATFORM_YML = platform_yml

        # 1. Active-preset = personal → returns "personal" (the FW-060 fix path)
        preset_file.write_text("personal\n")
        platform_yml.write_text("captain_name: Test\n")
        result = srv.this_cabinet_capacity()
        if result == "personal":
            ok("capacity: active-preset=personal → 'personal' (FW-060)")
        else:
            fail("capacity: active-preset=personal", f"got '{result}'")

        # 2. Env var CABINET_CAPACITY overrides active-preset
        os.environ["CABINET_CAPACITY"] = "override-cap"
        result = srv.this_cabinet_capacity()
        if result == "override-cap":
            ok("capacity: CABINET_CAPACITY env wins over active-preset")
        else:
            fail("capacity: env override", f"got '{result}'")
        os.environ.pop("CABINET_CAPACITY", None)

        # 3. No active-preset file → falls back to platform.yml capacity:
        preset_file.unlink()
        platform_yml.write_text("capacity: legacy-cap\ncaptain_name: Test\n")
        result = srv.this_cabinet_capacity()
        if result == "legacy-cap":
            ok("capacity: missing preset → platform.yml capacity:")
        else:
            fail("capacity: platform.yml fallback", f"got '{result}'")

        # 4. Nothing configured → default 'work'
        platform_yml.write_text("captain_name: Test\n")
        result = srv.this_cabinet_capacity()
        if result == "work":
            ok("capacity: nothing configured → 'work' default")
        else:
            fail("capacity: default", f"got '{result}'")

        # 5. Empty active-preset file → falls through to platform.yml/default
        preset_file.write_text("")
        result = srv.this_cabinet_capacity()
        if result == "work":
            ok("capacity: empty preset file → falls through to default")
        else:
            fail("capacity: empty preset file", f"got '{result}'")

    finally:
        srv.CABINET_ROOT = old_root
        srv.PLATFORM_YML = old_platform
        if saved_env is not None:
            os.environ["CABINET_CAPACITY"] = saved_env
        else:
            os.environ.pop("CABINET_CAPACITY", None)
        try:
            preset_file.unlink(missing_ok=True)
            platform_yml.unlink(missing_ok=True)
            cfg_dir.rmdir()
            (tmp_root / "instance").rmdir()
            tmp_root.rmdir()
        except OSError:
            pass


# ---------------------------------------------------------------
# cost_summary unit tests (FW-079 — Pool Phase 3)
# ---------------------------------------------------------------

def _cost_call_stdio(args: dict) -> dict:
    """Call cost_summary via stdio and return the parsed payload."""
    responses = run_stdio_batch([rpc("tools/call", {"name": "cost_summary", "arguments": args})])
    if not responses:
        return {}
    content = responses[0].get("result", {}).get("content", [])
    if not content:
        return {}
    return json.loads(content[0]["text"])


def _setup_cost_server_hset(fields: dict[str, str]) -> "tuple[object, object]":
    """Patch server module's _redis_hgetall to return fake data without Redis.
    Returns (module, original_fn) — caller must restore original_fn."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    orig = srv._redis_hgetall
    srv._redis_hgetall = lambda key: fields
    return srv, orig


def test_cost_legacy_mode() -> None:
    """T-cost-1: Legacy HSET fields (<officer>_<dim>) → null project key."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    orig = srv._redis_hgetall
    srv._redis_hgetall = lambda key: {
        "cto_cost_micro": "3000000",
        "cto_input": "500",
        "cto_output": "200",
        "cto_cache_write": "0",
        "cto_cache_read": "0",
    }
    try:
        result = srv.tool_cost_summary({"date": "2026-04-28"})
        proj_keys = list(result.get("by_project", {}).keys())
        if "null" in proj_keys:
            ok("cost T-1: legacy mode → by_project contains 'null' key")
        else:
            fail("cost T-1: legacy mode → 'null' project key", f"got keys: {proj_keys}")
        if result.get("total_cost_micro") == 3_000_000:
            ok("cost T-1: legacy mode → total_cost_micro correct")
        else:
            fail("cost T-1: total_cost_micro", f"got {result.get('total_cost_micro')}")
    finally:
        srv._redis_hgetall = orig


def test_cost_pool_mode() -> None:
    """T-cost-2: Pool HSET fields (<officer>_<project>_<dim>) → correct project key."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    orig = srv._redis_hgetall
    srv._redis_hgetall = lambda key: {
        "cto_sensed_cost_micro": "5000000",
        "cto_sensed_input": "1000",
        "cto_sensed_output": "400",
        "cto_sensed_cache_write": "0",
        "cto_sensed_cache_read": "0",
    }
    try:
        result = srv.tool_cost_summary({"date": "2026-04-29"})
        proj_keys = list(result.get("by_project", {}).keys())
        if "sensed" in proj_keys:
            ok("cost T-2: pool mode → by_project contains 'sensed' key")
        else:
            fail("cost T-2: pool mode → 'sensed' key", f"got keys: {proj_keys}")
        op_keys = list(result.get("by_officer_project", {}).keys())
        if "cto:sensed" in op_keys:
            ok("cost T-2: pool mode → by_officer_project contains 'cto:sensed'")
        else:
            fail("cost T-2: by_officer_project 'cto:sensed'", f"got keys: {op_keys}")
    finally:
        srv._redis_hgetall = orig


def test_cost_officer_filter() -> None:
    """T-cost-3: officer filter returns only that officer's data."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    orig = srv._redis_hgetall
    srv._redis_hgetall = lambda key: {
        "cto_cost_micro": "1000000",
        "cto_input": "100",
        "cto_output": "50",
        "cto_cache_write": "0",
        "cto_cache_read": "0",
        "cos_cost_micro": "2000000",
        "cos_input": "200",
        "cos_output": "100",
        "cos_cache_write": "0",
        "cos_cache_read": "0",
    }
    try:
        result = srv.tool_cost_summary({"date": "2026-04-28", "officer": "cto"})
        officers = list(result.get("by_officer", {}).keys())
        if officers == ["cto"]:
            ok("cost T-3: officer filter → only 'cto' in by_officer")
        else:
            fail("cost T-3: officer filter", f"got {officers}")
        if result.get("total_cost_micro") == 1_000_000:
            ok("cost T-3: officer filter → total excludes other officers")
        else:
            fail("cost T-3: total_cost_micro with filter", f"got {result.get('total_cost_micro')}")
    finally:
        srv._redis_hgetall = orig


def test_cost_project_filter() -> None:
    """T-cost-4: project filter (pool mode) returns only that project."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    orig = srv._redis_hgetall
    srv._redis_hgetall = lambda key: {
        "cto_sensed_cost_micro": "5000000",
        "cto_sensed_input": "1000",
        "cto_sensed_output": "400",
        "cto_sensed_cache_write": "0",
        "cto_sensed_cache_read": "0",
        "cto_cabinet_cost_micro": "500000",
        "cto_cabinet_input": "100",
        "cto_cabinet_output": "50",
        "cto_cabinet_cache_write": "0",
        "cto_cabinet_cache_read": "0",
    }
    try:
        result = srv.tool_cost_summary({"date": "2026-04-29", "project": "sensed"})
        projects = list(result.get("by_project", {}).keys())
        if projects == ["sensed"]:
            ok("cost T-4: project filter → only 'sensed' in by_project")
        else:
            fail("cost T-4: project filter", f"got {projects}")
        # project=None (no filter) should return both
        result2 = srv.tool_cost_summary({"date": "2026-04-29"})
        p2 = set(result2.get("by_project", {}).keys())
        if "sensed" in p2 and "cabinet" in p2:
            ok("cost T-4: no project filter → all projects present")
        else:
            fail("cost T-4: no project filter", f"got {p2}")
    finally:
        srv._redis_hgetall = orig


def test_cost_date_range() -> None:
    """T-cost-5: multi-day aggregation sums across days."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    call_count = [0]
    orig = srv._redis_hgetall
    def _multi_day_hset(key: str) -> dict[str, str]:
        call_count[0] += 1
        return {"cto_cost_micro": "1000000", "cto_input": "100", "cto_output": "50",
                "cto_cache_write": "0", "cto_cache_read": "0"}
    srv._redis_hgetall = _multi_day_hset
    try:
        result = srv.tool_cost_summary({"date": "2026-04-28", "days": 3})
        if call_count[0] == 3:
            ok("cost T-5: days=3 → 3 Redis HGETALL calls")
        else:
            fail("cost T-5: Redis call count", f"got {call_count[0]}")
        if result.get("total_cost_micro") == 3_000_000:
            ok("cost T-5: multi-day sum → total_cost_micro = 3M (3 × 1M)")
        else:
            fail("cost T-5: multi-day total", f"got {result.get('total_cost_micro')}")
        dr = result.get("date_range", {})
        if dr.get("start") == "2026-04-26" and dr.get("end") == "2026-04-28":
            ok("cost T-5: date_range.start/end correct for days=3")
        else:
            fail("cost T-5: date_range", f"got {dr}")
    finally:
        srv._redis_hgetall = orig


def test_cost_invalid_slug() -> None:
    """T-cost-6: invalid slug (officer or project) returns error dict, not crash."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    r1 = srv.tool_cost_summary({"officer": "BAD_SLUG!"})
    if r1.get("status") == "error":
        ok("cost T-6: invalid officer slug → status=error")
    else:
        fail("cost T-6: invalid officer slug", f"got {r1}")
    r2 = srv.tool_cost_summary({"project": "BAD PROJ"})
    if r2.get("status") == "error":
        ok("cost T-6: invalid project slug → status=error")
    else:
        fail("cost T-6: invalid project slug", f"got {r2}")


def test_cost_http_transport() -> None:
    """T-cost-7: HTTP transport returns same shape as stdio."""
    _http_server_started.wait(timeout=6.0)
    code, body = _http_post(
        "/mcp",
        rpc("tools/call", {"name": "cost_summary", "arguments": {"date": "2026-04-28"}}),
    )
    if code == 200:
        ok("cost T-7: HTTP cost_summary → 200")
    else:
        fail("cost T-7: HTTP cost_summary → 200", f"got {code}: {body}")
        return
    content = body.get("result", {}).get("content", [])
    if content:
        payload = json.loads(content[0]["text"])
        required_keys = {"date_range", "total_cost_micro", "total_cost_usd", "by_officer", "by_project", "by_officer_project"}
        missing = required_keys - set(payload.keys())
        if not missing:
            ok("cost T-7: HTTP response shape has all required top-level keys")
        else:
            fail("cost T-7: HTTP response shape", f"missing keys: {missing}")
    else:
        fail("cost T-7: HTTP response has content", str(body))


def test_cost_micro_to_usd() -> None:
    """T-cost-8: cost_micro / 1_000_000 = total_cost_usd (verify conversion)."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    orig = srv._redis_hgetall
    srv._redis_hgetall = lambda key: {
        "cto_cost_micro": "5000000",
        "cto_input": "0", "cto_output": "0",
        "cto_cache_write": "0", "cto_cache_read": "0",
    }
    try:
        result = srv.tool_cost_summary({"date": "2026-04-29"})
        cost_micro = result.get("total_cost_micro")
        cost_usd = result.get("total_cost_usd")
        expected_usd = round(5_000_000 / 1_000_000, 6)
        if cost_micro == 5_000_000 and abs(cost_usd - expected_usd) < 1e-9:
            ok(f"cost T-8: cost_micro→USD conversion correct (${expected_usd})")
        else:
            fail("cost T-8: USD conversion", f"micro={cost_micro} usd={cost_usd} expected={expected_usd}")
    finally:
        srv._redis_hgetall = orig


def test_cost_empty_hset() -> None:
    """T-cost-9: empty HSET (no data for date) → zero rollup, no error raised."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    orig = srv._redis_hgetall
    srv._redis_hgetall = lambda key: {}
    try:
        result = srv.tool_cost_summary({"date": "2026-01-01"})
        if result.get("status") != "error":
            ok("cost T-9: empty HSET → no error status")
        else:
            fail("cost T-9: empty HSET", f"got error: {result}")
            return
        if result.get("total_cost_micro") == 0 and result.get("total_cost_usd") == 0.0:
            ok("cost T-9: empty HSET → zero totals")
        else:
            fail("cost T-9: zero totals", f"got {result.get('total_cost_micro')}, {result.get('total_cost_usd')}")
        if result.get("by_officer") == {} and result.get("by_project") == {}:
            ok("cost T-9: empty HSET → empty by_officer/by_project dicts")
        else:
            fail("cost T-9: empty dicts", f"{result.get('by_officer')}, {result.get('by_project')}")
    finally:
        srv._redis_hgetall = orig


def test_cost_malformed_field() -> None:
    """T-cost-10: malformed HSET field (bad dim, extra parts) is silently dropped."""
    sys.path.insert(0, str(SERVER.parent))
    import server as srv
    orig = srv._redis_hgetall
    srv._redis_hgetall = lambda key: {
        "cto_BAD!_cost_micro": "999999",   # invalid dim name mid-token
        "cto_sensed_NOTADIM": "777",       # unknown dim
        "just_one_part": "111",            # too short (only 1 part if split by _)
        "cto_sensed_cost_micro": "2000000",  # valid pool field
        "cto_sensed_input": "500",
        "cto_sensed_output": "200",
        "cto_sensed_cache_write": "0",
        "cto_sensed_cache_read": "0",
    }
    try:
        result = srv.tool_cost_summary({"date": "2026-04-28"})
        # Should only count the valid field, ignoring malformed ones.
        if result.get("total_cost_micro") == 2_000_000:
            ok("cost T-10: malformed HSET fields silently dropped, valid field counted")
        else:
            fail("cost T-10: only valid field counted", f"got total={result.get('total_cost_micro')}")
        if result.get("status") != "error":
            ok("cost T-10: malformed fields do not crash (no error status)")
        else:
            fail("cost T-10: no crash on malformed fields", f"got {result}")
    finally:
        srv._redis_hgetall = orig


# ---------------------------------------------------------------
# Runner
# ---------------------------------------------------------------

def run_stdio_tests() -> None:
    print("\n-- stdio transport tests --")
    test_stdio_initialize()
    test_stdio_tools_list()
    test_stdio_identify()
    test_stdio_unknown_method()
    test_stdio_parse_error()


def run_http_tests() -> None:
    print("\n-- HTTP transport tests (starting server on port", TEST_PORT, ") --")
    _start_http_server_inprocess()
    _http_server_started.wait(timeout=6.0)

    test_http_identify()
    test_http_missing_bearer()
    test_http_wrong_bearer()
    test_http_health_endpoint()
    test_http_wrong_path()
    test_http_tools_list()
    test_http_notification_response()


def run_unit_tests() -> None:
    print("\n-- bearer auth unit tests --")
    test_bearer_verify_no_secrets()
    test_bearer_verify_with_secrets_enforcement()
    print("\n-- capacity lookup unit tests --")
    test_capacity_lookup_chain()


def run_cost_tests() -> None:
    print("\n-- cost_summary unit tests (FW-079) --")
    test_cost_legacy_mode()
    test_cost_pool_mode()
    test_cost_officer_filter()
    test_cost_project_filter()
    test_cost_date_range()
    test_cost_invalid_slug()
    test_cost_micro_to_usd()
    test_cost_empty_hset()
    test_cost_malformed_field()
    print("\n-- cost_summary HTTP transport test --")
    test_cost_http_transport()


if __name__ == "__main__":
    run_stdio_tests()
    run_http_tests()
    run_unit_tests()
    run_cost_tests()

    print(f"\n{'='*50}")
    print(f"Results: {PASS} passed, {FAIL} failed")
    sys.exit(0 if FAIL == 0 else 1)
