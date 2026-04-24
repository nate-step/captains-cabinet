"""Tests for cutover/delta-verify.py (Spec 039 §5.9 Gate 4 Step 0).

delta-verify counts post-Gate-1 row drift on Linear + GitHub before the
cutover can proceed. The script implements four adversary-review
invariants that a silent regression would quietly void:

  H-β  — filter uses `updatedAt OR createdAt` (belt-and-suspenders on
         row-creation timestamps).
  H-1  — any NEW Blocked row post-Gate-1 aborts with exit 6; a dropped
         blocked_reason field would destroy load-bearing context.
  H-2  — baseline is ONLY recorded on PROCEED/PAUSE outcomes. Recording
         on ABORT would poison the next --strict re-check (drift=0
         against a fraudulent baseline).
  M-β  — --strict mode requires drift ≤ 5 from the recorded baseline;
         enforces atomic pre-step-1 re-check in the cutover runbook.

The harness pins:
  - redis_get "(nil)" normalisation
  - linear_delta_count pagination + updated/created de-dup + GraphQL
    error → RuntimeError + new-Blocked-row → RuntimeError
  - github_delta_count PR filtering + Link header pagination +
    created/updated bucketing
  - main() exit codes 0/1/2/3/4/5/6 across both modes, and the critical
    H-2 invariant that ABORT paths NEVER call redis_set on the baseline.

conftest.py stubs requests + yaml. We replace delta_verify.requests
with a namespace and delta_verify.redis_cli with a recording stub so
no redis-cli subprocess is required at test time.
"""
from __future__ import annotations

import importlib.util
import types
from pathlib import Path

import pytest


def _load_module():
    path = Path(__file__).parent.parent / "delta-verify.py"
    spec = importlib.util.spec_from_file_location("delta_verify_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def dv():
    """Load delta-verify fresh per test.

    The conftest stubs `requests` as a bare ModuleType with no attributes, but
    delta-verify.py's main() contains `except requests.RequestException` — Python
    evaluates each except class when seeking a handler, even for exceptions of
    unrelated types (e.g., a test that raises RuntimeError inside the try block).
    Without RequestException on the stub, any such main() call fails with
    AttributeError before the real exception can be caught.

    We ensure the attribute exists here so every test sees a consistent shape.
    Tests that want to simulate HTTP failure still override mod.requests via
    _install_requests_fake, which carries a RequestException of its own.
    """
    mod = _load_module()
    if not hasattr(mod.requests, "RequestException"):
        mod.requests.RequestException = type(
            "RequestException", (Exception,), {}
        )
    return mod


# ── Fakes ────────────────────────────────────────────────────────────────────

class _FakeResponse:
    def __init__(self, status_code=200, json_body=None, headers=None, text=""):
        self.status_code = status_code
        self._json = json_body if json_body is not None else {}
        self.headers = headers or {}
        self.text = text

    def json(self):
        return self._json

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")


def _install_redis_fake(mod, initial: dict | None = None):
    """Replace mod.redis_cli with a dict-backed stub. Returns the dict so the
    test can assert what was SET (and was NOT, for H-2)."""
    store = dict(initial or {})
    calls = {"get": [], "set": []}

    def fake_redis_cli(*args):
        if args[0] == "GET":
            calls["get"].append(args[1])
            return store.get(args[1], "")
        if args[0] == "SET":
            calls["set"].append((args[1], args[2]))
            store[args[1]] = args[2]
            return "OK"
        return ""

    mod.redis_cli = fake_redis_cli
    return store, calls


def _install_requests_fake(mod, post_responses=None, get_responses=None):
    """Replace mod.requests with a namespace whose post/get pop from a list
    (letting us simulate pagination)."""
    posts = list(post_responses or [])
    gets = list(get_responses or [])
    calls = {"post": [], "get": []}

    def post(url, headers=None, json=None, timeout=None):
        calls["post"].append({"url": url, "json": json})
        if not posts:
            return _FakeResponse(200, {"data": {"issues": {
                "pageInfo": {"hasNextPage": False, "endCursor": None},
                "nodes": [],
            }}})
        return posts.pop(0)

    def get(url, headers=None, params=None, timeout=None):
        calls["get"].append({"url": url, "params": params})
        if not gets:
            return _FakeResponse(200, [], headers={})
        return gets.pop(0)

    # requests.RequestException — used in except clause; must exist on the namespace
    ns = types.SimpleNamespace(post=post, get=get, RequestException=type("RE", (Exception,), {}))
    mod.requests = ns
    return calls


# ── redis_get normalisation ──────────────────────────────────────────────────

def test_redis_get_returns_empty_for_nil(dv):
    """redis-cli prints '(nil)' when the key is missing; redis_get must
    normalise that to ''. A regression that returned '(nil)' literal would
    get parsed as a valid Gate-1 timestamp string by main()."""
    dv.redis_cli = lambda *a: "(nil)"
    assert dv.redis_get("k") == ""


def test_redis_get_returns_value_when_set(dv):
    dv.redis_cli = lambda *a: "2026-04-20T10:00:00Z"
    assert dv.redis_get("k") == "2026-04-20T10:00:00Z"


def test_redis_get_strips_whitespace(dv):
    """redis-cli appends a newline that our strip() handles in redis_cli
    itself, but verify the normalised shape reaches the caller."""
    dv.redis_cli = lambda *a: "value"  # already stripped in real redis_cli
    assert dv.redis_get("k") == "value"


# ── linear_delta_count ───────────────────────────────────────────────────────

def _linear_page(nodes, hasNextPage=False, endCursor=None):
    return _FakeResponse(200, {"data": {"issues": {
        "pageInfo": {"hasNextPage": hasNextPage, "endCursor": endCursor},
        "nodes": nodes,
    }}})


def test_linear_delta_single_page_partitions_created_and_updated(dv, monkeypatch):
    monkeypatch.setenv("LINEAR_API_KEY", "key")
    _install_requests_fake(dv, post_responses=[
        _linear_page([
            {"id": "A", "createdAt": "2026-04-22T00:00:00Z",
             "updatedAt": "2026-04-22T00:00:00Z",
             "state": {"name": "Todo"}, "identifier": "DEV-1"},
            {"id": "B", "createdAt": "2026-04-01T00:00:00Z",  # before cutoff
             "updatedAt": "2026-04-22T00:00:00Z",            # updated after
             "state": {"name": "In Progress"}, "identifier": "DEV-2"},
        ]),
    ])
    updated, created = dv.linear_delta_count("2026-04-20T00:00:00Z")
    assert created == 1
    assert updated == 1


def test_linear_delta_follows_pagination(dv, monkeypatch):
    """hasNextPage=true → follow cursor → second page rows also counted."""
    monkeypatch.setenv("LINEAR_API_KEY", "key")
    _install_requests_fake(dv, post_responses=[
        _linear_page([
            {"id": "A", "createdAt": "2026-04-22T00:00:00Z",
             "updatedAt": "2026-04-22T00:00:00Z",
             "state": {"name": "Todo"}, "identifier": "DEV-1"},
        ], hasNextPage=True, endCursor="cursor-1"),
        _linear_page([
            {"id": "B", "createdAt": "2026-04-23T00:00:00Z",
             "updatedAt": "2026-04-23T00:00:00Z",
             "state": {"name": "Todo"}, "identifier": "DEV-2"},
        ]),
    ])
    updated, created = dv.linear_delta_count("2026-04-20T00:00:00Z")
    assert created == 2


def test_linear_delta_graphql_errors_raise(dv, monkeypatch):
    """'errors' key in response → RuntimeError. A missing check would let
    partial/empty data masquerade as delta=0 and greenlight cutover."""
    monkeypatch.setenv("LINEAR_API_KEY", "key")
    _install_requests_fake(dv, post_responses=[
        _FakeResponse(200, {"errors": [{"message": "bad filter"}]}),
    ])
    with pytest.raises(RuntimeError, match="Linear GraphQL error"):
        dv.linear_delta_count("2026-04-20T00:00:00Z")


def test_linear_delta_new_blocked_row_raises(dv, monkeypatch):
    """H-1: a NEW Blocked row post-Gate-1 must abort (exit 6 from main).
    The test pins the RuntimeError path."""
    monkeypatch.setenv("LINEAR_API_KEY", "key")
    _install_requests_fake(dv, post_responses=[
        _linear_page([
            {"id": "X", "createdAt": "2026-04-22T00:00:00Z",
             "updatedAt": "2026-04-22T00:00:00Z",
             "state": {"name": "Blocked"}, "identifier": "DEV-99"},
        ]),
    ])
    with pytest.raises(RuntimeError, match="new Blocked rows"):
        dv.linear_delta_count("2026-04-20T00:00:00Z")


# ── github_delta_count ───────────────────────────────────────────────────────

def test_github_delta_skips_pull_requests(dv, monkeypatch):
    """GH's /issues endpoint returns issues + PRs; PRs carry 'pull_request'
    key. Regression that included PRs in the count would inflate Δ and
    trigger spurious PAUSE/ABORT."""
    monkeypatch.setenv("GITHUB_PAT", "tok")
    _install_requests_fake(dv, get_responses=[
        _FakeResponse(200, [
            {"id": 1, "created_at": "2026-04-22T00:00:00Z",
             "updated_at": "2026-04-22T00:00:00Z"},
            {"id": 2, "pull_request": {}, "created_at": "2026-04-22T00:00:00Z",
             "updated_at": "2026-04-22T00:00:00Z"},
        ]),
    ])
    updated, created = dv.github_delta_count("2026-04-20T00:00:00Z")
    assert updated + created == 1  # PR skipped


def test_github_delta_partitions_created_vs_updated(dv, monkeypatch):
    monkeypatch.setenv("GITHUB_PAT", "tok")
    _install_requests_fake(dv, get_responses=[
        _FakeResponse(200, [
            {"id": 1, "created_at": "2026-04-22T00:00:00Z",  # after cutoff
             "updated_at": "2026-04-22T00:00:00Z"},
            {"id": 2, "created_at": "2026-04-01T00:00:00Z",  # before cutoff
             "updated_at": "2026-04-22T00:00:00Z"},
        ]),
    ])
    updated, created = dv.github_delta_count("2026-04-20T00:00:00Z")
    assert created == 1
    assert updated == 1


def test_github_delta_follows_link_header_pagination(dv, monkeypatch):
    """GH pagination is Link header based, rel='next'. Missing the
    follow-up page would under-count delta."""
    monkeypatch.setenv("GITHUB_PAT", "tok")
    _install_requests_fake(dv, get_responses=[
        _FakeResponse(
            200,
            [{"id": 1, "created_at": "2026-04-22T00:00:00Z",
              "updated_at": "2026-04-22T00:00:00Z"}],
            headers={"Link": '<https://api.github.com/next>; rel="next"'},
        ),
        _FakeResponse(
            200,
            [{"id": 2, "created_at": "2026-04-23T00:00:00Z",
              "updated_at": "2026-04-23T00:00:00Z"}],
            headers={},
        ),
    ])
    updated, created = dv.github_delta_count("2026-04-20T00:00:00Z")
    assert created == 2


# ── main(): default mode decision matrix ─────────────────────────────────────

def test_main_missing_gate_1_timestamp_exits_2(dv, monkeypatch):
    """No baseline timestamp in Redis → exit 2 (cutover precondition)."""
    monkeypatch.setattr("sys.argv", ["delta-verify.py"])
    _install_redis_fake(dv, initial={})  # nothing in redis
    assert dv.main() == 2


def test_main_api_request_exception_returns_3(dv, monkeypatch):
    """Any requests.RequestException during source queries → exit 3 —
    generic 'source API down' sentinel for the runbook."""
    monkeypatch.setenv("LINEAR_API_KEY", "k")
    monkeypatch.setenv("GITHUB_PAT", "t")
    monkeypatch.setattr("sys.argv", ["delta-verify.py"])
    _install_redis_fake(dv, initial={dv.GATE_1_TS_KEY: "2026-04-20T00:00:00Z"})

    fake_requests = types.SimpleNamespace()
    class FakeRE(Exception): pass
    fake_requests.RequestException = FakeRE
    def post(*a, **k): raise FakeRE("boom")
    def get(*a, **k): raise FakeRE("boom")
    fake_requests.post = post
    fake_requests.get = get
    dv.requests = fake_requests

    assert dv.main() == 3


def test_main_new_blocker_runtime_returns_6(dv, monkeypatch):
    """H-1: RuntimeError from linear_delta_count → exit 6."""
    monkeypatch.setenv("LINEAR_API_KEY", "k")
    monkeypatch.setenv("GITHUB_PAT", "t")
    monkeypatch.setattr("sys.argv", ["delta-verify.py"])
    _install_redis_fake(dv, initial={dv.GATE_1_TS_KEY: "2026-04-20T00:00:00Z"})
    # Force linear to raise (GH never reached)
    def bad_linear(since): raise RuntimeError("1 new Blocked rows post-Gate-1")
    dv.linear_delta_count = bad_linear
    dv.github_delta_count = lambda s: (0, 0)
    assert dv.main() == 6


def test_main_proceed_records_baseline(dv, monkeypatch):
    """Δ ≤ 5 → exit 0, baseline recorded."""
    monkeypatch.setenv("LINEAR_API_KEY", "k")
    monkeypatch.setenv("GITHUB_PAT", "t")
    monkeypatch.setattr("sys.argv", ["delta-verify.py"])
    store, calls = _install_redis_fake(
        dv, initial={dv.GATE_1_TS_KEY: "2026-04-20T00:00:00Z"}
    )
    dv.linear_delta_count = lambda s: (1, 1)
    dv.github_delta_count = lambda s: (1, 0)
    assert dv.main() == 0
    # Baseline recorded
    assert store[dv.BASELINE_KEY] == "3"


def test_main_pause_records_baseline(dv, monkeypatch):
    """5 < Δ ≤ 20 → exit 1, baseline recorded."""
    monkeypatch.setenv("LINEAR_API_KEY", "k")
    monkeypatch.setenv("GITHUB_PAT", "t")
    monkeypatch.setattr("sys.argv", ["delta-verify.py"])
    store, calls = _install_redis_fake(
        dv, initial={dv.GATE_1_TS_KEY: "2026-04-20T00:00:00Z"}
    )
    dv.linear_delta_count = lambda s: (5, 3)
    dv.github_delta_count = lambda s: (2, 0)
    assert dv.main() == 1
    assert store[dv.BASELINE_KEY] == "10"


def test_main_abort_does_NOT_record_baseline_H2(dv, monkeypatch):
    """H-2 tripwire: Δ > 20 → exit 2 (ABORT), baseline MUST NOT be written.
    A regression that recorded the baseline here would poison the next
    --strict re-run (drift=0 against the fraudulent baseline)."""
    monkeypatch.setenv("LINEAR_API_KEY", "k")
    monkeypatch.setenv("GITHUB_PAT", "t")
    monkeypatch.setattr("sys.argv", ["delta-verify.py"])
    store, calls = _install_redis_fake(
        dv, initial={dv.GATE_1_TS_KEY: "2026-04-20T00:00:00Z"}
    )
    dv.linear_delta_count = lambda s: (30, 0)  # Δ = 30 > 20
    dv.github_delta_count = lambda s: (0, 0)
    assert dv.main() == 2
    # Critical: baseline NOT in store, and no SET call for the baseline key
    assert dv.BASELINE_KEY not in store
    baseline_sets = [k for k, _ in calls["set"] if k == dv.BASELINE_KEY]
    assert baseline_sets == [], (
        f"H-2 violated: ABORT path wrote baseline {baseline_sets!r}"
    )


# ── main(): --strict mode (M-β) ──────────────────────────────────────────────

def test_main_strict_missing_baseline_returns_4(dv, monkeypatch):
    """--strict without a prior baseline → exit 4. Prevents a strict check
    from passing when the manual pre-run was skipped."""
    monkeypatch.setenv("LINEAR_API_KEY", "k")
    monkeypatch.setenv("GITHUB_PAT", "t")
    monkeypatch.setattr("sys.argv", ["delta-verify.py", "--strict"])
    _install_redis_fake(dv, initial={dv.GATE_1_TS_KEY: "2026-04-20T00:00:00Z"})
    dv.linear_delta_count = lambda s: (0, 0)
    dv.github_delta_count = lambda s: (0, 0)
    assert dv.main() == 4


def test_main_strict_within_tolerance_returns_0(dv, monkeypatch):
    """--strict with drift ≤ 5 → exit 0 (cutover may proceed)."""
    monkeypatch.setenv("LINEAR_API_KEY", "k")
    monkeypatch.setenv("GITHUB_PAT", "t")
    monkeypatch.setattr("sys.argv", ["delta-verify.py", "--strict"])
    _install_redis_fake(dv, initial={
        dv.GATE_1_TS_KEY: "2026-04-20T00:00:00Z",
        dv.BASELINE_KEY: "10",
    })
    dv.linear_delta_count = lambda s: (5, 7)  # current = 12, baseline = 10 → drift 2
    dv.github_delta_count = lambda s: (0, 0)
    assert dv.main() == 0


def test_main_strict_drift_exceeds_tolerance_returns_5(dv, monkeypatch):
    """--strict with drift > 5 → exit 5 (material drift, ABORT cutover)."""
    monkeypatch.setenv("LINEAR_API_KEY", "k")
    monkeypatch.setenv("GITHUB_PAT", "t")
    monkeypatch.setattr("sys.argv", ["delta-verify.py", "--strict"])
    _install_redis_fake(dv, initial={
        dv.GATE_1_TS_KEY: "2026-04-20T00:00:00Z",
        dv.BASELINE_KEY: "10",
    })
    # drift 8 > tolerance 5
    dv.linear_delta_count = lambda s: (10, 8)  # current = 18
    dv.github_delta_count = lambda s: (0, 0)
    assert dv.main() == 5


# ── Threshold constants (invariants) ─────────────────────────────────────────

def test_drift_tolerance_is_5(dv):
    """Runbook decision matrix: drift tolerance is 5. Accidental edit would
    loosen/tighten the gate silently."""
    assert dv.DRIFT_TOLERANCE == 5


def test_abort_threshold_is_20(dv):
    """Runbook decision matrix: ABORT threshold is 20."""
    assert dv.DELTA_ABORT_THRESHOLD == 20


def test_baseline_and_gate_1_keys_are_namespaced(dv):
    """Redis key shape is load-bearing — the cutover-to-tasks.sh reader
    uses the same keys. A rename without coordinated change would break
    strict mode silently."""
    assert dv.GATE_1_TS_KEY == "cabinet:migration:039:gate-1-completed-at"
    assert dv.BASELINE_KEY == "cabinet:migration:039:delta-pre-cutover:count"
