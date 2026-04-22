"""FW-023 — ETL pure-transform tests.

Covers:
  * etl-linear `_map_state` — all 5 Linear fixtures (queue / wip+blocked /
    done / cancelled / captain-decision).
  * etl-github `_map_status` — AC #52 mapping grid: open / closed+completed /
    closed+not_planned (cancelled) / closed+None (default → done).
  * etl-github `_extract_fw_marker` — positive, trailing-content (H1 regression),
    absent, empty-body.
  * etl-github `_extract_priority` — positive, absent, case-insensitive.
  * Label parity — captain-decision label presence on both Linear + GH fixtures.
  * etl-common `resolve_assignee` — email + github_login lookup hits/misses, empty raw.
  * etl-common `extract_pr_url` — https GH PR URL regex, http-rejection, listing-page-rejection, first-match-on-multi.
  * etl-common `_infer_source` — linear via identifier, github via html_url/url, unknown fallback, identifier-wins.

Runs two ways:
    python3 -m pytest cabinet/scripts/lib/tests/       # FW-024 path
    python3 cabinet/scripts/lib/tests/test_etl_transforms.py   # works today
"""
from __future__ import annotations

import sys
import types
from pathlib import Path

for _mod in ("requests", "yaml"):
    if _mod not in sys.modules:
        sys.modules[_mod] = types.ModuleType(_mod)

_LIB_DIR = Path(__file__).parent.parent.resolve()
if str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))

import importlib.util as _ilu


def _load(modname: str, relpath: str):
    spec = _ilu.spec_from_file_location(modname, _LIB_DIR / relpath)
    mod = _ilu.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


etl_linear = _load("etl_linear", "etl-linear.py")
etl_github = _load("etl_github", "etl-github.py")
etl_common = _load("etl_common", "etl-common.py")

import test_etl_fixtures as fx  # no hyphens, importable directly


# ---------------------------------------------------------------------------
# Linear _map_state
# ---------------------------------------------------------------------------

def test_map_state_queue_backlog():
    status, blocked, reason = etl_linear._map_state(fx.LINEAR_ISSUE_QUEUE["state"])
    assert status == "queue"
    assert blocked is False
    assert reason is None


def test_map_state_wip_blocked():
    status, blocked, reason = etl_linear._map_state(fx.LINEAR_ISSUE_WIP_BLOCKED["state"])
    assert status == "wip"
    assert blocked is True
    assert reason == "Blocked"


def test_map_state_done():
    status, blocked, reason = etl_linear._map_state(fx.LINEAR_ISSUE_DONE["state"])
    assert status == "done"
    assert blocked is False
    assert reason is None


def test_map_state_cancelled():
    status, blocked, reason = etl_linear._map_state(fx.LINEAR_ISSUE_CANCELLED["state"])
    assert status == "cancelled"
    assert blocked is False
    assert reason is None


def test_map_state_captain_decision_in_progress():
    # CAPTAIN_DECISION fixture: state.name="In Progress", type="started"
    # → wip (via _STATE_TYPE_MAP["started"]), blocked=False.
    status, blocked, reason = etl_linear._map_state(
        fx.LINEAR_ISSUE_CAPTAIN_DECISION["state"]
    )
    assert status == "wip"
    assert blocked is False
    assert reason is None


def test_map_state_started_non_in_progress_routes_to_queue():
    # Regression: Spec 038 §4.5 — type=started with name != "In Progress"
    # and not blocked → queue (intermediate workflow bucket like "Review").
    state = {"name": "In Review", "type": "started"}
    status, blocked, reason = etl_linear._map_state(state)
    assert status == "queue"
    assert blocked is False
    assert reason is None


def test_map_state_on_hold_wip_blocked():
    # "On Hold" is the other _BLOCKED_NAMES entry alongside "Blocked".
    state = {"name": "On Hold", "type": "started"}
    status, blocked, reason = etl_linear._map_state(state)
    assert status == "wip"
    assert blocked is True
    assert reason == "On Hold"


# ---------------------------------------------------------------------------
# GH _map_status — AC #52 grid
# ---------------------------------------------------------------------------

def test_map_status_open():
    assert etl_github._map_status("open", None) == ("queue", None)


def test_map_status_closed_completed():
    assert etl_github._map_status("closed", "completed") == ("done", "closed_at")


def test_map_status_closed_not_planned():
    # AC #52: not_planned → cancelled with cancelled_at sourced from closed_at.
    assert etl_github._map_status("closed", "not_planned") == ("cancelled", "closed_at")


def test_map_status_closed_none_defaults_to_done():
    assert etl_github._map_status("closed", None) == ("done", "closed_at")


# ---------------------------------------------------------------------------
# GH _extract_fw_marker — H1 regression + happy-paths
# ---------------------------------------------------------------------------

def test_extract_fw_marker_positive():
    assert etl_github._extract_fw_marker(fx.GH_ISSUE_FW_MARKED["body"]) == "FW-024"


def test_extract_fw_marker_trailing_content():
    # Adversarial H1: pre-fix regex was full-line anchored and dropped
    # 'FW-039: title'; post-fix uses `\b` so trailing content is fine.
    assert etl_github._extract_fw_marker("FW-039: ship it\n\ndetails") == "FW-039"


def test_extract_fw_marker_absent_body():
    assert etl_github._extract_fw_marker(fx.GH_ISSUE_NO_FW_MARKER["body"]) is None


def test_extract_fw_marker_empty_and_none():
    assert etl_github._extract_fw_marker(None) is None
    assert etl_github._extract_fw_marker("") is None


def test_extract_fw_marker_mid_line_rejected():
    # Regex is `(?m)^(FW-\d+)\b` — markers MUST start at line beginning.
    # Guards against someone loosening the `^` anchor thinking it's a bug.
    assert etl_github._extract_fw_marker("See FW-024 for details") is None
    assert etl_github._extract_fw_marker("preamble\n  FW-024 indented") is None


def test_extract_fw_marker_closed_not_planned_fixture():
    # The new AC-#52 fixture carries a valid FW-013 marker.
    assert etl_github._extract_fw_marker(fx.GH_ISSUE_CLOSED_NOT_PLANNED["body"]) == "FW-013"


# ---------------------------------------------------------------------------
# GH _extract_priority
# ---------------------------------------------------------------------------

def test_extract_priority_positive():
    assert etl_github._extract_priority(["priority-p0"]) == "P0"
    assert etl_github._extract_priority(["other", "priority-p2"]) == "P2"


def test_extract_priority_absent():
    assert etl_github._extract_priority(["bug", "framework"]) is None


def test_extract_priority_case_insensitive():
    assert etl_github._extract_priority(["Priority-P1"]) == "P1"


def test_extract_priority_empty_list():
    # No labels at all — not "priority absent among many", but zero input.
    assert etl_github._extract_priority([]) is None


def test_extract_priority_first_match_wins():
    # Multiple priority labels shouldn't happen, but regex is `.match()` per
    # label in list-order. Contract: first match wins; later entries ignored.
    assert etl_github._extract_priority(["priority-p2", "priority-p0"]) == "P2"


def test_extract_priority_out_of_range_rejected():
    # Regex pins digit range to [0-3]. Anything else → no match → None.
    assert etl_github._extract_priority(["priority-p4"]) is None
    assert etl_github._extract_priority(["priority-p9"]) is None


def test_extract_priority_malformed_label_no_digit():
    # Regex requires trailing digit; bare `priority-p` shouldn't match.
    assert etl_github._extract_priority(["priority-p"]) is None


# ---------------------------------------------------------------------------
# Captain-decision label parity (fixture-gap b, both sources)
# ---------------------------------------------------------------------------

def test_linear_captain_decision_label_on_fixture():
    names = [n["name"] for n in fx.LINEAR_ISSUE_CAPTAIN_DECISION["labels"]["nodes"]]
    assert "captain-decision" in names


def test_gh_captain_decision_label_on_fixture():
    names = [l["name"] for l in fx.GH_ISSUE_CAPTAIN_DECISION["labels"]]
    assert "captain-decision" in names


def test_linear_queue_fixture_no_captain_decision():
    names = [n["name"] for n in fx.LINEAR_ISSUE_QUEUE["labels"]["nodes"]]
    assert "captain-decision" not in names


def test_gh_fw_marked_fixture_no_captain_decision():
    names = [l["name"] for l in fx.GH_ISSUE_FW_MARKED["labels"]]
    assert "captain-decision" not in names


# ---------------------------------------------------------------------------
# etl-common `resolve_assignee` — email / github_login lookup + miss semantics
# ---------------------------------------------------------------------------

# Synthetic mapping matching load_officer_emails() return shape.
_MAPPING = {
    "emails": {
        "captain@example.com": "captain",
        "cto@example.com": "cto",
    },
    "github_logins": {
        "nate-step": "captain",
        "cto-bot": "cto",
    },
}


def test_resolve_assignee_none_raw():
    # Empty input short-circuits to (None, None) — no lookup, no unresolved.
    assert etl_common.resolve_assignee(None, "email", _MAPPING) == (None, None)


def test_resolve_assignee_empty_string_raw():
    # Falsy check on raw — "" is also (None, None), not ("", None).
    assert etl_common.resolve_assignee("", "email", _MAPPING) == (None, None)


def test_resolve_assignee_email_hit():
    assert etl_common.resolve_assignee("captain@example.com", "email", _MAPPING) == ("captain", None)


def test_resolve_assignee_email_miss():
    # Miss: returns (None, raw) — caller logs the unresolved raw value.
    assert etl_common.resolve_assignee("stranger@example.com", "email", _MAPPING) == (None, "stranger@example.com")


def test_resolve_assignee_github_login_hit():
    # kind='github_login' switches the lookup table.
    assert etl_common.resolve_assignee("nate-step", "github_login", _MAPPING) == ("captain", None)


def test_resolve_assignee_github_login_miss():
    assert etl_common.resolve_assignee("unknown-user", "github_login", _MAPPING) == (None, "unknown-user")


# ---------------------------------------------------------------------------
# etl-common `extract_pr_url` — GH PR URL regex
# Pattern: https://github\.com/[\w.-]+/[\w.-]+/pull/\d+
# ---------------------------------------------------------------------------

def test_extract_pr_url_none():
    assert etl_common.extract_pr_url(None) is None


def test_extract_pr_url_empty_string():
    assert etl_common.extract_pr_url("") is None


def test_extract_pr_url_plain_text_no_url():
    assert etl_common.extract_pr_url("ordinary commit message, no URL") is None


def test_extract_pr_url_happy_path():
    text = "See PR https://github.com/nate-step/captains-cabinet/pull/42 for details"
    assert etl_common.extract_pr_url(text) == "https://github.com/nate-step/captains-cabinet/pull/42"


def test_extract_pr_url_http_rejected():
    # Regex requires https — http is not an alternative (prevents downgrade-style false matches).
    assert etl_common.extract_pr_url("http://github.com/foo/bar/pull/1") is None


def test_extract_pr_url_pulls_listing_page_rejected():
    # /pulls (listing) is not /pull/\d+ (specific PR). Regex requires the latter.
    assert etl_common.extract_pr_url("https://github.com/foo/bar/pulls") is None


def test_extract_pr_url_first_match_wins_on_multi():
    text = "first https://github.com/a/b/pull/1 then https://github.com/c/d/pull/99"
    assert etl_common.extract_pr_url(text) == "https://github.com/a/b/pull/1"


# ---------------------------------------------------------------------------
# etl-common `_infer_source` — source classification fallback
# ---------------------------------------------------------------------------

def test_infer_source_linear_via_identifier():
    assert etl_common._infer_source({"identifier": "SEN-42"}) == "linear"


def test_infer_source_github_via_html_url():
    assert etl_common._infer_source({"html_url": "https://github.com/foo/bar/issues/1"}) == "github-issues"


def test_infer_source_github_via_url_field_fallback():
    # When html_url absent but `url` (GH API field) contains github.com.
    assert etl_common._infer_source({"url": "https://api.github.com/repos/foo/bar/issues/1"}) == "github-issues"


def test_infer_source_unknown_empty_record():
    assert etl_common._infer_source({}) == "unknown"


def test_infer_source_unknown_non_github_url():
    # Non-github URL does not route to github-issues.
    assert etl_common._infer_source({"html_url": "https://example.com/issue/1"}) == "unknown"


def test_infer_source_identifier_wins_over_url():
    # Even when both fields present, `identifier` check runs first.
    record = {"identifier": "SEN-1", "html_url": "https://github.com/foo/bar/pull/1"}
    assert etl_common._infer_source(record) == "linear"


# ---------------------------------------------------------------------------
# `_parse_dt` parity — identical impl duplicated across etl-linear +
# etl-github. Tests run against both modules per case so future drift (one
# side Z-normalizes differently, one side catches a different exception
# class, one side grows timezone coercion) surfaces loudly instead of as
# a silent desync in timestamps written to officer_tasks.
# ---------------------------------------------------------------------------

from datetime import datetime, timedelta, timezone

_PARSE_DT_MODULES = (etl_linear, etl_github)


def test_parse_dt_none_both_modules():
    for mod in _PARSE_DT_MODULES:
        assert mod._parse_dt(None) is None


def test_parse_dt_empty_string_both_modules():
    # `if not val` short-circuits — empty string and None identical.
    for mod in _PARSE_DT_MODULES:
        assert mod._parse_dt("") is None


def test_parse_dt_z_suffix_normalizes_to_utc():
    # Linear timestamps end in `Z`; implementation replaces Z→+00:00 before
    # fromisoformat (pre-Python-3.11 compat). Both sides must agree.
    for mod in _PARSE_DT_MODULES:
        dt = mod._parse_dt("2026-04-22T10:30:00Z")
        assert dt == datetime(2026, 4, 22, 10, 30, 0, tzinfo=timezone.utc)
        assert dt.utcoffset() == timedelta(0)


def test_parse_dt_plus_zero_offset_both_modules():
    # Explicit +00:00 form should parse identically to Z-suffix form.
    for mod in _PARSE_DT_MODULES:
        dt = mod._parse_dt("2026-04-22T10:30:00+00:00")
        assert dt == datetime(2026, 4, 22, 10, 30, 0, tzinfo=timezone.utc)


def test_parse_dt_negative_offset_preserves_tz():
    # Non-UTC offsets must round-trip — comparing officer_tasks rows across
    # timezones depends on tzinfo being preserved, not coerced to naive UTC.
    for mod in _PARSE_DT_MODULES:
        dt = mod._parse_dt("2026-04-22T10:30:00-05:00")
        assert dt is not None
        assert dt.utcoffset() == timedelta(hours=-5)


def test_parse_dt_invalid_returns_none_both_modules():
    # ValueError path: fromisoformat rejects garbage; try/except swallows.
    # Contract: return None, never raise. Upstream callers lean on this.
    for mod in _PARSE_DT_MODULES:
        assert mod._parse_dt("not-a-date") is None
        assert mod._parse_dt("2026/04/22") is None


# ---------------------------------------------------------------------------
# Standalone runner (no pytest required)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import traceback

    tests = [
        (name, fn)
        for name, fn in globals().items()
        if name.startswith("test_") and callable(fn)
    ]
    passed = 0
    failed = 0
    for name, fn in tests:
        try:
            fn()
            passed += 1
            print(f"  ok   {name}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL {name}: {e!r}")
            traceback.print_exc()
        except Exception as e:
            failed += 1
            print(f"  ERR  {name}: {e!r}")
            traceback.print_exc()
    print(f"\n{passed} passed, {failed} failed (total {len(tests)})")
    sys.exit(1 if failed else 0)
