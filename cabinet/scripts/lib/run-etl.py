#!/usr/bin/env python3
# cabinet/scripts/lib/run-etl.py — Spec 039 Phase A Python ETL entry point.
# Acquires advisory lock, runs requested track(s), releases lock.
# Called by migrate-sources-to-officer-tasks.sh; not invoked directly.
#
# Dependencies: psycopg2-binary, requests, PyYAML
#   install: pip3 install psycopg2-binary requests pyyaml

from __future__ import annotations

import argparse
import logging
import os
import sys
from pathlib import Path

# Module imports — etl-common.py has a hyphen, requires importlib.
sys.path.insert(0, str(Path(__file__).parent))
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location("etl_common", Path(__file__).parent / "etl-common.py")
common = _ilu.module_from_spec(_spec)  # type: ignore[arg-type]
_spec.loader.exec_module(common)  # type: ignore[union-attr]

logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("run-etl")


def _assert_reconcile(track: str, result: dict) -> None:
    """Spec §5.5 step 5: per-track arithmetic invariant on ETL counters.

    Every extracted row must be accounted for as inserted, updated, or skipped.
    Raises AssertionError on mismatch so the bash wrapper's `set -e` aborts the
    run with a non-zero exit (preferable to silently drifting counts).
    """
    extracted = result["issues_extracted"] + result.get("projects_extracted", 0)
    handled = result["inserted"] + result["updated"] + result["skipped"]
    if extracted != handled:
        raise AssertionError(
            f"{track} ETL reconcile FAILED: extracted={extracted} "
            f"inserted={result['inserted']} updated={result['updated']} "
            f"skipped={result['skipped']} (sum={handled}). "
            "Every source row must be accounted for per spec §5.5 step 5."
        )
    logger.info(
        "%s ETL reconcile OK: extracted=%d == inserted+updated+skipped=%d",
        track, extracted, handled,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Spec 039 ETL runner")
    parser.add_argument("--track", choices=["linear", "github", "both"], default="both")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    conn_str = os.environ.get("CONN") or os.environ.get("NEON_CONNECTION_STRING")
    if not conn_str:
        logger.error("CONN or NEON_CONNECTION_STRING env var is required")
        sys.exit(1)

    conn = common.get_db_connection(conn_str)
    common.register_signal_handlers(conn)

    try:
        common.acquire_advisory_lock(conn)

        if args.track in ("linear", "both"):
            _lspec = _ilu.spec_from_file_location(
                "etl_linear", Path(__file__).parent / "etl-linear.py"
            )
            etl_linear = _ilu.module_from_spec(_lspec)  # type: ignore[arg-type]
            _lspec.loader.exec_module(etl_linear)  # type: ignore[union-attr]
            result = etl_linear.run_linear_etl(conn, dry_run=args.dry_run)
            _assert_reconcile("linear", result)
            logger.info(
                "Linear ETL done — inserted=%d updated=%d skipped=%d "
                "unresolved=%d projects=%d issues=%d",
                result["inserted"], result["updated"], result["skipped"],
                len(result["unresolved"]), result["projects_extracted"],
                result["issues_extracted"],
            )

        if args.track in ("github", "both"):
            _gspec = _ilu.spec_from_file_location(
                "etl_github", Path(__file__).parent / "etl-github.py"
            )
            etl_github = _ilu.module_from_spec(_gspec)  # type: ignore[arg-type]
            _gspec.loader.exec_module(etl_github)  # type: ignore[union-attr]
            result = etl_github.run_github_etl(conn, dry_run=args.dry_run)
            _assert_reconcile("github", result)
            logger.info(
                "GitHub ETL done — inserted=%d updated=%d skipped=%d "
                "unresolved=%d issues=%d",
                result["inserted"], result["updated"], result["skipped"],
                len(result["unresolved"]), result["issues_extracted"],
            )

    finally:
        common.release_advisory_lock(conn)
        conn.close()


if __name__ == "__main__":
    main()
