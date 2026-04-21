# cabinet/scripts/lib/etl-linear.py — Spec 039 Phase A, Track A1.
# Extracts Linear SEN-* issues + projects, transforms per §5.A1, upserts
# into officer_tasks via etl-common.  Linear GraphQL endpoint; bearer auth.
# Dependencies: requests  (install: pip3 install requests)

from __future__ import annotations

import logging
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests

# Allow imports from sibling lib directory when run directly.
# etl-common.py has a hyphen — use importlib since Python can't import hyphened names directly.
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location("etl_common", Path(__file__).parent / "etl-common.py")
common = _ilu.module_from_spec(_spec)  # type: ignore[arg-type]
_spec.loader.exec_module(common)  # type: ignore[union-attr]

logger = logging.getLogger(__name__)

_LINEAR_ENDPOINT = "https://api.linear.app/graphql"
_PAGE_SIZE = 100


# ---------------------------------------------------------------------------
# GraphQL client helper
# ---------------------------------------------------------------------------

def _gql(query: str, variables: Dict[str, Any], api_key: str) -> Dict[str, Any]:
    """Execute a Linear GraphQL query; raises on HTTP error or GQL errors."""
    resp = requests.post(
        _LINEAR_ENDPOINT,
        json={"query": query, "variables": variables},
        headers={"Authorization": api_key, "Content-Type": "application/json"},
        timeout=30,
    )
    resp.raise_for_status()
    body = resp.json()
    if body.get("errors"):
        raise RuntimeError(f"Linear GraphQL errors: {body['errors']}")
    return body["data"]


# ---------------------------------------------------------------------------
# Team resolution: get SEN team UUID by key
# ---------------------------------------------------------------------------

_TEAM_QUERY = """
query GetTeam($key: String!) {
  teams(filter: { key: { eq: $key } }) {
    nodes { id name key }
  }
}
"""


def _get_team_id(api_key: str, team_key: str = "SEN") -> str:
    """Return UUID of team with given key; raises if not found."""
    data = _gql(_TEAM_QUERY, {"key": team_key}, api_key)
    nodes = data.get("teams", {}).get("nodes", [])
    if not nodes:
        raise RuntimeError(
            f"Linear team with key '{team_key}' not found. "
            "Check LINEAR_API_KEY and workspace."
        )
    return nodes[0]["id"]


# ---------------------------------------------------------------------------
# Projects extraction
# ---------------------------------------------------------------------------

_PROJECTS_QUERY = """
query GetProjects($after: String) {
  projects(first: 50, after: $after) {
    nodes {
      id
      name
      description
      state
      createdAt
      updatedAt
      completedAt
    }
    pageInfo { hasNextPage endCursor }
  }
}
"""


def _fetch_projects(api_key: str) -> List[Dict[str, Any]]:
    """Return all Linear projects (paginated, first 50/page)."""
    projects: List[Dict[str, Any]] = []
    cursor: Optional[str] = None
    while True:
        data = _gql(_PROJECTS_QUERY, {"after": cursor}, api_key)
        page = data["projects"]
        projects.extend(page["nodes"])
        if not page["pageInfo"]["hasNextPage"]:
            break
        cursor = page["pageInfo"]["endCursor"]
    logger.info("Fetched %d Linear projects", len(projects))
    return projects


# ---------------------------------------------------------------------------
# Issues extraction
# ---------------------------------------------------------------------------

_ISSUES_QUERY = """
query GetIssues($teamId: String!, $after: String) {
  team(id: $teamId) {
    issues(first: 100, after: $after) {
      nodes {
        identifier
        title
        description
        state { type name }
        priority
        labels { nodes { name } }
        assignee { email displayName }
        dueDate
        createdAt
        updatedAt
        completedAt
        canceledAt
        project { id name }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
"""


def _fetch_issues(api_key: str, team_id: str) -> List[Dict[str, Any]]:
    """Return all issues for team_id (paginated 100/page)."""
    issues: List[Dict[str, Any]] = []
    cursor: Optional[str] = None
    while True:
        data = _gql(_ISSUES_QUERY, {"teamId": team_id, "after": cursor}, api_key)
        page = data["team"]["issues"]
        issues.extend(page["nodes"])
        logger.debug("Fetched %d issues so far", len(issues))
        if not page["pageInfo"]["hasNextPage"]:
            break
        cursor = page["pageInfo"]["endCursor"]
    logger.info("Fetched %d Linear issues for team %s", len(issues), team_id)
    return issues


# ---------------------------------------------------------------------------
# Field transforms (§5.A1)
# ---------------------------------------------------------------------------

_STATE_TYPE_MAP = {
    "unstarted": "queue",
    "backlog": "queue",
    "triage": "queue",
    "started": "wip",   # refined per state.name below
    "completed": "done",
    "canceled": "cancelled",
}

_BLOCKED_NAMES = {"Blocked", "On Hold"}

_PRIORITY_MAP = {1: "P0", 2: "P1", 3: "P2", 4: "P3"}  # 0 → None


def _map_state(state: Dict[str, Any]) -> tuple[str, bool, Optional[str]]:
    """Return (status, blocked, blocked_reason) from Linear state dict."""
    stype = state.get("type", "unstarted")
    sname = state.get("name", "")
    blocked = sname in _BLOCKED_NAMES
    blocked_reason = sname if blocked else None

    # Preserve block semantics per Spec 038 §4.5: blocked is a boolean overlay
    # on WIP rows. A Blocked/On Hold state.name with type='started' stays as
    # wip+blocked, not queue (queue+blocked is incoherent per 038's model).
    # Only route started→queue when the workflow state is "started" without
    # being In Progress or a block overlay (intermediate workflow buckets).
    if stype == "started" and sname != "In Progress" and not blocked:
        status = "queue"
    else:
        status = _STATE_TYPE_MAP.get(stype, "queue")
    return status, blocked, blocked_reason


def _parse_dt(val: Optional[str]) -> Optional[datetime]:
    """Parse ISO-8601 string to datetime; return None if absent."""
    if not val:
        return None
    # Linear timestamps end in Z or +00:00
    try:
        return datetime.fromisoformat(val.replace("Z", "+00:00"))
    except ValueError:
        return None


def _transform_project(proj: Dict[str, Any]) -> Dict[str, Any]:
    """Synthesize an officer_tasks epic row from a Linear project (M-2 amend)."""
    # Linear's project state scalar is American-English: `canceled` (one L).
    # officer_tasks uses British spelling — map both forms defensively.
    state = proj.get("state", "")
    if state == "completed":
        status = "done"
    elif state in ("canceled", "cancelled", "archived"):
        status = "cancelled"
    else:
        status = "wip"

    cancelled_at = None
    completed_at = None
    if status == "done":
        completed_at = _parse_dt(proj.get("completedAt"))
    if status == "cancelled":
        cancelled_at = _parse_dt(proj.get("updatedAt"))  # best proxy

    return {
        "officer_slug": None,
        "title": proj["name"].strip(),
        "description": proj.get("description"),
        "status": status,
        "blocked": False,
        "blocked_reason": None,
        "context_slug": "sensed",
        "priority": None,
        "type": "epic",
        "parent_epic_ref": None,  # epics never have a parent (epic_no_parent CHECK)
        "founder_action": False,
        "due_date": None,
        "captain_decision": False,
        "decision_ref": None,
        "external_ref": f"linear-project:{proj['id']}",
        "external_source": "linear",
        "pr_url": None,
        "created_at": _parse_dt(proj.get("createdAt")),
        "updated_at": _parse_dt(proj.get("updatedAt")),
        "completed_at": completed_at,
        "cancelled_at": cancelled_at,
    }


def _transform_issue(
    issue: Dict[str, Any],
    email_mapping: Dict[str, Dict[str, str]],
    epic_lookup: Dict[str, int],  # project_id → officer_tasks.id
    skip_entries: List[Dict[str, Any]],
    unresolved_entries: List[Dict[str, Any]],
) -> Optional[Dict[str, Any]]:
    """Transform a raw Linear issue dict into an officer_tasks row dict.

    Returns None if the issue should be skipped (adds to skip_entries).
    Appends to unresolved_entries for unmapped assignees.
    """
    state = issue.get("state") or {}
    stype = state.get("type", "unstarted")

    # Skip duplicates (Linear concept; not a valid target status)
    if stype == "duplicate" or state.get("name", "").lower() == "duplicate":
        skip_entries.append({
            "external_ref": issue["identifier"],
            "reason": "duplicate_state",
            "raw": {"state": state},
        })
        return None

    status, blocked, blocked_reason = _map_state(state)

    # Labels
    label_names = [n["name"] for n in (issue.get("labels") or {}).get("nodes", [])]
    founder_action = "founder-action" in label_names
    captain_decision = "captain-decision" in label_names

    # Assignee resolution
    assignee_email = (issue.get("assignee") or {}).get("email")
    officer_slug, unresolved = common.resolve_assignee(assignee_email, "email", email_mapping)
    if unresolved:
        unresolved_entries.append({
            "external_ref": issue["identifier"],
            "source": "linear",
            "raw_identifier": unresolved,
        })
    # Captain-assigned → also flag founder_action
    if officer_slug == "captain":
        founder_action = True

    # Priority: 0 → None; 1–4 → P0–P3
    raw_priority = issue.get("priority")
    priority = _PRIORITY_MAP.get(raw_priority) if raw_priority else None

    # Dates
    created_at = _parse_dt(issue.get("createdAt"))
    updated_at = _parse_dt(issue.get("updatedAt"))
    completed_at = _parse_dt(issue.get("completedAt")) if status == "done" else None
    cancelled_at = _parse_dt(issue.get("canceledAt")) if status == "cancelled" else None

    # due_date — only for founder_action rows
    due_date = None
    if founder_action and issue.get("dueDate"):
        try:
            from datetime import date as date_cls
            due_date = date_cls.fromisoformat(issue["dueDate"])
        except ValueError:
            pass

    # PR URL extracted from description
    pr_url = common.extract_pr_url(issue.get("description"))

    # Parent epic lookup
    project = issue.get("project") or {}
    project_id = project.get("id")
    parent_epic_ref = epic_lookup.get(project_id) if project_id else None

    return {
        "officer_slug": officer_slug,
        "title": issue["title"].strip(),
        "description": issue.get("description"),
        "status": status,
        "blocked": blocked,
        "blocked_reason": blocked_reason,
        "context_slug": "sensed",
        "priority": priority,
        "type": "task",
        "parent_epic_ref": parent_epic_ref,
        "founder_action": founder_action,
        "due_date": due_date,
        "captain_decision": captain_decision,
        "decision_ref": None,  # CoS postflight backfill
        "external_ref": issue["identifier"],
        "external_source": "linear",
        "pr_url": pr_url,
        "created_at": created_at,
        "updated_at": updated_at,
        "completed_at": completed_at,
        "cancelled_at": cancelled_at,
    }


# ---------------------------------------------------------------------------
# Epic-id lookup helper
# ---------------------------------------------------------------------------

def _lookup_epic_id(conn: Any, project_id: str) -> Optional[int]:
    """Query officer_tasks for the synthetic epic row matching a Linear project id."""
    ext_ref = f"linear-project:{project_id}"
    with conn.cursor() as cur:
        cur.execute(
            "SELECT id FROM officer_tasks WHERE external_source='linear' AND external_ref=%s",
            (ext_ref,),
        )
        row = cur.fetchone()
    return row[0] if row else None


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def run_linear_etl(
    conn: Any,
    dry_run: bool = False,
    workspace_id: Optional[str] = None,
) -> Dict[str, Any]:
    """Run Track A1 — Linear SEN-* extraction, transform, and upsert.

    Args:
        conn: active psycopg2 connection (advisory lock already held by caller).
        dry_run: if True, extract + transform but do not upsert.
        workspace_id: unused (Linear team resolved by key 'SEN'); reserved for
            future multi-workspace support.

    Returns dict with keys:
        inserted, updated, skipped, unresolved, projects_extracted, issues_extracted
    """
    api_key = os.environ.get("LINEAR_API_KEY")
    if not api_key:
        raise EnvironmentError("LINEAR_API_KEY env var is required")
    print("(LINEAR_API_KEY: set)", file=sys.stderr)

    email_mapping = common.load_officer_emails()

    # 1. Fetch team ID
    team_id = _get_team_id(api_key)
    logger.info("Linear SEN team id: %s", team_id)

    # 2. Fetch + upsert projects (epics) first so parent_epic_ref can be set
    projects = _fetch_projects(api_key)
    epic_lookup: Dict[str, int] = {}  # project_id → officer_tasks.id

    inserted = updated = skipped = 0
    project_rows_processed = 0

    for proj in projects:
        row = _transform_project(proj)
        archive_record = {**proj, "external_ref": row["external_ref"]}
        if dry_run:
            logger.info("[dry-run] would upsert epic: %s", row["external_ref"])
            project_rows_processed += 1
            continue
        try:
            op, task_id = common.upsert_task(conn, row)
            epic_lookup[proj["id"]] = task_id
            if op == "inserted":
                inserted += 1
            else:
                updated += 1
            project_rows_processed += 1
            common.archive_to_library(conn, archive_record)
            logger.debug("Epic %s → %s (id=%d)", row["external_ref"], op, task_id)
        except Exception as exc:  # noqa: BLE001
            logger.error("Failed to upsert epic %s: %s", row["external_ref"], exc)
            skipped += 1
            conn.rollback()

    # For dry_run: populate epic_lookup via DB query (rows may exist from prior run)
    if dry_run:
        for proj in projects:
            existing_id = _lookup_epic_id(conn, proj["id"])
            if existing_id:
                epic_lookup[proj["id"]] = existing_id

    # 3. Fetch issues
    issues = _fetch_issues(api_key, team_id)
    skip_entries: List[Dict[str, Any]] = []
    unresolved_entries: List[Dict[str, Any]] = []

    for issue in issues:
        row = _transform_issue(issue, email_mapping, epic_lookup, skip_entries, unresolved_entries)
        if row is None:
            skipped += 1
            continue
        archive_record = {**issue, "external_ref": row["external_ref"]}
        if dry_run:
            logger.info("[dry-run] would upsert issue: %s", row["external_ref"])
            continue
        try:
            op, task_id = common.upsert_task(conn, row)
            if op == "inserted":
                inserted += 1
            else:
                updated += 1
            common.archive_to_library(conn, archive_record)
            logger.debug("Issue %s → %s (id=%d)", row["external_ref"], op, task_id)
        except Exception as exc:  # noqa: BLE001
            logger.error("Failed to upsert issue %s: %s", row["external_ref"], exc)
            skip_entries.append({
                "external_ref": issue["identifier"],
                "reason": f"upsert_error: {exc}",
                "raw": {k: v for k, v in issue.items() if k != "description"},
            })
            skipped += 1
            conn.rollback()

    # Write logs
    if skip_entries:
        path = common.write_skip_log(skip_entries)
        logger.info("Wrote %d skip entries to %s", len(skip_entries), path)
    if unresolved_entries:
        path = common.write_unresolved_log(unresolved_entries)
        logger.info(
            "Wrote %d unresolved assignee entries to %s",
            len(unresolved_entries), path,
        )

    return {
        "inserted": inserted,
        "updated": updated,
        "skipped": skipped,
        "unresolved": unresolved_entries,
        "projects_extracted": len(projects),
        "issues_extracted": len(issues),
    }
