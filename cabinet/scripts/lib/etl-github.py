# cabinet/scripts/lib/etl-github.py — Spec 039 Phase A, Track A2.
# Extracts GitHub Issues FW-* from nate-step/founders-cabinet, transforms
# per §5.A2, upserts into officer_tasks via etl-common.
# Dependencies: requests  (install: pip3 install requests)

from __future__ import annotations

import logging
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import requests

sys.path.insert(0, str(Path(__file__).parent))
# etl-common.py has a hyphen — use importlib since Python can't import hyphened names directly.
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location("etl_common", Path(__file__).parent / "etl-common.py")
common = _ilu.module_from_spec(_spec)  # type: ignore[arg-type]
_spec.loader.exec_module(common)  # type: ignore[union-attr]

logger = logging.getLogger(__name__)

_GH_REPO = "nate-step/captains-cabinet"
_ISSUES_URL = f"https://api.github.com/repos/{_GH_REPO}/issues"
_PAGE_SIZE = 100

# FW-marker regex: start-of-line + word boundary. Accepts 'FW-024',
# 'FW-024: title', 'FW-024 — details', 'FW-024\n' — anything after the number
# that isn't a digit is fine. Avoids the full-line anchoring that silently
# dropped real FW issues with trailing content (adversarial review H1).
_FW_RE = re.compile(r"(?m)^(FW-\d+)\b")
# Priority label: priority-p0 … priority-p3
_PRIORITY_LABEL_RE = re.compile(r"^priority-p([0-3])$", re.IGNORECASE)


# ---------------------------------------------------------------------------
# GH REST client helper
# ---------------------------------------------------------------------------

def _gh_get(url: str, params: Dict[str, Any], token: str) -> requests.Response:
    """GET url with GitHub bearer auth; raises on HTTP error."""
    resp = requests.get(
        url,
        params=params,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github.v3+json",
        },
        timeout=30,
    )
    remaining = int(resp.headers.get("X-RateLimit-Remaining", 999))
    if remaining < 50:
        logger.warning(
            "GitHub rate limit low: %d requests remaining (reset at %s)",
            remaining,
            resp.headers.get("X-RateLimit-Reset", "unknown"),
        )
    resp.raise_for_status()
    return resp


# ---------------------------------------------------------------------------
# Issues extraction
# ---------------------------------------------------------------------------

def _fetch_issues(token: str) -> List[Dict[str, Any]]:
    """Return all non-PR issues for nate-step/founders-cabinet (state=all)."""
    issues: List[Dict[str, Any]] = []
    page = 1
    while True:
        resp = _gh_get(
            _ISSUES_URL,
            {"state": "all", "per_page": _PAGE_SIZE, "page": page},
            token,
        )
        batch = resp.json()
        if not batch:
            break
        for item in batch:
            # GH issues endpoint returns PRs too; filter them out
            if item.get("pull_request") is not None:
                continue
            issues.append(item)
        logger.debug("Fetched page %d (%d items, %d issues so far)", page, len(batch), len(issues))
        # If fewer than page_size returned, we're on the last page
        if len(batch) < _PAGE_SIZE:
            break
        page += 1
    logger.info("Fetched %d GH issues (non-PR) from %s", len(issues), _GH_REPO)
    return issues


# ---------------------------------------------------------------------------
# FW-marker extraction
# ---------------------------------------------------------------------------

def _extract_fw_marker(body: Optional[str]) -> Optional[str]:
    """Return 'FW-NNN' from issue body, or None if absent."""
    if not body:
        return None
    m = _FW_RE.search(body)
    return m.group(1) if m else None


# ---------------------------------------------------------------------------
# Field transforms (§5.A2)
# ---------------------------------------------------------------------------

def _map_status(
    state: str,
    state_reason: Optional[str],
) -> tuple[str, Optional[str]]:
    """Return (status, cancelled_at_source_key) from GH state fields.

    GH has no native wip distinction — open issues default to 'queue'.
    Officers promote to 'wip' via /tasks UI post-ETL.
    """
    if state == "open":
        return "queue", None
    # closed
    if state_reason == "not_planned":
        return "cancelled", "closed_at"
    return "done", "closed_at"


def _extract_priority(label_names: List[str]) -> Optional[str]:
    """Return priority string (P0–P3) from label list, or None."""
    for name in label_names:
        m = _PRIORITY_LABEL_RE.match(name)
        if m:
            return f"P{m.group(1)}"
    return None


def _parse_dt(val: Optional[str]) -> Optional[datetime]:
    if not val:
        return None
    try:
        return datetime.fromisoformat(val.replace("Z", "+00:00"))
    except ValueError:
        return None


def _transform_issue(
    issue: Dict[str, Any],
    email_mapping: Dict[str, Dict[str, str]],
    skip_entries: List[Dict[str, Any]],
    unresolved_entries: List[Dict[str, Any]],
) -> Optional[Dict[str, Any]]:
    """Transform GH issue to officer_tasks row dict.

    Returns None + appends to skip_entries if FW-marker absent.
    """
    body = issue.get("body") or ""
    fw_marker = _extract_fw_marker(body)
    if fw_marker is None:
        skip_entries.append({
            "external_ref": str(issue["number"]),
            "reason": "no_fw_marker",
            "raw": {"number": issue["number"], "title": issue.get("title", "")},
        })
        return None

    label_names = [lbl["name"] for lbl in (issue.get("labels") or [])]
    state = issue.get("state", "open")
    state_reason = issue.get("state_reason")

    status, _ = _map_status(state, state_reason)

    blocked = "blocked" in label_names
    blocked_reason = "blocked" if blocked else None

    priority = _extract_priority(label_names)
    founder_action = "founder-action" in label_names
    captain_decision = "captain-decision" in label_names

    # Assignee resolution via github_login
    assignee_login = (issue.get("assignee") or {}).get("login")
    officer_slug, unresolved = common.resolve_assignee(
        assignee_login, "github_login", email_mapping
    )
    if unresolved:
        unresolved_entries.append({
            "external_ref": fw_marker,
            "source": "github-issues",
            "raw_identifier": unresolved,
        })
    if officer_slug == "captain":
        founder_action = True

    # Timestamps
    created_at = _parse_dt(issue.get("created_at"))
    updated_at = _parse_dt(issue.get("updated_at"))

    closed_at = _parse_dt(issue.get("closed_at"))
    completed_at = closed_at if status == "done" else None
    cancelled_at = closed_at if status == "cancelled" else None

    pr_url = common.extract_pr_url(body)

    return {
        "officer_slug": officer_slug,
        "title": issue["title"].strip(),
        "description": body if body else None,
        "status": status,
        "blocked": blocked,
        "blocked_reason": blocked_reason,
        "context_slug": "cabinet-framework",
        "priority": priority,
        "type": "task",
        "parent_epic_ref": None,  # no GH project synthesis per §5.A2
        "founder_action": founder_action,
        "due_date": None,  # GH has no native due_date; CoS backfills post-ETL
        "captain_decision": captain_decision,
        "decision_ref": None,
        "external_ref": fw_marker,
        "external_source": "github-issues",
        "pr_url": pr_url,
        "created_at": created_at,
        "updated_at": updated_at,
        "completed_at": completed_at,
        "cancelled_at": cancelled_at,
    }


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def run_github_etl(
    conn: Any,
    dry_run: bool = False,
) -> Dict[str, Any]:
    """Run Track A2 — GH Issues FW-* extraction, transform, and upsert.

    Args:
        conn: active psycopg2 connection (advisory lock already held by caller).
        dry_run: if True, extract + transform but do not upsert.

    Returns dict with keys:
        inserted, updated, skipped, unresolved, projects_extracted, issues_extracted
    """
    token = os.environ.get("GITHUB_PAT")
    if not token:
        raise EnvironmentError("GITHUB_PAT env var is required")
    print("(GITHUB_PAT: set)", file=sys.stderr)

    email_mapping = common.load_officer_emails()
    issues = _fetch_issues(token)

    skip_entries: List[Dict[str, Any]] = []
    unresolved_entries: List[Dict[str, Any]] = []
    inserted = updated = skipped = 0

    for issue in issues:
        row = _transform_issue(issue, email_mapping, skip_entries, unresolved_entries)
        if row is None:
            skipped += 1
            continue
        archive_record = {**issue, "external_ref": row["external_ref"]}
        common.archive_to_library(conn, archive_record)
        if dry_run:
            logger.info("[dry-run] would upsert GH issue: %s", row["external_ref"])
            continue
        try:
            op, task_id = common.upsert_task(conn, row)
            if op == "inserted":
                inserted += 1
            else:
                updated += 1
            logger.debug("GH issue %s → %s (id=%d)", row["external_ref"], op, task_id)
        except Exception as exc:  # noqa: BLE001
            logger.error("Failed to upsert GH issue %s: %s", row["external_ref"], exc)
            skip_entries.append({
                "external_ref": row.get("external_ref", "?"),
                "reason": f"upsert_error: {exc}",
                "raw": {k: v for k, v in issue.items() if k != "body"},
            })
            skipped += 1
            conn.rollback()

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
        "projects_extracted": 0,  # no GH project synthesis
        "issues_extracted": len(issues),
    }
