"""Tests for cutover/gh-freeze.py (Spec 039 §5.9 Gate 4 Step 3).

gh-freeze demotes Cabinet bot collaborators on nate-step/captains-cabinet
from write → read via PATCH /repos/{owner}/{repo}/collaborators/{user}.
Two branches came from COO adversary review (M-α: mechanism decision,
M-2: 201 means invitation-not-demotion, must NOT claim success). The
post-demote verify is a fail-closed gate: any bot that didn't end up at
permission=read aborts the runbook.

This harness pins:
  - every HTTP status-code branch in _demote_collaborator (204 happy,
    201 invitation, 404 not-a-collab, 500 raise-for-status)
  - _verify_collaborator_permission's response shape (200 OK returns
    permission; non-200 returns 'error-{code}')
  - main() exit codes: 2 (missing token), 0 (full success), 3 (verify
    failed), AssertionError (Captain in bot list — H-γ tripwire)

The `requests` module is stubbed by conftest.py to a bare ModuleType so
the test environment doesn't need urllib3 et al. We replace
gh_freeze.requests with a minimal namespace holding put() + get() that
return fake Response objects with the status_code + .json() surface the
module actually touches.

Hyphen in 'gh-freeze.py' forbids plain import; importlib.util matches
the pattern used by the other cutover tests (test_service_accounts).
"""
from __future__ import annotations

import importlib.util
import os
import types
from pathlib import Path

import pytest


def _load_gh_freeze(monkeypatch):
    """Load gh-freeze.py fresh.

    load_officer_emails from etl-common is pulled in transitively via
    service_accounts import — we monkeypatch service_accounts.load_officer_emails
    BEFORE the gh-freeze module is loaded so enumerate_gh_demotion_targets
    sees a deterministic input when main() runs.
    """
    path = Path(__file__).parent.parent / "gh-freeze.py"
    spec = importlib.util.spec_from_file_location("gh_freeze_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class _FakeResponse:
    """Minimal requests.Response surrogate — status_code + .json() + .text +
    raise_for_status(). Enough for every branch in gh-freeze.py."""

    def __init__(self, status_code: int, json_body: dict | None = None, text: str = ""):
        self.status_code = status_code
        self._json = json_body or {}
        self.text = text

    def json(self):
        return self._json

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")


def _install_fake_requests(mod, put_resp: _FakeResponse | None = None,
                           get_resp: _FakeResponse | None = None):
    """Replace gh_freeze.requests with a tiny namespace that returns the
    canned responses. Each call records args for assertion."""
    calls = {"put": [], "get": []}

    def put(url, headers=None, json=None, timeout=None):
        calls["put"].append({"url": url, "headers": headers, "json": json})
        return put_resp if put_resp else _FakeResponse(204)

    def get(url, headers=None, timeout=None):
        calls["get"].append({"url": url, "headers": headers})
        return get_resp if get_resp else _FakeResponse(200, {"permission": "read"})

    ns = types.SimpleNamespace(put=put, get=get)
    mod.requests = ns
    return calls


@pytest.fixture
def gh_freeze(monkeypatch):
    mod = _load_gh_freeze(monkeypatch)
    return mod


# ── _demote_collaborator: HTTP status branches ───────────────────────────────

def test_demote_204_is_success_path(gh_freeze, caplog):
    """204 No Content = existing collaborator demoted. No exception, no warning."""
    _install_fake_requests(gh_freeze, put_resp=_FakeResponse(204))
    # Must not raise
    gh_freeze._demote_collaborator("sensed-cto", "fake-token")


def test_demote_201_logs_invitation_warning_no_raise(gh_freeze, caplog):
    """201 = invitation created (bot not a collab). M-2 fix: log loud
    warning, do NOT raise — post-demote verify will catch and abort."""
    caplog.set_level("WARNING", logger="gh-freeze")
    _install_fake_requests(gh_freeze, put_resp=_FakeResponse(201))
    gh_freeze._demote_collaborator("drifted-bot", "fake-token")
    # Warning names the specific class of drift
    warnings = [r for r in caplog.records if r.levelname == "WARNING"]
    assert any("201" in r.getMessage() or "invitation" in r.getMessage() for r in warnings)
    assert any("drifted-bot" in r.getMessage() for r in warnings)


def test_demote_404_skips_non_collaborator(gh_freeze, caplog):
    """404 = user not a collaborator. Log + continue (not an error)."""
    caplog.set_level("WARNING", logger="gh-freeze")
    _install_fake_requests(gh_freeze, put_resp=_FakeResponse(404))
    gh_freeze._demote_collaborator("ghost-user", "fake-token")
    warnings = [r for r in caplog.records if r.levelname == "WARNING"]
    assert any("not a collaborator" in r.getMessage() for r in warnings)


def test_demote_500_raises_for_status(gh_freeze):
    """Any non-204/201/404 must raise — don't silently accept partial failure."""
    _install_fake_requests(gh_freeze, put_resp=_FakeResponse(500, text="GH down"))
    with pytest.raises(RuntimeError, match="HTTP 500"):
        gh_freeze._demote_collaborator("sensed-cto", "fake-token")


def test_demote_uses_correct_url_and_payload(gh_freeze):
    """Wire invariant: PUT to /collaborators/{user} with {permission: read}."""
    calls = _install_fake_requests(gh_freeze)
    gh_freeze._demote_collaborator("sensed-cto", "tok-xyz")
    assert len(calls["put"]) == 1
    call = calls["put"][0]
    assert call["url"].endswith("/repos/nate-step/captains-cabinet/collaborators/sensed-cto")
    assert call["json"] == {"permission": "read"}
    assert call["headers"]["Authorization"] == "token tok-xyz"


# ── _verify_collaborator_permission: response shape ──────────────────────────

def test_verify_returns_permission_on_200(gh_freeze):
    _install_fake_requests(
        gh_freeze,
        get_resp=_FakeResponse(200, {"permission": "read"}),
    )
    assert gh_freeze._verify_collaborator_permission("sensed-cto", "tok") == "read"


def test_verify_returns_unknown_when_permission_missing(gh_freeze):
    """200 OK but no 'permission' key in body → default 'unknown'.
    Not a hypothetical: GitHub API shape changes have been known to
    drop fields in new API versions."""
    _install_fake_requests(
        gh_freeze,
        get_resp=_FakeResponse(200, {"user": {"login": "x"}}),  # no 'permission'
    )
    assert gh_freeze._verify_collaborator_permission("x", "tok") == "unknown"


def test_verify_returns_error_code_on_non_200(gh_freeze):
    """Non-200 → 'error-{code}' sentinel. main() treats anything !='read'
    as a verify failure, so this sentinel reliably triggers abort."""
    _install_fake_requests(gh_freeze, get_resp=_FakeResponse(403))
    assert gh_freeze._verify_collaborator_permission("x", "tok") == "error-403"


def test_verify_uses_correct_url(gh_freeze):
    """Wire invariant: /collaborators/{user}/permission (separate endpoint
    from the demote URL)."""
    calls = _install_fake_requests(gh_freeze)
    gh_freeze._verify_collaborator_permission("sensed-cto", "tok")
    assert calls["get"][0]["url"].endswith(
        "/repos/nate-step/captains-cabinet/collaborators/sensed-cto/permission"
    )


# ── main(): exit codes + orchestration ───────────────────────────────────────

def test_main_missing_token_exits_2(gh_freeze, monkeypatch):
    """Neither GITHUB_PAT_ADMIN nor GITHUB_PAT → exit 2. Prevents the
    script from silently doing nothing when the operator forgot to export
    credentials (adversary class: dry-run that looks like success)."""
    monkeypatch.delenv("GITHUB_PAT_ADMIN", raising=False)
    monkeypatch.delenv("GITHUB_PAT", raising=False)
    # No enumeration needed — short-circuits before
    assert gh_freeze.main() == 2


def test_main_full_success_returns_0(gh_freeze, monkeypatch):
    """Token present + 1 bot + demote 204 + verify=read → exit 0.
    This is the nominal runbook path."""
    monkeypatch.setenv("GITHUB_PAT_ADMIN", "tok-admin")
    monkeypatch.setattr(gh_freeze, "enumerate_gh_demotion_targets",
                        lambda: (["sensed-cto"], ["nate-step"]))
    monkeypatch.setattr(gh_freeze, "assert_captain_excluded", lambda *a, **k: None)

    _install_fake_requests(
        gh_freeze,
        put_resp=_FakeResponse(204),
        get_resp=_FakeResponse(200, {"permission": "read"}),
    )
    assert gh_freeze.main() == 0


def test_main_verify_failed_returns_3(gh_freeze, monkeypatch):
    """Post-demote verify returns non-'read' → exit 3 (abort the runbook).
    This is the fail-closed gate that catches 201-invitation drift or GH
    API anomalies from leaking through as 'success'."""
    monkeypatch.setenv("GITHUB_PAT_ADMIN", "tok-admin")
    monkeypatch.setattr(gh_freeze, "enumerate_gh_demotion_targets",
                        lambda: (["bot-not-demoted"], ["nate-step"]))
    monkeypatch.setattr(gh_freeze, "assert_captain_excluded", lambda *a, **k: None)

    _install_fake_requests(
        gh_freeze,
        put_resp=_FakeResponse(201),  # invitation, not a demotion
        get_resp=_FakeResponse(200, {"permission": "write"}),  # still write — not read
    )
    assert gh_freeze.main() == 3


def test_main_falls_back_to_github_pat_when_admin_missing(gh_freeze, monkeypatch):
    """GITHUB_PAT fallback — admin PAT is preferred but plain PAT works
    if that's what the operator has. Don't exit 2 when a usable token
    is available under the non-preferred name."""
    monkeypatch.delenv("GITHUB_PAT_ADMIN", raising=False)
    monkeypatch.setenv("GITHUB_PAT", "fallback-tok")
    monkeypatch.setattr(gh_freeze, "enumerate_gh_demotion_targets",
                        lambda: ([], []))  # no bots = trivially success
    monkeypatch.setattr(gh_freeze, "assert_captain_excluded", lambda *a, **k: None)
    _install_fake_requests(gh_freeze)
    assert gh_freeze.main() == 0


def test_main_calls_assert_captain_excluded(gh_freeze, monkeypatch):
    """H-γ tripwire integration: main() must invoke assert_captain_excluded
    with the enumerated bot list + captain list BEFORE any demote call.
    A regression that drops this call would allow Captain demotion to slip
    through when enumeration is ever buggy."""
    monkeypatch.setenv("GITHUB_PAT_ADMIN", "tok")
    called_with = {}

    def fake_assert(targets, captains, context):
        called_with["targets"] = list(targets)
        called_with["captains"] = list(captains)
        called_with["context"] = context

    monkeypatch.setattr(gh_freeze, "enumerate_gh_demotion_targets",
                        lambda: (["sensed-cto"], ["nate-step"]))
    monkeypatch.setattr(gh_freeze, "assert_captain_excluded", fake_assert)
    _install_fake_requests(gh_freeze)
    gh_freeze.main()

    assert called_with["targets"] == ["sensed-cto"]
    assert called_with["captains"] == ["nate-step"]
    assert called_with["context"] == "gh"


def test_main_captain_in_bots_raises_assertion(gh_freeze, monkeypatch):
    """End-to-end tripwire: if enumeration ever leaks captain into bots,
    the real assert_captain_excluded (not mocked) must raise AssertionError
    BEFORE any PATCH call fires."""
    monkeypatch.setenv("GITHUB_PAT_ADMIN", "tok")
    monkeypatch.setattr(gh_freeze, "enumerate_gh_demotion_targets",
                        lambda: (["nate-step"], ["nate-step"]))  # intentional leak

    calls = _install_fake_requests(gh_freeze)
    with pytest.raises(AssertionError, match="Captain identity"):
        gh_freeze.main()
    # Critical: no PATCH fired before the assertion aborted
    assert calls["put"] == []


def test_main_iterates_all_bots(gh_freeze, monkeypatch):
    """Multiple bots → one PATCH each, one verify each. Regression against
    a refactor that accidentally skips the second bot in a list."""
    monkeypatch.setenv("GITHUB_PAT_ADMIN", "tok")
    monkeypatch.setattr(gh_freeze, "enumerate_gh_demotion_targets",
                        lambda: (["bot-a", "bot-b", "bot-c"], ["nate-step"]))
    monkeypatch.setattr(gh_freeze, "assert_captain_excluded", lambda *a, **k: None)

    calls = _install_fake_requests(
        gh_freeze,
        put_resp=_FakeResponse(204),
        get_resp=_FakeResponse(200, {"permission": "read"}),
    )
    assert gh_freeze.main() == 0
    # One PATCH per bot
    assert len(calls["put"]) == 3
    # Verify per bot + one per captain (captain audit)
    assert len(calls["get"]) == 4


def test_main_captain_audit_logged_post_demote(gh_freeze, monkeypatch, caplog):
    """After all bot demotes + verifies pass, main() logs each Captain's
    permission for the audit trail. Captain should still be admin."""
    caplog.set_level("INFO", logger="gh-freeze")
    monkeypatch.setenv("GITHUB_PAT_ADMIN", "tok")
    monkeypatch.setattr(gh_freeze, "enumerate_gh_demotion_targets",
                        lambda: ([], ["nate-step"]))
    monkeypatch.setattr(gh_freeze, "assert_captain_excluded", lambda *a, **k: None)

    # get returns 'admin' for the captain audit query
    _install_fake_requests(
        gh_freeze,
        get_resp=_FakeResponse(200, {"permission": "admin"}),
    )
    assert gh_freeze.main() == 0
    audit_lines = [r.getMessage() for r in caplog.records if "Captain" in r.getMessage()]
    assert any("nate-step" in line and "admin" in line for line in audit_lines)
