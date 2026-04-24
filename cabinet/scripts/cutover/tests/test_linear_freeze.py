"""Tests for cutover/linear-freeze.py (Spec 039 §5.9 Gate 4 Step 2).

linear-freeze.py is the last safety-critical cutover module without harness
coverage. It drives the write-freeze sequence for Linear:

  Phase 2a — demote ALL service-account members to Viewer on every team.
  Phase 2b — revoke ALL service-account API keys (semi-manual; operator-driven
              via Linear UI with script-assisted verification).

This harness pins the following adversary invariants:

  H-α  — Phase 2a completes for ALL members BEFORE Phase 2b starts. The
          `all_svc_members_demoted == True` gate prevents mid-loop self-lockout
          when the operator's own key is among those being revoked.

  H-γ  — Service-account enumeration derived from officer-emails.yml at runtime
          (not hardcoded); Captain explicitly excluded via assert_captain_excluded.
          We pin that phase_2a filters strictly to svc_account emails and that
          non-svc-account members are silently skipped.

  M-δ  — 429 rate-limit handling: honors Retry-After header, applies RETRY_FLOOR_SEC
          floor (2s), RETRY_CAP_SEC cap (60s), and raises after MAX_RETRIES (3)
          exhausted. We assert sleep durations and raise_for_status behavior.

  N-M-γ — teamMembershipUpdate mutation shape is NOT stable across Linear API
          versions. verify_mutation_shape() introspects Team / TeamMembership /
          TeamMembershipUpdateInput and raises RuntimeError if required fields
          missing. Runs in both normal mode AND --verify-schema mode.

  B-2  — team.members returns User (no membership.id); script correctly uses
          team.memberships so we carry TeamMembership ids for the mutation.
          Failure of Team.memberships field verification is explicitly tested.

The `requests` module is stubbed by conftest.py to a bare ModuleType.
We replace linear_freeze.requests with a minimal namespace carrying post()
and the RequestException type that every branch the module touches.

Hyphen in 'linear-freeze.py' forbids plain import; we use importlib.util
(identical pattern to test_gh_freeze.py and test_delta_verify.py).
"""
from __future__ import annotations

import importlib.util as _ilu
import types
from pathlib import Path

import pytest


# ── Module loader ─────────────────────────────────────────────────────────────

_CUTOVER = Path(__file__).resolve().parent.parent


def _load_module():
    """Load linear-freeze.py fresh via importlib to avoid hyphen-import error."""
    spec = _ilu.spec_from_file_location(
        "linear_freeze_under_test", _CUTOVER / "linear-freeze.py"
    )
    mod = _ilu.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def lf():
    """Fresh linear-freeze module per test.

    Adds RequestException to the conftest-stubbed requests namespace so that
    any future `except requests.RequestException` clause in the module does
    not raise AttributeError during handler lookup — same defensive pattern
    used by test_delta_verify.py.
    """
    mod = _load_module()
    if not hasattr(mod.requests, "RequestException"):
        mod.requests.RequestException = type("RequestException", (Exception,), {})
    return mod


# ── Shared fakes ─────────────────────────────────────────────────────────────


class _FakeResponse:
    """Minimal requests.Response surrogate.

    Exposes status_code, headers dict, .json(), and raise_for_status() —
    the complete surface that linear-freeze.py touches.
    """

    def __init__(
        self,
        status_code: int,
        json_body: dict | None = None,
        headers: dict | None = None,
        text: str = "",
    ):
        self.status_code = status_code
        self._json = json_body if json_body is not None else {}
        self.headers = headers or {}
        self.text = text

    def json(self):
        return self._json

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")


def _install_fake_requests(mod, post_responses=None):
    """Replace mod.requests with a namespace whose post() pops from a list.

    Enables simulating sequences (e.g. 429 then 200, multi-page, etc.).
    Each consumed response is recorded in calls["post"] for assertion.

    Returns the calls dict.
    """
    responses = list(post_responses or [])
    calls = {"post": []}

    def post(url, headers=None, json=None, timeout=None):
        calls["post"].append({"url": url, "headers": headers, "json": json})
        if not responses:
            # Default: empty-nodes happy-path response
            return _FakeResponse(200, {"data": {"teams": {"nodes": []}}})
        return responses.pop(0)

    ns = types.SimpleNamespace(
        post=post,
        RequestException=type("RequestException", (Exception,), {}),
    )
    mod.requests = ns
    return calls


# ── Group 1: _post_with_429 — M-δ rate-limit adversary ───────────────────────


def test_post_429_200_happy_returns_data_dict(lf):
    """200 response with no 'errors' key → returns the data dict."""
    payload = {"data": {"foo": "bar"}}
    _install_fake_requests(lf, post_responses=[_FakeResponse(200, payload)])
    result = lf._post_with_429("query {}", {}, {})
    assert result == payload


def test_post_429_200_with_errors_key_raises_runtime_error(lf):
    """200 response with 'errors' key → RuntimeError('Linear error: ...')."""
    payload = {"errors": [{"message": "bad query"}]}
    _install_fake_requests(lf, post_responses=[_FakeResponse(200, payload)])
    with pytest.raises(RuntimeError, match="Linear error"):
        lf._post_with_429("query {}", {}, {})


def test_post_429_honors_retry_after_header(lf, monkeypatch):
    """429 with numeric Retry-After → sleep for exactly that many seconds,
    then the subsequent 200 is returned.  M-δ adversary: without Retry-After
    handling the script hammers Linear with retries and gets banned."""
    slept = []
    monkeypatch.setattr(lf.time, "sleep", lambda s: slept.append(s))

    payload = {"data": {"result": True}}
    _install_fake_requests(
        lf,
        post_responses=[
            _FakeResponse(429, headers={"Retry-After": "10"}),
            _FakeResponse(200, payload),
        ],
    )
    result = lf._post_with_429("query {}", {}, {})
    assert result == payload
    # Must have slept exactly the Retry-After value (≥ floor)
    assert len(slept) == 1
    assert slept[0] == 10


def test_post_429_non_int_retry_after_uses_floor(lf, monkeypatch):
    """429 with non-int Retry-After ('later') → falls back to RETRY_FLOOR_SEC (2s)."""
    slept = []
    monkeypatch.setattr(lf.time, "sleep", lambda s: slept.append(s))

    payload = {"data": {"ok": True}}
    _install_fake_requests(
        lf,
        post_responses=[
            _FakeResponse(429, headers={"Retry-After": "later"}),
            _FakeResponse(200, payload),
        ],
    )
    lf._post_with_429("query {}", {}, {})
    assert len(slept) == 1
    assert slept[0] == lf.RETRY_FLOOR_SEC


def test_post_429_exceeds_max_retries_raises(lf, monkeypatch):
    """429 responses exhausting MAX_RETRIES (3) → raise_for_status propagates.

    M-δ: the script must not loop infinitely when the API is down for longer
    than the retry budget.
    """
    monkeypatch.setattr(lf.time, "sleep", lambda s: None)

    # MAX_RETRIES + 1 = 4 responses; the last one is the "terminal" 429
    # that triggers raise_for_status.
    all_429 = [_FakeResponse(429, headers={"Retry-After": "1"})] * (lf.MAX_RETRIES + 1)
    _install_fake_requests(lf, post_responses=all_429)

    with pytest.raises(RuntimeError, match="HTTP 429"):
        lf._post_with_429("query {}", {}, {})


# ── Group 2: _introspect_type ─────────────────────────────────────────────────


def test_introspect_type_found_returns_dict(lf):
    """Type present in schema → returns the __type dict."""
    type_dict = {"name": "Team", "kind": "OBJECT", "fields": [], "inputFields": None}
    payload = {"data": {"__type": type_dict}}
    _install_fake_requests(lf, post_responses=[_FakeResponse(200, payload)])
    result = lf._introspect_type("Team", {})
    assert result == type_dict


def test_introspect_type_null_returns_none(lf):
    """__type returns null (type not in schema) → None.

    N-M-γ: a missing type is the signal that the mutation path has drifted.
    """
    payload = {"data": {"__type": None}}
    _install_fake_requests(lf, post_responses=[_FakeResponse(200, payload)])
    result = lf._introspect_type("NonExistent", {})
    assert result is None


# ── Group 3: verify_mutation_shape — N-M-γ / B-2 schema-drift adversary ──────


def _make_introspect_dispatcher(overrides: dict):
    """Return a _post_with_429 replacement that dispatches by type name.

    overrides: {type_name: __type value or None}
    Missing names return a minimal valid type so tests can focus on one error.
    """
    defaults = {
        "Team": {
            "name": "Team",
            "kind": "OBJECT",
            "fields": [{"name": "memberships"}, {"name": "id"}],
            "inputFields": None,
        },
        "TeamMembership": {
            "name": "TeamMembership",
            "kind": "OBJECT",
            "fields": [{"name": "id"}, {"name": "user"}],
            "inputFields": None,
        },
        "TeamMembershipUpdateInput": {
            "name": "TeamMembershipUpdateInput",
            "kind": "INPUT_OBJECT",
            "fields": None,
            "inputFields": [{"name": "role"}],
        },
    }

    def _fake_post(query, variables, headers):
        name = variables.get("name", "")
        type_val = overrides.get(name, defaults.get(name))
        return {"data": {"__type": type_val}}

    return _fake_post


def test_verify_mutation_shape_all_present_no_errors(lf):
    """All 3 types + all required fields → report.errors empty, no raise."""
    lf._post_with_429 = _make_introspect_dispatcher({})
    report = lf.verify_mutation_shape({})
    assert report["errors"] == []
    assert any("Team.memberships" in v for v in report["verified"])


def test_verify_mutation_shape_team_type_missing_raises(lf):
    """Team type not found in schema → RuntimeError with 'Team type not found'."""
    lf._post_with_429 = _make_introspect_dispatcher({"Team": None})
    with pytest.raises(RuntimeError, match="Team type not found"):
        lf.verify_mutation_shape({})


def test_verify_mutation_shape_team_memberships_missing_raises(lf):
    """Team type exists but lacks 'memberships' field → error referencing B-2 fix.

    B-2: team.members returns User (no membership.id); we need team.memberships.
    """
    lf._post_with_429 = _make_introspect_dispatcher(
        {
            "Team": {
                "name": "Team",
                "kind": "OBJECT",
                # Only 'members', not 'memberships'
                "fields": [{"name": "members"}, {"name": "id"}],
                "inputFields": None,
            }
        }
    )
    with pytest.raises(RuntimeError, match="Team.memberships field missing"):
        lf.verify_mutation_shape({})


def test_verify_mutation_shape_team_membership_id_missing_raises(lf):
    """TeamMembership type missing 'id' field → RuntimeError."""
    lf._post_with_429 = _make_introspect_dispatcher(
        {
            "TeamMembership": {
                "name": "TeamMembership",
                "kind": "OBJECT",
                # 'id' is gone — user still present
                "fields": [{"name": "user"}],
                "inputFields": None,
            }
        }
    )
    with pytest.raises(RuntimeError, match="TeamMembership.id missing"):
        lf.verify_mutation_shape({})


def test_verify_mutation_shape_input_type_missing_raises(lf):
    """TeamMembershipUpdateInput not in schema → RuntimeError with 'mutation path invalid'."""
    lf._post_with_429 = _make_introspect_dispatcher(
        {"TeamMembershipUpdateInput": None}
    )
    with pytest.raises(RuntimeError, match="mutation path invalid"):
        lf.verify_mutation_shape({})


def test_verify_mutation_shape_input_role_missing_raises(lf):
    """TeamMembershipUpdateInput exists but lacks 'role' → RuntimeError
    referencing workspace-level mutation (N-M-γ / B-2 combined signal)."""
    lf._post_with_429 = _make_introspect_dispatcher(
        {
            "TeamMembershipUpdateInput": {
                "name": "TeamMembershipUpdateInput",
                "kind": "INPUT_OBJECT",
                "fields": None,
                # 'role' absent
                "inputFields": [{"name": "teamId"}],
            }
        }
    )
    with pytest.raises(RuntimeError, match="workspace-level mutation"):
        lf.verify_mutation_shape({})


# ── Group 4: _list_teams ──────────────────────────────────────────────────────


def test_list_teams_returns_nodes(lf):
    """Happy path: returns the list of team node dicts."""
    nodes = [{"id": "t1", "name": "Engineering", "key": "ENG"}]
    payload = {"data": {"teams": {"nodes": nodes}}}
    _install_fake_requests(lf, post_responses=[_FakeResponse(200, payload)])
    result = lf._list_teams({})
    assert result == nodes


# ── Group 5: _list_team_memberships ──────────────────────────────────────────


def _tm_page(nodes, *, has_next=False, cursor=None):
    """Helper: build a _post_with_429 response for a team memberships page."""
    return _FakeResponse(
        200,
        {
            "data": {
                "team": {
                    "memberships": {
                        "pageInfo": {"hasNextPage": has_next, "endCursor": cursor},
                        "nodes": nodes,
                    }
                }
            }
        },
    )


def test_list_team_memberships_single_page(lf):
    """Single page (hasNextPage: false) → returns all nodes, exactly 1 POST call."""
    nodes = [
        {"id": "m1", "user": {"id": "u1", "email": "cto@sensed.internal", "name": "CTO"}},
        {"id": "m2", "user": {"id": "u2", "email": "cpo@sensed.internal", "name": "CPO"}},
    ]
    calls = _install_fake_requests(lf, post_responses=[_tm_page(nodes)])
    result = lf._list_team_memberships("team-abc", {})
    assert result == nodes
    assert len(calls["post"]) == 1


def test_list_team_memberships_multi_page_concatenates(lf):
    """Multi-page (hasNextPage true then false) → nodes from both pages concatenated,
    second POST carries 'after' cursor.  B-2: cursor-based pagination needed
    for large teams.
    """
    page1_nodes = [{"id": "m1", "user": {"id": "u1", "email": "a@x.io", "name": "A"}}]
    page2_nodes = [{"id": "m2", "user": {"id": "u2", "email": "b@x.io", "name": "B"}}]
    calls = _install_fake_requests(
        lf,
        post_responses=[
            _tm_page(page1_nodes, has_next=True, cursor="cursor-1"),
            _tm_page(page2_nodes, has_next=False),
        ],
    )
    result = lf._list_team_memberships("team-xyz", {})
    assert result == page1_nodes + page2_nodes
    assert len(calls["post"]) == 2
    # Second POST must carry the cursor
    second_vars = calls["post"][1]["json"]["variables"]
    assert second_vars.get("after") == "cursor-1"


# ── Group 6: _demote_member ───────────────────────────────────────────────────


def test_demote_member_success_true_returns_true(lf):
    """success:true from teamMembershipUpdate → returns True."""
    payload = {"data": {"teamMembershipUpdate": {"success": True}}}
    _install_fake_requests(lf, post_responses=[_FakeResponse(200, payload)])
    assert lf._demote_member("membership-1", {}) is True


def test_demote_member_success_false_returns_false(lf):
    """success:false → returns False.  Caller (phase_2a) decides to raise."""
    payload = {"data": {"teamMembershipUpdate": {"success": False}}}
    _install_fake_requests(lf, post_responses=[_FakeResponse(200, payload)])
    assert lf._demote_member("membership-2", {}) is False


# ── Group 7: phase_2a_demote_members — H-α / H-γ enforcement ─────────────────


def _make_teams(*keys):
    """Return a list of minimal team dicts for the given keys."""
    return [{"id": f"id-{k}", "name": k, "key": k} for k in keys]


def test_phase_2a_happy_path_two_teams(lf):
    """H-α: 2 teams × 2 svc-account memberships = 4 demote calls, returns True."""
    svc_emails = ["cto@sensed.internal", "cpo@sensed.internal"]
    teams = _make_teams("ENG", "OPS")
    memberships = [
        {"id": "m-cto", "user": {"id": "u1", "email": "cto@sensed.internal", "name": "CTO"}},
        {"id": "m-cpo", "user": {"id": "u2", "email": "cpo@sensed.internal", "name": "CPO"}},
    ]
    demote_calls = []

    lf._list_teams = lambda h: teams
    lf._list_team_memberships = lambda tid, h: memberships
    lf._demote_member = lambda mid, h: demote_calls.append(mid) or True

    result = lf.phase_2a_demote_members({}, svc_emails)
    assert result is True
    # 2 teams × 2 svc-account members = 4 demote calls
    assert len(demote_calls) == 4


def test_phase_2a_filters_non_svc_account_members(lf):
    """H-γ: non-svc-account members (captain, guests) MUST be skipped."""
    svc_emails = ["cto@sensed.internal"]
    teams = _make_teams("ENG")
    memberships = [
        {"id": "m-cto", "user": {"email": "cto@sensed.internal", "name": "CTO"}},
        {"id": "m-cap", "user": {"email": "nate@sensed.io", "name": "Nate"}},  # Captain — must skip
        {"id": "m-unk", "user": {"email": "guest@external.com", "name": "Guest"}},  # external — skip
    ]
    demote_calls = []

    lf._list_teams = lambda h: teams
    lf._list_team_memberships = lambda tid, h: memberships
    lf._demote_member = lambda mid, h: demote_calls.append(mid) or True

    lf.phase_2a_demote_members({}, svc_emails)
    # Only the CTO membership should have been demoted
    assert demote_calls == ["m-cto"]


def test_phase_2a_demote_false_raises_runtime_error(lf):
    """H-α: _demote_member returning False mid-loop → RuntimeError with team.key + email.

    This ensures phase_2b is NEVER reached when any demote fails.
    """
    svc_emails = ["cto@sensed.internal"]
    teams = _make_teams("ENG")
    memberships = [
        {"id": "m-cto", "user": {"email": "cto@sensed.internal", "name": "CTO"}},
    ]

    lf._list_teams = lambda h: teams
    lf._list_team_memberships = lambda tid, h: memberships
    lf._demote_member = lambda mid, h: False  # simulate failure

    with pytest.raises(RuntimeError) as exc:
        lf.phase_2a_demote_members({}, svc_emails)
    msg = str(exc.value)
    assert "ENG" in msg
    assert "cto@sensed.internal" in msg


def test_phase_2a_empty_svc_accounts_no_demotes(lf):
    """Empty svc_accounts list → no demote calls, returns True cleanly."""
    demote_calls = []
    lf._list_teams = lambda h: _make_teams("ENG")
    lf._list_team_memberships = lambda tid, h: [
        {"id": "m1", "user": {"email": "cto@x.io", "name": "CTO"}}
    ]
    lf._demote_member = lambda mid, h: demote_calls.append(mid) or True

    result = lf.phase_2a_demote_members({}, [])
    assert result is True
    assert demote_calls == []


# ── Group 8: _verify_key_revoked ─────────────────────────────────────────────


def test_verify_key_revoked_401_returns_true(lf):
    """401 response → key has been revoked."""
    _install_fake_requests(lf, post_responses=[_FakeResponse(401)])
    assert lf._verify_key_revoked("lin_abc123") is True


def test_verify_key_revoked_403_returns_true(lf):
    """403 Forbidden → also treated as revoked (Linear uses either code)."""
    _install_fake_requests(lf, post_responses=[_FakeResponse(403)])
    assert lf._verify_key_revoked("lin_abc123") is True


def test_verify_key_revoked_200_with_viewer_id_returns_false(lf):
    """200 + data.viewer.id present → key is still live, not revoked."""
    payload = {"data": {"viewer": {"id": "user-xyz"}}}
    _install_fake_requests(lf, post_responses=[_FakeResponse(200, payload)])
    assert lf._verify_key_revoked("lin_live_key") is False


def test_verify_key_revoked_500_returns_false_fail_closed(lf):
    """500 server error → conservative fail-closed: treat as 'not confirmed revoked'.

    COO LOW: unknown state must block cutover, not silently pass it.
    """
    _install_fake_requests(lf, post_responses=[_FakeResponse(500)])
    assert lf._verify_key_revoked("lin_unknown") is False


# ── Group 9: phase_2b_revoke_keys ────────────────────────────────────────────


def test_phase_2b_missing_keys_env_var_raises(lf, monkeypatch):
    """LINEAR_API_KEYS_TO_REVOKE unset → RuntimeError('no keys to revoke').

    H-α ordering: the script must refuse to proceed if the operator hasn't
    configured which keys to revoke.
    """
    monkeypatch.delenv("LINEAR_API_KEYS_TO_REVOKE", raising=False)
    with pytest.raises(RuntimeError, match="no keys to revoke"):
        lf.phase_2b_revoke_keys("LINEAR_API_KEY_CTO")


def test_phase_2b_operator_key_appears_last(lf, monkeypatch, capsys):
    """H-α ordering invariant: the operator key must be printed LAST in the
    manual-revocation list so the operator revokes non-operator keys first,
    preventing mid-Phase-2a self-lockout.
    """
    monkeypatch.setenv("LINEAR_API_KEYS_TO_REVOKE", "LINEAR_API_KEY_COS LINEAR_API_KEY_CPO LINEAR_API_KEY_CTO")
    monkeypatch.setenv("LINEAR_API_KEY_COS", "lin_cos_xxxx")
    monkeypatch.setenv("LINEAR_API_KEY_CPO", "lin_cpo_xxxx")
    monkeypatch.setenv("LINEAR_API_KEY_CTO", "lin_cto_xxxx")

    # Stub _verify_key_revoked to return True for all keys
    lf._verify_key_revoked = lambda k: True
    # Stub input() so we don't block on user prompt
    monkeypatch.setattr("builtins.input", lambda prompt="": "")

    lf.phase_2b_revoke_keys("LINEAR_API_KEY_CTO")

    captured = capsys.readouterr()
    output = captured.out

    # Find line positions for each key label in the printed output
    cos_pos = output.find("LINEAR_API_KEY_COS")
    cpo_pos = output.find("LINEAR_API_KEY_CPO")
    cto_pos = output.find("LINEAR_API_KEY_CTO")

    # Operator key (CTO) must appear after the others
    assert cto_pos > cos_pos, "Operator key must print AFTER LINEAR_API_KEY_COS"
    assert cto_pos > cpo_pos, "Operator key must print AFTER LINEAR_API_KEY_CPO"
    # Operator-key marker present
    assert "OPERATOR KEY" in output or "revoke LAST" in output.lower() or "LAST" in output


def test_phase_2b_unset_env_var_for_named_key_raises(lf, monkeypatch):
    """COO LOW fail-closed: if a key env var name is listed but not set in the
    environment, that key cannot be verified — treat as unrevoked and raise.

    A typo'd env-var name would otherwise silently skip revocation, leaving
    the key LIVE post-freeze while the runbook reports clean.
    """
    monkeypatch.setenv("LINEAR_API_KEYS_TO_REVOKE", "LINEAR_API_KEY_COS LINEAR_API_KEY_TYPO")
    monkeypatch.setenv("LINEAR_API_KEY_COS", "lin_cos_xxxx")
    monkeypatch.delenv("LINEAR_API_KEY_TYPO", raising=False)  # typo'd name — not in env

    lf._verify_key_revoked = lambda k: True
    monkeypatch.setattr("builtins.input", lambda prompt="": "")

    with pytest.raises(RuntimeError) as exc:
        lf.phase_2b_revoke_keys("LINEAR_API_KEY_COS")
    assert "still live" in str(exc.value).lower() or "LINEAR_API_KEY_TYPO" in str(exc.value)


def test_phase_2b_all_keys_revoked_completes_cleanly(lf, monkeypatch):
    """All keys verified as revoked → no RuntimeError, runs to completion."""
    monkeypatch.setenv("LINEAR_API_KEYS_TO_REVOKE", "LINEAR_API_KEY_COS LINEAR_API_KEY_CTO")
    monkeypatch.setenv("LINEAR_API_KEY_COS", "lin_cos_xxxx")
    monkeypatch.setenv("LINEAR_API_KEY_CTO", "lin_cto_xxxx")

    lf._verify_key_revoked = lambda k: True
    monkeypatch.setattr("builtins.input", lambda prompt="": "")

    # Must not raise
    lf.phase_2b_revoke_keys("LINEAR_API_KEY_CTO")


# ── Group 10: main() exit codes ──────────────────────────────────────────────


def _stub_verify_and_enum(lf, monkeypatch, *, verify_raises=False, phase_2a_result=True):
    """Install canned stubs for schema verify + enumeration + phase functions."""
    if verify_raises:
        lf.verify_mutation_shape = lambda h, **kw: (_ for _ in ()).throw(
            RuntimeError("Schema verification FAILED:\n  Team type not found in schema")
        )
    else:
        lf.verify_mutation_shape = lambda h, **kw: {"verified": [], "warnings": [], "errors": []}

    lf.enumerate_linear_demotion_targets = lambda: (["cto@x.io"], ["nate@x.io"])
    lf.assert_captain_excluded = lambda *a, **k: None
    lf.phase_2a_demote_members = lambda h, svc: phase_2a_result
    lf.phase_2b_revoke_keys = lambda op: None


def test_main_missing_api_key_exits_2(lf, monkeypatch):
    """LINEAR_API_KEY not set → exit 2.  Prevents silent dry-run masquerade."""
    monkeypatch.delenv("LINEAR_API_KEY", raising=False)
    monkeypatch.setattr("sys.argv", ["linear-freeze.py"])
    assert lf.main() == 2


def test_main_schema_verify_failure_exits_4(lf, monkeypatch):
    """verify_mutation_shape raises RuntimeError → exit 4 (schema drift abort)."""
    monkeypatch.setenv("LINEAR_API_KEY", "lin_op_key")
    monkeypatch.setattr("sys.argv", ["linear-freeze.py"])

    # Patch to raise
    def _raise(h, **kw):
        raise RuntimeError("Schema verification FAILED:\n  Team type not found in schema")

    lf.verify_mutation_shape = _raise
    assert lf.main() == 4


def test_main_verify_schema_mode_exits_0_without_phase_calls(lf, monkeypatch):
    """--verify-schema flag → exit 0, phase_2a + phase_2b are NEVER called.

    N-M-γ: pre-cutover operator can check schema without risking mutations.
    """
    monkeypatch.setenv("LINEAR_API_KEY", "lin_op_key")
    monkeypatch.setattr("sys.argv", ["linear-freeze.py", "--verify-schema"])

    phase_calls = []
    lf.verify_mutation_shape = lambda h, **kw: {"verified": [], "warnings": [], "errors": []}
    lf.enumerate_linear_demotion_targets = lambda: (["cto@x.io"], ["nate@x.io"])
    lf.assert_captain_excluded = lambda *a, **k: None
    lf.phase_2a_demote_members = lambda h, svc: phase_calls.append("2a") or True
    lf.phase_2b_revoke_keys = lambda op: phase_calls.append("2b")

    result = lf.main()
    assert result == 0
    assert phase_calls == [], (
        f"--verify-schema mode must NOT call phase functions; called: {phase_calls}"
    )


def test_main_phase_2a_returns_false_exits_3(lf, monkeypatch):
    """H-α belt-and-suspenders: if phase_2a_demote_members somehow returns False
    (normally it raises, but the defensive branch catches it), main() exits 3
    and does NOT proceed to Phase 2b.
    """
    monkeypatch.setenv("LINEAR_API_KEY", "lin_op_key")
    monkeypatch.setattr("sys.argv", ["linear-freeze.py"])

    phase_2b_called = []
    lf.verify_mutation_shape = lambda h, **kw: {"verified": [], "warnings": [], "errors": []}
    lf.enumerate_linear_demotion_targets = lambda: (["cto@x.io"], ["nate@x.io"])
    lf.assert_captain_excluded = lambda *a, **k: None
    lf.phase_2a_demote_members = lambda h, svc: False  # returns False instead of raising
    lf.phase_2b_revoke_keys = lambda op: phase_2b_called.append(True)

    result = lf.main()
    assert result == 3
    assert phase_2b_called == [], "Phase 2b must NOT be called when Phase 2a reports failure"
