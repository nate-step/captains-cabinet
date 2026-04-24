"""Tests for run-etl.py's `_assert_reconcile` arithmetic invariant.

Spec 039 §5.5 step 5 requires every extracted Linear/GH row to be accounted
for as inserted/updated/skipped. Without this assertion, ETL silently
drifts counts — the exact failure mode the invariant was introduced to
prevent. The assertion runs inside a bash `set -e` wrapper, so any raise
aborts the migration run with non-zero exit.

Small, safety-critical surface → high test-density is warranted.

conftest.py already stubs yaml + puts cabinet/scripts/lib on sys.path,
so run-etl.py's importlib dance for etl-common resolves cleanly without
psycopg2 (only get_db_connection imports it, and that's never called here).
"""
from __future__ import annotations

import importlib.util as _ilu
from pathlib import Path

import pytest

_LIB_DIR = Path(__file__).parent.parent.resolve()


def _load_run_etl():
    """Load run-etl.py via importlib (hyphen prevents plain import)."""
    spec = _ilu.spec_from_file_location("run_etl_under_test", _LIB_DIR / "run-etl.py")
    mod = _ilu.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def run_etl():
    return _load_run_etl()


# ── Happy path ────────────────────────────────────────────────────────────────

def test_reconcile_linear_balanced(run_etl):
    """Linear track: issues + projects extracted == inserted + updated + skipped."""
    # Must not raise
    run_etl._assert_reconcile("linear", {
        "issues_extracted": 100,
        "projects_extracted": 10,
        "inserted": 80,
        "updated": 20,
        "skipped": 10,
    })


def test_reconcile_github_balanced_no_projects(run_etl):
    """GitHub track has no projects_extracted key — .get() defaults to 0."""
    run_etl._assert_reconcile("github", {
        "issues_extracted": 50,
        "inserted": 30,
        "updated": 15,
        "skipped": 5,
    })


def test_reconcile_all_zero(run_etl):
    """Empty run (no rows extracted) → 0 == 0, no raise."""
    run_etl._assert_reconcile("linear", {
        "issues_extracted": 0,
        "projects_extracted": 0,
        "inserted": 0,
        "updated": 0,
        "skipped": 0,
    })


# ── Mismatch (the whole point of the assertion) ──────────────────────────────

def test_reconcile_under_handled_raises(run_etl):
    """extracted > handled (a row was dropped) → abort."""
    with pytest.raises(AssertionError) as exc:
        run_etl._assert_reconcile("linear", {
            "issues_extracted": 100,
            "projects_extracted": 5,
            "inserted": 50,
            "updated": 20,
            "skipped": 10,  # sum = 80, but extracted = 105
        })
    msg = str(exc.value)
    assert "linear ETL reconcile FAILED" in msg
    assert "extracted=105" in msg
    assert "inserted=50" in msg
    assert "updated=20" in msg
    assert "skipped=10" in msg
    assert "sum=80" in msg


def test_reconcile_over_handled_raises(run_etl):
    """extracted < handled (double-counted row) → abort."""
    with pytest.raises(AssertionError) as exc:
        run_etl._assert_reconcile("github", {
            "issues_extracted": 50,
            "inserted": 30,
            "updated": 20,
            "skipped": 10,  # sum = 60, extracted = 50
        })
    msg = str(exc.value)
    assert "github ETL reconcile FAILED" in msg
    assert "extracted=50" in msg
    assert "sum=60" in msg


# ── Error-message format invariants ───────────────────────────────────────────

def test_reconcile_message_includes_spec_reference(run_etl):
    """Message names spec §5.5 step 5 so operators can find the invariant."""
    with pytest.raises(AssertionError) as exc:
        run_etl._assert_reconcile("linear", {
            "issues_extracted": 1,
            "projects_extracted": 0,
            "inserted": 0,
            "updated": 0,
            "skipped": 0,
        })
    assert "spec §5.5 step 5" in str(exc.value)


def test_reconcile_message_names_track(run_etl):
    """Track name prefixes the error so linear vs github mismatch is clear."""
    with pytest.raises(AssertionError) as exc:
        run_etl._assert_reconcile("github", {
            "issues_extracted": 1,
            "inserted": 0,
            "updated": 0,
            "skipped": 0,
        })
    # Message starts with the track name
    assert str(exc.value).startswith("github ETL reconcile FAILED")


# ── Projects-extracted absent vs present ──────────────────────────────────────

def test_reconcile_missing_projects_defaults_to_zero(run_etl):
    """.get('projects_extracted', 0) — github track omits the key."""
    # github: just issues_extracted=5, inserted+updated+skipped=5
    run_etl._assert_reconcile("github", {
        "issues_extracted": 5,
        "inserted": 5,
        "updated": 0,
        "skipped": 0,
    })


def test_reconcile_projects_extracted_counted(run_etl):
    """Linear projects are added to issues for the extracted total.
    Leaving projects out of the math would silently drop project rows
    from reconciliation — a subtle regression the test pins against."""
    # 10 issues + 3 projects = 13 extracted; 13 handled → OK
    run_etl._assert_reconcile("linear", {
        "issues_extracted": 10,
        "projects_extracted": 3,
        "inserted": 13,
        "updated": 0,
        "skipped": 0,
    })
    # But 13 extracted with only 10 handled → raise
    with pytest.raises(AssertionError):
        run_etl._assert_reconcile("linear", {
            "issues_extracted": 10,
            "projects_extracted": 3,
            "inserted": 10,
            "updated": 0,
            "skipped": 0,
        })
