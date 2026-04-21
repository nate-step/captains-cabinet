#!/usr/bin/env bash
# cabinet/scripts/migrate-sources-to-officer-tasks.sh — Spec 039 Phase A orchestrator.
# Runs preflight, acquires advisory lock, dispatches Linear + GH Python ETL modules,
# runs postflight, releases lock.
#
# Usage:
#   bash migrate-sources-to-officer-tasks.sh [--dry-run] [--track linear|github|both] [--staging]
#
# Dependencies (Python): psycopg2-binary, requests, PyYAML
#   Install: pip3 install psycopg2-binary requests pyyaml
#
# Required env vars:
#   NEON_CONNECTION_STRING   — Cabinet Postgres (production)
#   LINEAR_API_KEY           — Linear API key (Track A1 only)
#   GITHUB_PAT               — GitHub personal access token (Track A2 only)
# Optional env vars:
#   NEON_STAGING_CONNECTION_STRING — staging DB; falls back to NEON_CONNECTION_STRING

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
LOG_PREFIX="[migrate-sources-to-officer-tasks]"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=false
TRACK="both"
USE_STAGING=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --staging)   USE_STAGING=true ;;
    --track)     ;;  # handled by next-arg logic below
    linear|github|both) TRACK="$arg" ;;
  esac
done

# Capture --track <value> explicitly
i=1
for arg in "$@"; do
  if [[ "$arg" == "--track" ]]; then
    next="${@:$((i+1)):1}"
    [[ -n "$next" ]] && TRACK="$next"
  fi
  ((i++)) || true
done

echo "$LOG_PREFIX DRY_RUN=$DRY_RUN TRACK=$TRACK USE_STAGING=$USE_STAGING"

# ---------------------------------------------------------------------------
# Connection string selection
# ---------------------------------------------------------------------------
if [[ "$USE_STAGING" == "true" ]]; then
  if [[ -z "${NEON_STAGING_CONNECTION_STRING:-}" ]]; then
    echo "$LOG_PREFIX WARNING: --staging passed but NEON_STAGING_CONNECTION_STRING is unset — falling back to NEON_CONNECTION_STRING (production)" >&2
    echo "$LOG_PREFIX If you intended to run against staging, set NEON_STAGING_CONNECTION_STRING and re-run." >&2
  fi
  CONN="${NEON_STAGING_CONNECTION_STRING:-${NEON_CONNECTION_STRING:-}}"
  echo "$LOG_PREFIX Using staging DB"
else
  CONN="${NEON_CONNECTION_STRING:-}"
fi

if [[ -z "$CONN" ]]; then
  echo "$LOG_PREFIX ERROR: NEON_CONNECTION_STRING is not set" >&2
  exit 1
fi

# Presence-only log — never print value
echo "$LOG_PREFIX (NEON_CONNECTION_STRING: set)" >&2
export CONN  # exported so embedded Python heredocs can read it

# ---------------------------------------------------------------------------
# Preflight: verify Spec 039 schema is applied (column existence)
# ---------------------------------------------------------------------------
echo "$LOG_PREFIX Running preflight schema check..."
python3 - <<PYEOF
import sys, os
try:
    import psycopg2
except ImportError:
    print("ERROR: psycopg2 not installed. Run: pip3 install psycopg2-binary", file=sys.stderr)
    sys.exit(1)

conn_str = os.environ["CONN"]
try:
    conn = psycopg2.connect(conn_str)
except Exception as e:
    print(f"ERROR: cannot connect to DB: {e}", file=sys.stderr)
    sys.exit(1)

required_cols = [
    "priority", "type", "parent_epic_ref", "founder_action",
    "due_date", "captain_decision", "decision_ref",
    "external_ref", "external_source", "pr_url", "cancelled_at",
]
with conn.cursor() as cur:
    cur.execute("""
        SELECT column_name FROM information_schema.columns
        WHERE table_name = 'officer_tasks'
    """)
    existing = {row[0] for row in cur.fetchall()}

missing = [c for c in required_cols if c not in existing]
if missing:
    print(f"ERROR: Spec 039 schema not applied. Missing columns: {missing}", file=sys.stderr)
    print("Apply cabinet/sql/039-linear-to-tasks-schema.sql first.", file=sys.stderr)
    sys.exit(1)

print("[preflight] All 11 Spec 039 columns present. Schema OK.")
conn.close()
PYEOF

# ---------------------------------------------------------------------------
# Preflight: warn if ETL ran recently (<24h)
# ---------------------------------------------------------------------------
STAMP_KEY="cabinet:migration:039:last-etl-run"
if command -v redis-cli &>/dev/null; then
  LAST_RUN=$(redis-cli -h redis -p 6379 GET "$STAMP_KEY" 2>/dev/null || true)
  if [[ -n "$LAST_RUN" ]]; then
    echo "$LOG_PREFIX WARNING: ETL last ran at $LAST_RUN (idempotent re-run OK, but flagging)"
  fi
fi

# ---------------------------------------------------------------------------
# Build Python invocation flags
# ---------------------------------------------------------------------------
PY_FLAGS=""
[[ "$DRY_RUN" == "true" ]] && PY_FLAGS="--dry-run"

# ---------------------------------------------------------------------------
# Dispatch to Python ETL runner (acquires advisory lock internally)
# Tracks run sequentially inside run-etl.py; advisory lock held for whole run.
# ---------------------------------------------------------------------------
echo "$LOG_PREFIX Dispatching to Python ETL runner (track=$TRACK)..."
python3 "$LIB_DIR/run-etl.py" --track "$TRACK" $PY_FLAGS
echo "$LOG_PREFIX ETL runner returned."

# ---------------------------------------------------------------------------
# Postflight: row-count summary
# ---------------------------------------------------------------------------
echo "$LOG_PREFIX Running postflight assertions..."
python3 - <<PYEOF
import sys, os
import psycopg2

conn_str = os.environ["CONN"]
conn = psycopg2.connect(conn_str)
with conn.cursor() as cur:
    cur.execute("""
        SELECT external_source, COUNT(*) AS total,
               COUNT(*) FILTER (WHERE status = 'cancelled') AS cancelled
        FROM officer_tasks
        WHERE external_source IN ('linear','github-issues')
        GROUP BY external_source
    """)
    rows = cur.fetchall()

print("[postflight] officer_tasks counts by source:")
for source, total, cancelled in rows:
    active = total - cancelled
    print(f"  {source}: {total} total, {active} active (non-cancelled), {cancelled} cancelled")

# Founder-action without due_date report
with conn.cursor() as cur:
    cur.execute("""
        SELECT COUNT(*) FROM officer_tasks
        WHERE founder_action = TRUE
          AND status IN ('queue','wip')
          AND NOT blocked
          AND due_date IS NULL
          AND external_source IN ('linear','github-issues')
    """)
    fa_no_due = cur.fetchone()[0]
if fa_no_due > 0:
    print(f"[postflight] WARNING: {fa_no_due} forward-going founder_action rows missing due_date — CoS triage required")

# Captain-decision without decision_ref report
with conn.cursor() as cur:
    cur.execute("""
        SELECT COUNT(*) FROM officer_tasks
        WHERE captain_decision = TRUE
          AND decision_ref IS NULL
          AND external_source IN ('linear','github-issues')
    """)
    cd_no_ref = cur.fetchone()[0]
if cd_no_ref > 0:
    print(f"[postflight] INFO: {cd_no_ref} captain_decision rows without decision_ref — CoS/CPO backfill required")

conn.close()
PYEOF

# ---------------------------------------------------------------------------
# Stamp last-run timestamp
# ---------------------------------------------------------------------------
if command -v redis-cli &>/dev/null; then
  redis-cli -h redis -p 6379 SET "$STAMP_KEY" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1 || true
fi

echo "$LOG_PREFIX ETL orchestration complete."
