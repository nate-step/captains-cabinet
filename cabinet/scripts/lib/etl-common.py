# cabinet/scripts/lib/etl-common.py — Spec 039 Phase A ETL shared utilities.
# Shared DB connection, advisory lock, session-var bypass, officer-email resolution,
# upsert helper, skip/unresolved log writers, and Library archive stub.
# Dependencies: psycopg2-binary, PyYAML  (install: pip3 install psycopg2-binary pyyaml)

from __future__ import annotations

import json
import logging
import os
import re
import signal
import sys
from datetime import date, datetime
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import yaml

# psycopg2 imported lazily inside get_db_connection so callers that only need
# load_officer_emails() / resolve_assignee() (e.g. cutover service_accounts.py)
# don't require the driver to be installed. See Spec 039 FW-024 — officer
# containers currently lack psycopg2 until Captain rebuilds from Dockerfile.

logger = logging.getLogger(__name__)

# Advisory lock identifier — must match across acquire/release/signal handler.
_LOCK_KEY = "etl:sources-to-officer-tasks"

# Resolved once at module level; populated by callers before registering signals.
_lock_conn: Optional[Any] = None


# ---------------------------------------------------------------------------
# DB connection
# ---------------------------------------------------------------------------

def get_db_connection(conn_str: str) -> Any:
    """Return a psycopg2 connection from conn_str; raises on failure."""
    import psycopg2  # lazy: keeps load_officer_emails usable without driver
    import psycopg2.extras  # noqa: F401 — ensure extras loadable for callers
    conn = psycopg2.connect(conn_str)
    conn.autocommit = False
    return conn


# ---------------------------------------------------------------------------
# Advisory lock (session-scoped — persists across tx boundaries)
# ---------------------------------------------------------------------------

def acquire_advisory_lock(conn: Any) -> None:
    """Acquire session-scoped advisory lock; blocks until available.

    Sets app.cabinet_officer='cpo-etl' after acquisition so history rows
    written during the ETL session are attributed correctly.
    """
    global _lock_conn
    _lock_conn = conn
    with conn.cursor() as cur:
        cur.execute(
            "SELECT pg_advisory_lock(hashtextextended(%s, 0))", (_LOCK_KEY,)
        )
        # Attribution — session-scoped (not LOCAL), survives tx boundaries.
        cur.execute("SET app.cabinet_officer = 'cpo-etl'")
    conn.commit()
    logger.info("Advisory lock acquired (%s)", _LOCK_KEY)


def release_advisory_lock(conn: Any) -> None:
    """Release session-scoped advisory lock. Safe to call multiple times."""
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT pg_advisory_unlock(hashtextextended(%s, 0))", (_LOCK_KEY,)
            )
        conn.commit()
        logger.info("Advisory lock released (%s)", _LOCK_KEY)
    except Exception as exc:  # noqa: BLE001
        logger.warning("Failed to release advisory lock: %s", exc)


def _make_signal_handler(conn: Any):
    """Return a SIGTERM/SIGINT handler that releases the lock before exit."""
    def handler(signum: int, frame: Any) -> None:
        logger.warning("Signal %d received — releasing advisory lock before exit", signum)
        release_advisory_lock(conn)
        sys.exit(128 + signum)
    return handler


def register_signal_handlers(conn: Any) -> None:
    """Register SIGTERM + SIGINT handlers that release the advisory lock."""
    handler = _make_signal_handler(conn)
    signal.signal(signal.SIGTERM, handler)
    signal.signal(signal.SIGINT, handler)


# ---------------------------------------------------------------------------
# ETL session variables (bypassable trigger registry — Spec 039 §4.2.1)
# ---------------------------------------------------------------------------

def set_etl_session_vars(cur: Any) -> None:
    """Issue all five SET LOCAL bypass variables on cursor cur.

    Must be called inside an open transaction before any INSERT/UPDATE so
    the bypassable triggers (enforce_founder_action_due_date,
    enforce_captain_decision_ref, bump_officer_tasks_updated_at,
    enforce_officer_wip_limit) skip their forward-only checks and preserve
    source timestamps. WIP-cap bypass (§4.2.1) lets historical WIP rows land
    above the forward-going cap of 3.
    """
    cur.execute("SET LOCAL app.etl.suppress_bump = 'true'")
    cur.execute("SET LOCAL app.etl.suspend_founder_check = 'true'")
    cur.execute("SET LOCAL app.etl.suspend_captain_decision_check = 'true'")
    cur.execute("SET LOCAL app.etl.suspend_wip_limit = 'true'")
    cur.execute("SET LOCAL app.cabinet_officer = 'cpo-etl'")


# ---------------------------------------------------------------------------
# Officer-email resolution
# ---------------------------------------------------------------------------

def load_officer_emails() -> Dict[str, Dict[str, str]]:
    """Parse instance/config/officer-emails.yml; return dict with keys
    'emails' and 'github_logins', each mapping raw identifier → officer slug.

    Raises FileNotFoundError with a helpful message if the file is absent.
    """
    base = Path(__file__).resolve().parents[3]  # /opt/founders-cabinet
    path = base / "instance" / "config" / "officer-emails.yml"
    if not path.exists():
        raise FileNotFoundError(
            f"officer-emails.yml not found at {path}. "
            "Create it per Spec 039 §5.4 before running the ETL."
        )
    with path.open() as fh:
        data = yaml.safe_load(fh)
    return {
        "emails": data.get("emails") or {},
        "github_logins": data.get("github_logins") or {},
    }


def resolve_assignee(
    raw: Optional[str],
    kind: str,
    mapping: Dict[str, Dict[str, str]],
) -> Tuple[Optional[str], Optional[str]]:
    """Resolve raw assignee identifier to officer slug.

    Args:
        raw: email address (kind='email') or GitHub login (kind='github_login').
        kind: 'email' | 'github_login'
        mapping: result of load_officer_emails()

    Returns:
        (officer_slug, unresolved_raw) — unresolved_raw is None on success,
        the original raw value when the lookup misses.

    Note: caller checks slug == 'captain' and sets founder_action=True.
    """
    if not raw:
        return (None, None)
    lookup = mapping["emails"] if kind == "email" else mapping["github_logins"]
    slug = lookup.get(raw)
    if slug is None:
        return (None, raw)
    return (slug, None)


# ---------------------------------------------------------------------------
# Core upsert
# ---------------------------------------------------------------------------

def upsert_task(conn: Any, row: Dict[str, Any]) -> Tuple[str, int]:
    """INSERT … ON CONFLICT (external_source, external_ref) DO UPDATE SET.

    Opens its own transaction.  Calls set_etl_session_vars before the write.
    Returns ('inserted'|'updated', task_id).
    """
    sql = """
        INSERT INTO officer_tasks (
            officer_slug, title, description, status, blocked, blocked_reason,
            context_slug, priority, type, parent_epic_ref,
            founder_action, due_date, captain_decision, decision_ref,
            external_ref, external_source, pr_url,
            created_at, updated_at, completed_at, cancelled_at
        ) VALUES (
            %(officer_slug)s, %(title)s, %(description)s, %(status)s,
            %(blocked)s, %(blocked_reason)s, %(context_slug)s,
            %(priority)s, %(type)s, %(parent_epic_ref)s,
            %(founder_action)s, %(due_date)s, %(captain_decision)s,
            %(decision_ref)s, %(external_ref)s, %(external_source)s,
            %(pr_url)s, %(created_at)s, %(updated_at)s,
            %(completed_at)s, %(cancelled_at)s
        )
        ON CONFLICT (external_source, external_ref)
        DO UPDATE SET
            officer_slug        = EXCLUDED.officer_slug,
            title               = EXCLUDED.title,
            description         = EXCLUDED.description,
            status              = EXCLUDED.status,
            blocked             = EXCLUDED.blocked,
            blocked_reason      = EXCLUDED.blocked_reason,
            context_slug        = EXCLUDED.context_slug,
            priority            = EXCLUDED.priority,
            type                = EXCLUDED.type,
            parent_epic_ref     = EXCLUDED.parent_epic_ref,
            founder_action      = EXCLUDED.founder_action,
            due_date            = EXCLUDED.due_date,
            captain_decision    = EXCLUDED.captain_decision,
            decision_ref        = EXCLUDED.decision_ref,
            pr_url              = EXCLUDED.pr_url,
            updated_at          = EXCLUDED.updated_at,
            completed_at        = EXCLUDED.completed_at,
            cancelled_at        = EXCLUDED.cancelled_at
        RETURNING id, (xmax = 0) AS inserted
    """
    with conn.cursor() as cur:
        set_etl_session_vars(cur)
        cur.execute(sql, row)
        task_id, was_inserted = cur.fetchone()
    conn.commit()
    op = "inserted" if was_inserted else "updated"
    return (op, task_id)


# ---------------------------------------------------------------------------
# Utility: PR URL extraction
# ---------------------------------------------------------------------------

_PR_RE = re.compile(r"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+")


def extract_pr_url(text: Optional[str]) -> Optional[str]:
    """Return first GitHub PR URL found in text, or None."""
    if not text:
        return None
    m = _PR_RE.search(text)
    return m.group(0) if m else None


# ---------------------------------------------------------------------------
# Log writers
# ---------------------------------------------------------------------------

def _archive_path(suffix: str) -> Path:
    base = Path(__file__).resolve().parents[3]
    today = date.today().strftime("%Y-%m-%d")
    archive_dir = base / "instance" / "archive"
    archive_dir.mkdir(parents=True, exist_ok=True)
    return archive_dir / f"039-etl-{suffix}-{today}.jsonl"


def write_skip_log(entries: List[Dict[str, Any]], path: Optional[Path] = None) -> Path:
    """Write JSONL skip log: {external_ref, reason, raw} per §5.6 drop definition."""
    out = path or _archive_path("skip-log")
    with out.open("a", encoding="utf-8") as fh:
        for entry in entries:
            fh.write(json.dumps(entry, default=str) + "\n")
    return out


def write_unresolved_log(entries: List[Dict[str, Any]], path: Optional[Path] = None) -> Path:
    """Write JSONL unresolved-assignee log: {external_ref, source, raw_identifier} per §5.4."""
    out = path or _archive_path("unresolved")
    with out.open("a", encoding="utf-8") as fh:
        for entry in entries:
            fh.write(json.dumps(entry, default=str) + "\n")
    return out


# ---------------------------------------------------------------------------
# Library archive — JSONL-per-issue snapshot to disk
# ---------------------------------------------------------------------------
# Spec §5.8 (Q_archive=KEEP): raw Linear/GH API response per issue archived
# as a migration snapshot. Full MCP ingestion is deferred — we write one JSON
# file per external_ref under instance/archive/039-migration-snapshots/.
# CoS/CPO ingest these into Library MCP post-ETL via the dashboard once the
# Python-side MCP adapter lands (tracked as FW-* framework item).

def archive_to_library(
    conn: Any,
    source_record: Dict[str, Any],
    dry_run: bool = False,
) -> None:
    """Write one JSON file per source row under instance/archive/039-migration-snapshots/.

    Filename: `<external_source>-<external_ref>.json`. File contains the raw
    source API response as-is. Gated by `ARCHIVE_TO_LIBRARY` env (default
    'true' per spec §5.8 Q_archive=KEEP). Idempotent — overwrites existing
    file so ETL re-runs land the latest snapshot.

    Call AFTER a successful upsert so dry-runs + upsert failures don't leak
    ghost snapshots (PR-3 H-1 review finding).

    conn is currently unused but kept in the signature so a future MCP
    adapter (tracked as FW-* framework item) can swap in without touching
    every caller.
    """
    if dry_run:
        return
    if os.environ.get("ARCHIVE_TO_LIBRARY", "true").lower() != "true":
        return

    ext_ref = source_record.get("external_ref") or source_record.get("id")
    if not ext_ref:
        logger.warning("archive_to_library: source_record has no external_ref or id; skipping")
        return

    ext_source = source_record.get("external_source") or _infer_source(source_record)
    base = Path(__file__).resolve().parents[3]
    archive_dir = base / "instance" / "archive" / "039-migration-snapshots"
    archive_dir.mkdir(parents=True, exist_ok=True)

    # Defensive sanitization — ext_ref values come from trusted APIs (Linear
    # IDs like 'SEN-247', GH refs like 'FW-024') but defense-in-depth blocks
    # path-escape chars + leading dash (flag-injection fence).
    safe_ref = (
        str(ext_ref)
        .replace("/", "_")
        .replace("\\", "_")
        .replace("..", "_")
        .replace("\x00", "_")
        .lstrip("-")
    ) or "unknown"
    out = archive_dir / f"{ext_source}-{safe_ref}.json"
    with out.open("w", encoding="utf-8") as fh:
        json.dump(source_record, fh, default=str, indent=2, sort_keys=True)


def _infer_source(record: Dict[str, Any]) -> str:
    """Best-effort source inference when external_source isn't on the record.

    Linear rows have `identifier` (e.g. 'SEN-42'); GH rows have `html_url`
    containing `github.com`. Defaults to 'unknown' if neither matches.
    """
    if "identifier" in record:
        return "linear"
    url = record.get("html_url") or record.get("url") or ""
    if "github.com" in url:
        return "github-issues"
    return "unknown"
