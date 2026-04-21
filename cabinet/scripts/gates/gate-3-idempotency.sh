#!/usr/bin/env bash
# cabinet/scripts/gates/gate-3-idempotency.sh — Spec 039 Phase A Gate 3 wrapper.
# Thin wrapper around gate-3-idempotency.py: verifies env presence, selects
# conn string (staging vs prod), dispatches to Python, surfaces exit code.
#
# Usage:
#   bash gate-3-idempotency.sh [--staging]
#
# Preconditions:
#   - Gate 1 ETL has already run on the target DB (so rows exist to re-hash)
#   - LINEAR_API_KEY + GITHUB_PAT set (the re-run invocation needs them)
#   - Python deps installed: pip3 install psycopg2-binary requests pyyaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATES_PY="$SCRIPT_DIR/gate-3-idempotency.py"
ETL_SH="$(dirname "$SCRIPT_DIR")/migrate-sources-to-officer-tasks.sh"
LOG_PREFIX="[gate-3-idempotency]"

USE_STAGING=false
USE_PROD=false
for arg in "$@"; do
  case "$arg" in
    --staging) USE_STAGING=true ;;
    --prod)    USE_PROD=true ;;
  esac
done

if [[ "$USE_STAGING" == "false" && "$USE_PROD" == "false" ]]; then
  echo "$LOG_PREFIX ERROR: must pass --staging or --prod explicitly (no default — Gate 3 re-runs the full ETL)" >&2
  exit 1
fi
if [[ "$USE_STAGING" == "true" && "$USE_PROD" == "true" ]]; then
  echo "$LOG_PREFIX ERROR: cannot pass both --staging and --prod" >&2
  exit 1
fi

if [[ "$USE_STAGING" == "true" ]]; then
  if [[ -z "${NEON_STAGING_CONNECTION_STRING:-}" ]]; then
    echo "$LOG_PREFIX ERROR: --staging passed but NEON_STAGING_CONNECTION_STRING is unset" >&2
    exit 1
  fi
  CONN="$NEON_STAGING_CONNECTION_STRING"
  echo "$LOG_PREFIX Using staging DB"
else
  CONN="${NEON_CONNECTION_STRING:-}"
  if [[ -z "$CONN" ]]; then
    echo "$LOG_PREFIX ERROR: --prod passed but NEON_CONNECTION_STRING is unset" >&2
    exit 1
  fi
  # Extract host from postgresql://user:pass@host/... for the confirmation prompt.
  HOST=$(echo "$CONN" | sed -E 's|^[a-z]+://[^@]+@([^:/?]+).*|\1|' 2>/dev/null || echo "<unparsed>")
  echo "$LOG_PREFIX WARNING: --prod selected. Target DB host: $HOST" >&2
  echo "$LOG_PREFIX Gate 3 will run a full ETL re-upsert against PRODUCTION officer_tasks." >&2
  echo "$LOG_PREFIX Type 'yes, run gate 3 on prod' to proceed (anything else aborts):" >&2
  read -r confirm
  if [[ "$confirm" != "yes, run gate 3 on prod" ]]; then
    echo "$LOG_PREFIX Aborted by operator." >&2
    exit 1
  fi
fi

: "${LINEAR_API_KEY:?LINEAR_API_KEY must be set — Gate 3 triggers an ETL re-run}"
: "${GITHUB_PAT:?GITHUB_PAT must be set — Gate 3 triggers an ETL re-run}"

echo "$LOG_PREFIX (NEON_CONNECTION_STRING: set)" >&2
echo "$LOG_PREFIX (LINEAR_API_KEY: set)" >&2
echo "$LOG_PREFIX (GITHUB_PAT: set)" >&2

export CONN
PY_FLAGS=""
[[ "$USE_STAGING" == "true" ]] && PY_FLAGS="--staging"

echo "$LOG_PREFIX Dispatching to gate-3-idempotency.py..."
python3 "$GATES_PY" --etl-script "$ETL_SH" $PY_FLAGS
echo "$LOG_PREFIX Gate 3 check complete."
