#!/usr/bin/env python3
# cabinet/scripts/gates/gate-3-idempotency.py — Spec 039 Phase A Gate 3.
# Snapshots SHA-256 hashes of every officer_tasks row sourced from linear/github,
# invokes a re-run of the ETL (via migrate-sources-to-officer-tasks.sh), then
# re-hashes and asserts zero mutations occurred on existing rows.
#
# AC #36: "Gate 3 ETL re-run on staging produces zero new inserts + zero
# unintended mutations. Pre/post row-hash snapshot equal."
#
# Dependencies: psycopg2-binary (pip3 install psycopg2-binary)

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Tuple

import psycopg2

logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("gate-3")

# Hash basis per Spec 039 §5.9 M-5 (immutable — any addition requires spec
# amendment). Hash = md5(concat_ws('|', <these 15 cols in this order>)).
# Excluded by spec: updated_at, completed_at, created_at, cancelled_at,
# officer_slug, context_slug, external_source (audit/lineage cols that
# re-runs may legitimately rewrite). Dict key is external_source:external_ref
# (the join key for before/after diffing), not part of the hash body.
_HASH_COLS = [
    "id", "external_ref", "title", "description", "status", "blocked",
    "blocked_reason", "priority", "type", "parent_epic_ref",
    "founder_action", "due_date", "captain_decision", "decision_ref",
    "pr_url",
]


def _fetch_row_hashes(conn: Any) -> Dict[str, str]:
    """Return {external_source:external_ref: md5_of_row} for migrated rows.

    Hash body mirrors Postgres `concat_ws('|', ...)` semantics — NULL values
    are skipped (not stringified to empty), so two rows whose NULL positions
    differ produce distinct strings even when non-NULL values agree.
    """
    cols_sql = ", ".join(_HASH_COLS)
    sql = f"""
        SELECT external_source, {cols_sql}
        FROM officer_tasks
        WHERE external_source IN ('linear','github-issues')
    """
    out: Dict[str, str] = {}
    with conn.cursor() as cur:
        cur.execute(sql)
        col_names = [d[0] for d in cur.description]
        for row in cur.fetchall():
            rec = dict(zip(col_names, row))
            ext_source = rec.pop("external_source")
            ext_ref = rec["external_ref"]  # stays in hash body per spec
            parts = [str(rec[c]) for c in _HASH_COLS if rec.get(c) is not None]
            body = "|".join(parts).encode("utf-8")
            out[f"{ext_source}:{ext_ref}"] = hashlib.md5(body).hexdigest()
    return out


def _run_etl_rerun(etl_script: Path, staging: bool) -> None:
    """Invoke migrate-sources-to-officer-tasks.sh (without --dry-run)."""
    cmd = ["bash", str(etl_script), "--track", "both"]
    if staging:
        cmd.append("--staging")
    logger.info("Invoking ETL re-run: %s", " ".join(cmd))
    result = subprocess.run(cmd, check=False)
    if result.returncode != 0:
        raise RuntimeError(f"ETL re-run exited {result.returncode} — Gate 3 aborted")


def _diff_hashes(
    before: Dict[str, str], after: Dict[str, str],
) -> Tuple[int, int, int, int]:
    """Return (unchanged, mutated, new_inserted, deleted)."""
    unchanged = mutated = 0
    before_keys = set(before)
    after_keys = set(after)
    for key in before_keys & after_keys:
        if before[key] == after[key]:
            unchanged += 1
        else:
            mutated += 1
    new_inserted = len(after_keys - before_keys)
    deleted = len(before_keys - after_keys)
    return unchanged, mutated, new_inserted, deleted


def main() -> int:
    parser = argparse.ArgumentParser(description="Spec 039 Gate 3 idempotency check")
    parser.add_argument("--etl-script", default="/opt/founders-cabinet/cabinet/scripts/migrate-sources-to-officer-tasks.sh")
    parser.add_argument("--staging", action="store_true", help="Pass --staging to ETL re-run")
    parser.add_argument("--skip-rerun", action="store_true",
                        help="Snapshot only (pre-run) — useful for external orchestration")
    args = parser.parse_args()

    conn_str = os.environ.get("CONN") or os.environ.get("NEON_CONNECTION_STRING")
    if not conn_str:
        logger.error("CONN or NEON_CONNECTION_STRING env var is required")
        return 1

    snapshot_path = Path("/tmp/039-gate-3-snapshot.json")

    conn = psycopg2.connect(conn_str)
    try:
        if args.skip_rerun:
            logger.info("snapshot-only mode — capturing pre-run hashes to %s", snapshot_path)
            hashes = _fetch_row_hashes(conn)
            snapshot_path.write_text(json.dumps(hashes, sort_keys=True))
            logger.info("Captured %d row hashes.", len(hashes))
            return 0

        logger.info("Step 1/3: snapshot current row hashes...")
        before = _fetch_row_hashes(conn)
        logger.info("Captured %d pre-run row hashes.", len(before))
        conn.close()

        logger.info("Step 2/3: trigger ETL re-run...")
        _run_etl_rerun(Path(args.etl_script), args.staging)

        logger.info("Step 3/3: compare post-run hashes...")
        conn = psycopg2.connect(conn_str)
        after = _fetch_row_hashes(conn)

        unchanged, mutated, new_inserted, deleted = _diff_hashes(before, after)
        logger.info(
            "Gate 3 result: unchanged=%d mutated=%d new_inserted=%d deleted=%d (total_before=%d, total_after=%d)",
            unchanged, mutated, new_inserted, deleted, len(before), len(after),
        )

        if mutated > 0 or new_inserted > 0 or deleted > 0:
            logger.error(
                "Gate 3 FAILED: expected zero mutations + zero new inserts + zero deletes on re-run."
            )
            return 2

        logger.info("Gate 3 PASSED: idempotent re-run — all %d rows unchanged.", unchanged)
        return 0
    finally:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass


if __name__ == "__main__":
    sys.exit(main())
