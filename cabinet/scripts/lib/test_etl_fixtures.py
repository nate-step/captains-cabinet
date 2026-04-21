"""Spec 039 Phase A — ETL test fixtures.

Sample Linear + GitHub API response shapes for unit testing etl-linear.py
and etl-github.py transforms. These are representative, not exhaustive —
future unit tests can extend with edge-case fixtures as needed.

Usage in a test (pseudo):
    from test_etl_fixtures import LINEAR_ISSUE_WIP_BLOCKED, GH_ISSUE_FW_MARKED
    from etl_linear import _map_state
    assert _map_state(LINEAR_ISSUE_WIP_BLOCKED) == ("wip", True, "Waiting on design")
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Linear issue fixtures (shape per Linear GraphQL `issue` type, trimmed)
# ---------------------------------------------------------------------------

LINEAR_ISSUE_QUEUE = {
    "id": "3ab91f00-aaaa-bbbb-cccc-000000000001",
    "identifier": "SEN-247",
    "title": "Implement voice-message TTS fallback",
    "description": "Fallback when ElevenLabs is rate-limited.",
    "state": {"id": "s1", "name": "Backlog", "type": "backlog"},
    "priority": 2,
    "assignee": {"email": "cto@cabinet.local"},
    "labels": {"nodes": [{"name": "backend"}]},
    "dueDate": None,
    "createdAt": "2026-04-15T10:00:00Z",
    "completedAt": None,
    "canceledAt": None,
    "url": "https://linear.app/sensed/issue/SEN-247",
    "parent": None,
    "project": {"id": "p1", "name": "Spec 039 — Migration"},
}

LINEAR_ISSUE_WIP_BLOCKED = {
    "id": "3ab91f00-aaaa-bbbb-cccc-000000000002",
    "identifier": "SEN-248",
    "title": "Reconcile duplicate officer_tasks rows",
    "description": "Blocked on CPO decision re: merge strategy.",
    "state": {"id": "s2", "name": "Blocked", "type": "started"},
    "priority": 1,
    "assignee": {"email": "cto@cabinet.local"},
    "labels": {"nodes": [{"name": "blocked"}, {"name": "founder-action"}]},
    "dueDate": "2026-04-25",
    "createdAt": "2026-04-10T08:00:00Z",
    "completedAt": None,
    "canceledAt": None,
    "url": "https://linear.app/sensed/issue/SEN-248",
    "parent": None,
    "project": {"id": "p1", "name": "Spec 039 — Migration"},
}

LINEAR_ISSUE_DONE = {
    "id": "3ab91f00-aaaa-bbbb-cccc-000000000003",
    "identifier": "SEN-246",
    "title": "Ship Library MCP v0.1",
    "description": "Initial read-only Library MCP shim.",
    "state": {"id": "s3", "name": "Done", "type": "completed"},
    "priority": 2,
    "assignee": {"email": "cto@cabinet.local"},
    "labels": {"nodes": []},
    "dueDate": None,
    "createdAt": "2026-03-20T12:00:00Z",
    "completedAt": "2026-04-14T09:30:00Z",
    "canceledAt": None,
    "url": "https://linear.app/sensed/issue/SEN-246",
    "parent": None,
    "project": None,
}

LINEAR_ISSUE_CANCELLED = {
    "id": "3ab91f00-aaaa-bbbb-cccc-000000000004",
    "identifier": "SEN-245",
    "title": "Deprecated: old auth middleware",
    "description": "Superseded by SEN-250.",
    "state": {"id": "s4", "name": "Cancelled", "type": "canceled"},
    "priority": 3,
    "assignee": None,
    "labels": {"nodes": []},
    "dueDate": None,
    "createdAt": "2026-02-01T10:00:00Z",
    "completedAt": None,
    "canceledAt": "2026-04-01T11:00:00Z",
    "url": "https://linear.app/sensed/issue/SEN-245",
    "parent": None,
    "project": None,
}

# FW-023 fixture-gap (b): captain-decision label on Linear — etl-linear.py L278
# sets captain_decision=True when the label appears in labels.nodes[].name.
LINEAR_ISSUE_CAPTAIN_DECISION = {
    "id": "3ab91f00-aaaa-bbbb-cccc-000000000005",
    "identifier": "SEN-251",
    "title": "Pivot pricing model: flat-tier → usage-based",
    "description": "Captain directive 2026-04-18 — switch to usage-based before launch.",
    "state": {"id": "s2", "name": "In Progress", "type": "started"},
    "priority": 1,
    "assignee": {"email": "cpo@cabinet.local"},
    "labels": {"nodes": [{"name": "captain-decision"}, {"name": "pricing"}]},
    "dueDate": None,
    "createdAt": "2026-04-18T15:00:00Z",
    "completedAt": None,
    "canceledAt": None,
    "url": "https://linear.app/sensed/issue/SEN-251",
    "parent": None,
    "project": None,
}

LINEAR_PROJECT_SYNTHESIZED_EPIC = {
    "id": "p1",
    "name": "Spec 039 — Migration",
    "description": "Linear/GH → officer_tasks migration.",
    "state": "started",
    "targetDate": "2026-05-01",
    "createdAt": "2026-03-15T09:00:00Z",
}

# ---------------------------------------------------------------------------
# GitHub Issues fixtures (shape per REST v3 /repos/:o/:r/issues, trimmed)
# ---------------------------------------------------------------------------

GH_ISSUE_FW_MARKED = {
    "number": 42,
    "title": "FW-024: Library MCP Python adapter",
    "body": "FW-024\n\nFramework item: ship a Python adapter that wraps the\nlibrary_create_record MCP so officers can archive from scripts.",
    "state": "open",
    "assignees": [{"login": "nate-step"}],
    "labels": [{"name": "framework"}, {"name": "founder-action"}],
    "created_at": "2026-04-10T10:00:00Z",
    "closed_at": None,
    "html_url": "https://github.com/nate-step/captains-cabinet/issues/42",
}

GH_ISSUE_CLOSED_FIXED = {
    "number": 41,
    "title": "FW-023: Hook substring-glob bug",
    "body": "FW-023\n\nFixed in PR #45.",
    "state": "closed",
    "state_reason": "completed",
    "assignees": [{"login": "cto-cabinet"}],
    "labels": [{"name": "framework"}, {"name": "bug"}],
    "created_at": "2026-03-28T14:00:00Z",
    "closed_at": "2026-04-05T11:30:00Z",
    "html_url": "https://github.com/nate-step/captains-cabinet/issues/41",
    "pull_request": {"url": "https://api.github.com/repos/nate-step/captains-cabinet/pulls/45"},
}

GH_ISSUE_NO_FW_MARKER = {
    # Should be SKIPPED by etl-github.py — no FW-NNN marker in body
    "number": 40,
    "title": "Random user-reported issue",
    "body": "Something broke.",
    "state": "open",
    "assignees": [],
    "labels": [],
    "created_at": "2026-04-11T10:00:00Z",
    "closed_at": None,
    "html_url": "https://github.com/nate-step/captains-cabinet/issues/40",
}

# FW-023 fixture-gap (a): AC #52 — closed + state_reason='not_planned' must
# map to status='cancelled' with cancelled_at=closed_at. etl-github.py L125-126
# is the transform under test.
GH_ISSUE_CLOSED_NOT_PLANNED = {
    "number": 39,
    "title": "FW-013: Deprecated bootstrap path",
    "body": "FW-013\n\nSuperseded by unified bootstrap-host.sh; won't pursue.",
    "state": "closed",
    "state_reason": "not_planned",
    "assignees": [{"login": "cto-cabinet"}],
    "labels": [{"name": "framework"}, {"name": "wontfix"}],
    "created_at": "2026-02-20T09:00:00Z",
    "closed_at": "2026-04-08T16:45:00Z",
    "html_url": "https://github.com/nate-step/captains-cabinet/issues/39",
}

# FW-023 fixture-gap (b), GH parity: captain-decision label on GH issue.
# etl-github.py L179 sets captain_decision=True when the label appears.
GH_ISSUE_CAPTAIN_DECISION = {
    "number": 38,
    "title": "FW-010: Use Library MCP for all archival",
    "body": "FW-010\n\nCaptain ruled 2026-04-12: all archival writes go through Library MCP; no direct Notion API from officers.",
    "state": "open",
    "assignees": [{"login": "nate-step"}],
    "labels": [
        {"name": "framework"},
        {"name": "captain-decision"},
        {"name": "architecture"},
    ],
    "created_at": "2026-04-12T18:00:00Z",
    "closed_at": None,
    "html_url": "https://github.com/nate-step/captains-cabinet/issues/38",
}

# ---------------------------------------------------------------------------
# Convenience bundles
# ---------------------------------------------------------------------------

ALL_LINEAR_ISSUES = [
    LINEAR_ISSUE_QUEUE,
    LINEAR_ISSUE_WIP_BLOCKED,
    LINEAR_ISSUE_DONE,
    LINEAR_ISSUE_CANCELLED,
    LINEAR_ISSUE_CAPTAIN_DECISION,
]

ALL_GH_ISSUES = [
    GH_ISSUE_FW_MARKED,
    GH_ISSUE_CLOSED_FIXED,
    GH_ISSUE_NO_FW_MARKER,
    GH_ISSUE_CLOSED_NOT_PLANNED,
    GH_ISSUE_CAPTAIN_DECISION,
]
