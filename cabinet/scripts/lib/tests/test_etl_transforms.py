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
# Linear `_transform_project` — epic-row synthesis invariants.
# Epics violate the epic_no_parent DB CHECK if parent_epic_ref ever gets set
# via this path; American/British spelling for `canceled/cancelled` is
# documented defensive coercion; completed_at / cancelled_at are contract-
# gated to the terminal statuses. Tests pin each invariant.
# ---------------------------------------------------------------------------

def test_transform_project_started_wip():
    # Fixture: state="started" → status="wip". completed_at / cancelled_at
    # stay None because the status branches don't trigger.
    row = etl_linear._transform_project(fx.LINEAR_PROJECT_SYNTHESIZED_EPIC)
    assert row["status"] == "wip"
    assert row["completed_at"] is None
    assert row["cancelled_at"] is None


def test_transform_project_completed_sets_completed_at():
    proj = dict(fx.LINEAR_PROJECT_SYNTHESIZED_EPIC)
    proj["state"] = "completed"
    proj["completedAt"] = "2026-04-20T12:00:00Z"
    row = etl_linear._transform_project(proj)
    assert row["status"] == "done"
    assert row["completed_at"] == datetime(2026, 4, 20, 12, 0, 0, tzinfo=timezone.utc)
    assert row["cancelled_at"] is None


def test_transform_project_canceled_one_l_american_spelling():
    # Linear uses American spelling — single-l `canceled`. Our map must
    # coerce to the British `cancelled` status value (docstring invariant).
    proj = dict(fx.LINEAR_PROJECT_SYNTHESIZED_EPIC)
    proj["state"] = "canceled"
    proj["updatedAt"] = "2026-04-19T08:00:00Z"
    row = etl_linear._transform_project(proj)
    assert row["status"] == "cancelled"
    # cancelled_at derives from updatedAt as the best proxy (no explicit
    # Linear field; re-verify on contract change).
    assert row["cancelled_at"] == datetime(2026, 4, 19, 8, 0, 0, tzinfo=timezone.utc)


def test_transform_project_cancelled_two_ls_defensive():
    # British spelling also coerces — defensive in case Linear ever emits
    # both forms mid-migration or someone constructs a test dict directly.
    proj = dict(fx.LINEAR_PROJECT_SYNTHESIZED_EPIC)
    proj["state"] = "cancelled"
    row = etl_linear._transform_project(proj)
    assert row["status"] == "cancelled"


def test_transform_project_archived_maps_to_cancelled():
    # Linear "archived" is a 3rd terminal form — treat as cancelled for
    # officer_tasks (docstring invariant).
    proj = dict(fx.LINEAR_PROJECT_SYNTHESIZED_EPIC)
    proj["state"] = "archived"
    row = etl_linear._transform_project(proj)
    assert row["status"] == "cancelled"


def test_transform_project_epic_invariants():
    # epic_no_parent CHECK at DB layer would reject any row with a parent
    # set — application-layer invariant here is parent_epic_ref is ALWAYS
    # None, type is ALWAYS "epic", external_ref format is stable.
    row = etl_linear._transform_project(fx.LINEAR_PROJECT_SYNTHESIZED_EPIC)
    assert row["type"] == "epic"
    assert row["parent_epic_ref"] is None
    assert row["external_ref"] == f"linear-project:{fx.LINEAR_PROJECT_SYNTHESIZED_EPIC['id']}"
    assert row["external_source"] == "linear"


def test_transform_project_missing_state_defaults_wip():
    # `state` absent or unknown → wip. Keeps new-shape resilience.
    row = etl_linear._transform_project({"id": "p-new", "name": "Fresh Project"})
    assert row["status"] == "wip"
    assert row["completed_at"] is None
    assert row["cancelled_at"] is None


# ---------------------------------------------------------------------------
# Linear `_transform_issue` — branch coverage on the subtle contracts.
# Captain-assignee auto-flagging, due-date gating on founder_action,
# priority mapping, PR URL extraction, duplicate skip semantics.
# ---------------------------------------------------------------------------

_ISSUE_MAPPING = {
    "emails": {
        "cto@cabinet.local": "cto",
        "cpo@cabinet.local": "cpo",
        "captain@cabinet.local": "captain",
    },
    "github_logins": {},
}


def test_transform_issue_duplicate_state_type_skipped():
    issue = dict(fx.LINEAR_ISSUE_QUEUE)
    issue["state"] = {"id": "sdup", "name": "Done", "type": "duplicate"}
    skip, unresolved = [], []
    result = etl_linear._transform_issue(issue, _ISSUE_MAPPING, {}, skip, unresolved)
    assert result is None
    assert len(skip) == 1
    assert skip[0]["reason"] == "duplicate_state"
    assert skip[0]["external_ref"] == "SEN-247"


def test_transform_issue_duplicate_state_name_skipped():
    # Defensive branch: Linear sometimes emits type='started' with name='Duplicate'
    # when an issue is mid-resolution. Both the type-check AND the name-check
    # must route to skip.
    issue = dict(fx.LINEAR_ISSUE_QUEUE)
    issue["state"] = {"id": "sdup", "name": "Duplicate", "type": "started"}
    skip, unresolved = [], []
    result = etl_linear._transform_issue(issue, _ISSUE_MAPPING, {}, skip, unresolved)
    assert result is None
    assert len(skip) == 1


def test_transform_issue_captain_assignee_forces_founder_action():
    # Contract: any issue assigned to Captain auto-flags founder_action=True
    # even if the label is absent. This is how CPO-assigned captain decisions
    # get onto the morning briefing "overdue" list.
    issue = dict(fx.LINEAR_ISSUE_QUEUE)
    issue["assignee"] = {"email": "captain@cabinet.local"}
    # Explicitly no founder-action label in the fixture labels.
    skip, unresolved = [], []
    row = etl_linear._transform_issue(issue, _ISSUE_MAPPING, {}, skip, unresolved)
    assert row["officer_slug"] == "captain"
    assert row["founder_action"] is True


def test_transform_issue_captain_decision_label_sets_flag():
    skip, unresolved = [], []
    row = etl_linear._transform_issue(
        fx.LINEAR_ISSUE_CAPTAIN_DECISION, _ISSUE_MAPPING, {}, skip, unresolved
    )
    assert row["captain_decision"] is True


def test_transform_issue_unresolved_assignee_appends():
    issue = dict(fx.LINEAR_ISSUE_QUEUE)
    issue["assignee"] = {"email": "stranger@external.com"}
    skip, unresolved = [], []
    row = etl_linear._transform_issue(issue, _ISSUE_MAPPING, {}, skip, unresolved)
    assert row["officer_slug"] is None
    assert len(unresolved) == 1
    assert unresolved[0]["raw_identifier"] == "stranger@external.com"
    assert unresolved[0]["source"] == "linear"


def test_transform_issue_priority_mapping():
    # Linear 1→P0, 2→P1, 3→P2, 4→P3. Priority 0 is "unset" and must map
    # to None (not "P-1" or similar).
    for linear_prio, expected in [(1, "P0"), (2, "P1"), (3, "P2"), (4, "P3"), (0, None)]:
        issue = dict(fx.LINEAR_ISSUE_QUEUE)
        issue["priority"] = linear_prio
        skip, unresolved = [], []
        row = etl_linear._transform_issue(issue, _ISSUE_MAPPING, {}, skip, unresolved)
        assert row["priority"] == expected, f"priority={linear_prio} expected={expected} got={row['priority']}"


def test_transform_issue_due_date_only_for_founder_action():
    # Contract: dueDate is populated on many Linear issues but officer_tasks
    # only tracks due dates for founder_action rows (Captain accountability).
    # A regular issue with a dueDate MUST drop the date.
    from datetime import date as date_cls
    issue = dict(fx.LINEAR_ISSUE_QUEUE)
    issue["dueDate"] = "2026-04-30"
    # QUEUE fixture has no founder-action label → due_date dropped.
    skip, unresolved = [], []
    row = etl_linear._transform_issue(issue, _ISSUE_MAPPING, {}, skip, unresolved)
    assert row["founder_action"] is False
    assert row["due_date"] is None

    # Flip to founder-action label → due_date parsed.
    issue_fa = dict(issue)
    issue_fa["labels"] = {"nodes": [{"name": "founder-action"}]}
    row_fa = etl_linear._transform_issue(issue_fa, _ISSUE_MAPPING, {}, [], [])
    assert row_fa["founder_action"] is True
    assert row_fa["due_date"] == date_cls(2026, 4, 30)


def test_transform_issue_pr_url_extracted_from_description():
    issue = dict(fx.LINEAR_ISSUE_QUEUE)
    issue["description"] = "Landed: https://github.com/nate-step/captains-cabinet/pull/123 \nShip."
    skip, unresolved = [], []
    row = etl_linear._transform_issue(issue, _ISSUE_MAPPING, {}, skip, unresolved)
    assert row["pr_url"] == "https://github.com/nate-step/captains-cabinet/pull/123"


def test_transform_issue_completed_at_only_for_done():
    # Contract: completed_at populated only when status=='done'. WIP rows
    # with a completedAt timestamp (shouldn't normally happen, but defensive)
    # must NOT carry the timestamp through.
    issue_done = dict(fx.LINEAR_ISSUE_DONE)
    row_done = etl_linear._transform_issue(issue_done, _ISSUE_MAPPING, {}, [], [])
    assert row_done["status"] == "done"
    assert row_done["completed_at"] is not None

    issue_queue = dict(fx.LINEAR_ISSUE_QUEUE)
    issue_queue["completedAt"] = "2026-04-22T00:00:00Z"  # stale/spurious
    row_queue = etl_linear._transform_issue(issue_queue, _ISSUE_MAPPING, {}, [], [])
    assert row_queue["status"] == "queue"
    assert row_queue["completed_at"] is None


def test_transform_issue_parent_epic_ref_from_lookup():
    # project.id → epic_lookup.get → parent_epic_ref. Empty lookup → None.
    issue = dict(fx.LINEAR_ISSUE_QUEUE)  # project.id = "p1"
    epic_lookup = {"p1": 7777}
    row = etl_linear._transform_issue(issue, _ISSUE_MAPPING, epic_lookup, [], [])
    assert row["parent_epic_ref"] == 7777

    row_none = etl_linear._transform_issue(issue, _ISSUE_MAPPING, {}, [], [])
    assert row_none["parent_epic_ref"] is None


# ---------------------------------------------------------------------------
# GitHub `_transform_issue` — FW-marker gating, github_login assignee path,
# label-driven priority/blocked/flags, closed+not_planned→cancelled
# invariant, and the per-source invariants (context_slug, external_source,
# parent_epic_ref=None, due_date=None).
# ---------------------------------------------------------------------------

_GH_MAPPING = {
    "emails": {},
    "github_logins": {
        "cto-cabinet": "cto",
        "nate-step": "captain",
        "cpo-cabinet": "cpo",
    },
}


def test_gh_transform_no_fw_marker_skips():
    # Docstring invariant: absent FW-### marker → row is skipped with reason.
    # This is how random user-reported GH issues stay out of officer_tasks.
    skip, unresolved = [], []
    result = etl_github._transform_issue(
        fx.GH_ISSUE_NO_FW_MARKER, _GH_MAPPING, skip, unresolved
    )
    assert result is None
    assert len(skip) == 1
    assert skip[0]["reason"] == "no_fw_marker"
    assert skip[0]["external_ref"] == str(fx.GH_ISSUE_NO_FW_MARKER["number"])


def test_gh_transform_fw_marker_becomes_external_ref():
    # external_ref is the FW-### marker, not the issue number. Critical for
    # de-duplication against Linear rows that reference the same FW-###.
    skip, unresolved = [], []
    row = etl_github._transform_issue(
        fx.GH_ISSUE_FW_MARKED, _GH_MAPPING, skip, unresolved
    )
    assert row is not None
    assert row["external_ref"] == "FW-024"
    assert row["external_source"] == "github-issues"


def test_gh_transform_context_slug_always_cabinet_framework():
    # GH ETL is the cabinet-framework side — context_slug invariant MUST NOT
    # be "sensed" (that's Linear's context). If this breaks, framework tasks
    # would pollute the Sensed product-task scope for briefings.
    row = etl_github._transform_issue(fx.GH_ISSUE_FW_MARKED, _GH_MAPPING, [], [])
    assert row["context_slug"] == "cabinet-framework"


def test_gh_transform_per_source_invariants():
    # GH ETL synthesizes no epic rows + has no native due_date field —
    # parent_epic_ref and due_date MUST always be None on this source.
    row = etl_github._transform_issue(fx.GH_ISSUE_FW_MARKED, _GH_MAPPING, [], [])
    assert row["parent_epic_ref"] is None
    assert row["due_date"] is None
    assert row["type"] == "task"


def test_gh_transform_closed_not_planned_cancelled_with_cancelled_at():
    # Key contract: state='closed' + state_reason='not_planned' → status
    # 'cancelled' AND cancelled_at takes closed_at. Distinct from completed_at
    # (which stays None). This is the AC #52 fixture.
    skip, unresolved = [], []
    row = etl_github._transform_issue(
        fx.GH_ISSUE_CLOSED_NOT_PLANNED, _GH_MAPPING, skip, unresolved
    )
    assert row["status"] == "cancelled"
    assert row["cancelled_at"] == datetime(2026, 4, 8, 16, 45, 0, tzinfo=timezone.utc)
    assert row["completed_at"] is None


def test_gh_transform_closed_fixed_done_with_completed_at():
    # Mirror of the above: state='closed' + state_reason='completed' → done
    # with completed_at=closed_at, cancelled_at=None. Pins the three-way
    # split (done / cancelled / none) works both directions.
    skip, unresolved = [], []
    row = etl_github._transform_issue(
        fx.GH_ISSUE_CLOSED_FIXED, _GH_MAPPING, skip, unresolved
    )
    assert row["status"] == "done"
    assert row["completed_at"] == datetime(2026, 4, 5, 11, 30, 0, tzinfo=timezone.utc)
    assert row["cancelled_at"] is None


def test_gh_transform_github_login_assignee_resolved():
    # GH routes assignee via github_login (not email). Resolution must hit
    # the github_logins side of the mapping dict, not emails.
    issue = dict(fx.GH_ISSUE_FW_MARKED)
    issue["assignee"] = {"login": "cto-cabinet"}
    skip, unresolved = [], []
    row = etl_github._transform_issue(issue, _GH_MAPPING, skip, unresolved)
    assert row["officer_slug"] == "cto"
    assert len(unresolved) == 0


def test_gh_transform_captain_login_forces_founder_action():
    # Same contract as Linear side: assignee resolving to "captain" auto-
    # flags founder_action regardless of label presence.
    issue = dict(fx.GH_ISSUE_FW_MARKED)
    issue["assignee"] = {"login": "nate-step"}  # → captain
    issue["labels"] = [{"name": "framework"}]  # no founder-action label
    skip, unresolved = [], []
    row = etl_github._transform_issue(issue, _GH_MAPPING, skip, unresolved)
    assert row["officer_slug"] == "captain"
    assert row["founder_action"] is True


def test_gh_transform_unresolved_assignee_appends_with_fw_ref():
    # Unresolved entry's external_ref is the FW marker (not issue number),
    # mirroring the external_ref contract for the row. Keeps unresolved-log
    # consistent with the skipped-row log.
    issue = dict(fx.GH_ISSUE_FW_MARKED)
    issue["assignee"] = {"login": "stranger-gh"}
    skip, unresolved = [], []
    row = etl_github._transform_issue(issue, _GH_MAPPING, skip, unresolved)
    assert row["officer_slug"] is None
    assert len(unresolved) == 1
    assert unresolved[0]["external_ref"] == "FW-024"
    assert unresolved[0]["source"] == "github-issues"
    assert unresolved[0]["raw_identifier"] == "stranger-gh"


def test_gh_transform_blocked_label_sets_overlay():
    # GH has no native blocked field — "blocked" label sets blocked=True
    # and blocked_reason="blocked" (literal, not a human-readable phrase).
    issue = dict(fx.GH_ISSUE_FW_MARKED)
    issue["labels"] = [{"name": "framework"}, {"name": "blocked"}]
    row = etl_github._transform_issue(issue, _GH_MAPPING, [], [])
    assert row["blocked"] is True
    assert row["blocked_reason"] == "blocked"


def test_gh_transform_no_blocked_label_blocked_false():
    row = etl_github._transform_issue(fx.GH_ISSUE_FW_MARKED, _GH_MAPPING, [], [])
    assert row["blocked"] is False
    assert row["blocked_reason"] is None


def test_gh_transform_priority_from_label():
    # GH priority comes from labels (unlike Linear's numeric field).
    issue = dict(fx.GH_ISSUE_FW_MARKED)
    issue["labels"] = [{"name": "framework"}, {"name": "priority-p1"}]
    row = etl_github._transform_issue(issue, _GH_MAPPING, [], [])
    assert row["priority"] == "P1"


def test_gh_transform_pr_url_extracted_from_body():
    # PR URL extracted from body (unlike Linear's description).
    issue = dict(fx.GH_ISSUE_FW_MARKED)
    issue["body"] = (
        "FW-024\n\nLanded in https://github.com/nate-step/captains-cabinet/pull/77"
    )
    row = etl_github._transform_issue(issue, _GH_MAPPING, [], [])
    assert row["pr_url"] == "https://github.com/nate-step/captains-cabinet/pull/77"


def test_gh_transform_captain_decision_label():
    row = etl_github._transform_issue(
        fx.GH_ISSUE_CAPTAIN_DECISION, _GH_MAPPING, [], []
    )
    assert row["captain_decision"] is True


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
