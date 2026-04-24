"""Tests for cutover/lib/service_accounts.py (Spec 039 §5.9 Gate 4 Step 2/3).

The module is safety-critical: enumerate_linear_demotion_targets() +
enumerate_gh_demotion_targets() produce the lists the cutover runbook
feeds into Linear/GitHub member-permission downgrades. A regression that
silently folds Captain identifiers into the demotion list would revoke
Captain admin access during cutover — exactly the class COO adversary
finding H-γ asked the module to defend against.

assert_captain_excluded is the explicit tripwire. We pin its message
format, its per-identity iteration, and its no-op-on-empty-captain path.

load_officer_emails is stubbed per-test via monkeypatch so tests don't
depend on the live instance/config/officer-emails.yml at collection time.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest


def _load_module():
    """Import cutover/lib/service_accounts.py by path.

    Conftest has already pushed cabinet/scripts/cutover on sys.path so the
    module's internal `_etl = importlib.util.spec_from_file_location(...)`
    resolves etl-common.py relative to its own __file__. We mirror that
    pattern here to load service_accounts itself (hyphen-free `lib` dir
    makes this cleaner than the ETL modules).
    """
    path = Path(__file__).parent.parent / "lib" / "service_accounts.py"
    spec = importlib.util.spec_from_file_location("service_accounts_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def service_accounts(monkeypatch):
    """Load service_accounts.py fresh per test, with load_officer_emails
    monkeypatchable via `module.load_officer_emails = fake_fn`.

    The module aliases `load_officer_emails = _etl.load_officer_emails`
    at import time (line 20). Tests replace that module-level reference
    directly — cleaner than patching etl-common's original function,
    since service_accounts holds its own bound reference.
    """
    return _load_module()


# ── enumerate_linear_demotion_targets ─────────────────────────────────────────

def test_linear_partitions_captain_from_service_accounts(service_accounts):
    """Baseline: officers go to service list, captain goes to captain list."""
    service_accounts.load_officer_emails = lambda: {
        "emails": {
            "cto@sensed.internal": "cto",
            "cpo@sensed.internal": "cpo",
            "nate@sensed.io": "captain",
        },
        "github_logins": {},
    }
    service, captain = service_accounts.enumerate_linear_demotion_targets()
    assert service == ["cpo@sensed.internal", "cto@sensed.internal"]
    assert captain == ["nate@sensed.io"]


def test_linear_multiple_captain_emails_all_captured(service_accounts):
    """Captain has two emails (personal + work per current officer-emails.yml).
    Both MUST land in the captain list — leaking either to demotion = outage."""
    service_accounts.load_officer_emails = lambda: {
        "emails": {
            "cto@sensed.internal": "cto",
            "nate@sensed.io": "captain",
            "stephie.stepnetwork@gmail.com": "captain",
        },
        "github_logins": {},
    }
    service, captain = service_accounts.enumerate_linear_demotion_targets()
    assert service == ["cto@sensed.internal"]
    assert captain == ["nate@sensed.io", "stephie.stepnetwork@gmail.com"]


def test_linear_output_is_sorted(service_accounts):
    """Sorted output is an invariant — downstream diff review + idempotency
    depend on stable ordering."""
    service_accounts.load_officer_emails = lambda: {
        "emails": {
            "zzz@sensed.internal": "cto",
            "aaa@sensed.internal": "cpo",
            "mmm@sensed.internal": "coo",
        },
        "github_logins": {},
    }
    service, _ = service_accounts.enumerate_linear_demotion_targets()
    assert service == [
        "aaa@sensed.internal",
        "mmm@sensed.internal",
        "zzz@sensed.internal",
    ]


def test_linear_only_captain_yields_empty_demotion(service_accounts):
    """If the mapping has only captain entries, demotion list is empty —
    this is the 'nothing to do' shape, not an error."""
    service_accounts.load_officer_emails = lambda: {
        "emails": {"nate@sensed.io": "captain"},
        "github_logins": {},
    }
    service, captain = service_accounts.enumerate_linear_demotion_targets()
    assert service == []
    assert captain == ["nate@sensed.io"]


def test_linear_empty_mapping(service_accounts):
    """Empty yaml sections → empty lists, no exception."""
    service_accounts.load_officer_emails = lambda: {
        "emails": {},
        "github_logins": {},
    }
    service, captain = service_accounts.enumerate_linear_demotion_targets()
    assert service == []
    assert captain == []


# ── enumerate_gh_demotion_targets ─────────────────────────────────────────────

def test_gh_partitions_captain_from_bot_logins(service_accounts):
    service_accounts.load_officer_emails = lambda: {
        "emails": {},
        "github_logins": {
            "sensed-cto": "cto",
            "sensed-cpo": "cpo",
            "nate-step": "captain",
        },
    }
    bots, captains = service_accounts.enumerate_gh_demotion_targets()
    assert bots == ["sensed-cpo", "sensed-cto"]
    assert captains == ["nate-step"]


def test_gh_output_is_sorted(service_accounts):
    service_accounts.load_officer_emails = lambda: {
        "emails": {},
        "github_logins": {
            "zzz-bot": "cto",
            "aaa-bot": "cpo",
        },
    }
    bots, _ = service_accounts.enumerate_gh_demotion_targets()
    assert bots == ["aaa-bot", "zzz-bot"]


def test_gh_empty_logins(service_accounts):
    service_accounts.load_officer_emails = lambda: {
        "emails": {},
        "github_logins": {},
    }
    bots, captains = service_accounts.enumerate_gh_demotion_targets()
    assert bots == []
    assert captains == []


# ── assert_captain_excluded ──────────────────────────────────────────────────

def test_assert_captain_excluded_passes_when_clean(service_accounts):
    """No captain identifier in the demotion targets → no-op (no raise)."""
    # Must not raise
    service_accounts.assert_captain_excluded(
        demotion_targets=["cto@sensed.internal", "cpo@sensed.internal"],
        captain_identities=["nate@sensed.io"],
        context="linear",
    )


def test_assert_captain_excluded_raises_on_overlap(service_accounts):
    """Captain in the demotion list MUST abort — this is the tripwire."""
    with pytest.raises(AssertionError) as exc:
        service_accounts.assert_captain_excluded(
            demotion_targets=["cto@sensed.internal", "nate@sensed.io"],
            captain_identities=["nate@sensed.io"],
            context="linear",
        )
    msg = str(exc.value)
    assert "Captain identity" in msg
    assert "'nate@sensed.io'" in msg
    assert "linear" in msg


def test_assert_captain_excluded_checks_every_identity(service_accounts):
    """Captain has multiple identities; ANY of them appearing in targets
    must trigger the abort — not just the first."""
    with pytest.raises(AssertionError) as exc:
        service_accounts.assert_captain_excluded(
            demotion_targets=["cto@sensed.internal", "stephie.stepnetwork@gmail.com"],
            captain_identities=["nate@sensed.io", "stephie.stepnetwork@gmail.com"],
            context="linear",
        )
    # Error message names the identity that actually overlapped
    assert "'stephie.stepnetwork@gmail.com'" in str(exc.value)


def test_assert_captain_excluded_context_in_message(service_accounts):
    """Context string appears in the error — lets the runbook tell Linear
    vs GH abort apart when the dump lands in console/alert."""
    with pytest.raises(AssertionError) as exc:
        service_accounts.assert_captain_excluded(
            demotion_targets=["nate-step"],
            captain_identities=["nate-step"],
            context="gh",
        )
    assert "gh" in str(exc.value)


def test_assert_captain_excluded_empty_captain_is_noop(service_accounts):
    """Empty captain_identities → nothing to check → no raise (explicit test
    to prevent a future 'no captain defined = assume overlap' regression)."""
    service_accounts.assert_captain_excluded(
        demotion_targets=["cto@sensed.internal"],
        captain_identities=[],
        context="linear",
    )


def test_assert_captain_excluded_empty_targets_is_noop(service_accounts):
    """Nothing to demote → trivially safe."""
    service_accounts.assert_captain_excluded(
        demotion_targets=[],
        captain_identities=["nate@sensed.io"],
        context="linear",
    )


# ── Invariant: enumerate_* outputs always disjoint ────────────────────────────

def test_linear_enumerate_outputs_are_disjoint(service_accounts):
    """Construction-level invariant: the two lists from enumerate_linear
    can never overlap by definition (the partition predicate is a single
    equality check). Pin it anyway — a future refactor that loosens the
    predicate would silently violate H-γ."""
    service_accounts.load_officer_emails = lambda: {
        "emails": {
            "cto@sensed.internal": "cto",
            "nate@sensed.io": "captain",
            "stephie.stepnetwork@gmail.com": "captain",
        },
        "github_logins": {},
    }
    service, captain = service_accounts.enumerate_linear_demotion_targets()
    assert set(service).isdisjoint(set(captain))


def test_gh_enumerate_outputs_are_disjoint(service_accounts):
    service_accounts.load_officer_emails = lambda: {
        "emails": {},
        "github_logins": {
            "sensed-cto": "cto",
            "nate-step": "captain",
        },
    }
    bots, captains = service_accounts.enumerate_gh_demotion_targets()
    assert set(bots).isdisjoint(set(captains))


# ── Integration: enumerate result feeds assert_captain_excluded cleanly ──────

def test_enumerate_then_assert_passes_on_partitioned_output(service_accounts):
    """The intended usage — enumerate the split, then run assert as a
    belt-and-suspenders check — must always pass on unmodified output."""
    service_accounts.load_officer_emails = lambda: {
        "emails": {
            "cto@sensed.internal": "cto",
            "nate@sensed.io": "captain",
        },
        "github_logins": {
            "sensed-cto": "cto",
            "nate-step": "captain",
        },
    }
    lin_svc, lin_cap = service_accounts.enumerate_linear_demotion_targets()
    gh_bots, gh_cap = service_accounts.enumerate_gh_demotion_targets()
    # Neither must raise
    service_accounts.assert_captain_excluded(lin_svc, lin_cap, "linear")
    service_accounts.assert_captain_excluded(gh_bots, gh_cap, "gh")
