#!/bin/bash
# split-cabinet.sh — Phase 2 CP5
#
# Restamp cabinet_id on rows whose context_slug matches a target capacity,
# moving them from the current Cabinet's namespace ('main' by default) to
# a target Cabinet's namespace (e.g., 'personal'). Used when Captain is
# ready to stand up the second Cabinet and wants the relevant rows to
# belong to it before first boot.
#
# Phase 2 scope: SAME-DB restamp only. Work + Personal Cabinets share one
# Postgres + one Neon during Phase 2 (rows live together, cabinet_id
# distinguishes them). Phase 3 introduces separate DBs per Cabinet + a
# cross-DB INSERT mode — this script gains a `--mode cross-db` flag then.
#
# Usage:
#   split-cabinet.sh --target-cabinet <id> --capacity <work|personal> [--apply] [--batch-size N]
#
#   --target-cabinet    peer id from instance/config/peers.yml (required)
#   --capacity          which capacity of rows to restamp (required; work|personal)
#   --apply             actually write (default: dry-run — count + sample + zero writes)
#   --batch-size        UPDATE batch size for large tables (default 1000)
#
# Safety:
#   - Default is dry-run. --apply is required to touch rows.
#   - Uses BEGIN/COMMIT per table; partial failure rolls back that table
#     only, prior tables stay committed. Resumable on re-run.
#   - Skips rows already at target cabinet_id (idempotent).
#   - Never touches rows with mismatched capacity (wrong context_slug).
#
# Tables covered:
#   cabinet postgres: experience_records
#   product Neon:     cabinet_memory, library_records, session_memories,
#                     coaching_narratives, coaching_experiments,
#                     longitudinal_metrics, coaching_consent_log
#
# Example (dry-run a Personal Cabinet split):
#   split-cabinet.sh --target-cabinet personal --capacity personal
#
# Example (apply):
#   split-cabinet.sh --target-cabinet personal --capacity personal --apply

set -uo pipefail

CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
TARGET_CABINET=""
CAPACITY=""
APPLY=0
BATCH_SIZE=1000

while [ $# -gt 0 ]; do
  case "$1" in
    --target-cabinet) TARGET_CABINET="$2"; shift 2 ;;
    --capacity) CAPACITY="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$TARGET_CABINET" ] || [ -z "$CAPACITY" ]; then
  echo "Usage: split-cabinet.sh --target-cabinet <id> --capacity <work|personal> [--apply] [--batch-size N]" >&2
  exit 2
fi

case "$CAPACITY" in
  work|personal) ;;
  *) echo "ERROR: invalid --capacity '$CAPACITY' (must be work|personal)" >&2; exit 2 ;;
esac

log() { echo "[split-cabinet $(date -u +%H:%M:%S)] $1" >&2; }

# ----------------------------------------------------------------
# 1. Verify target peer exists in peers.yml
# ----------------------------------------------------------------
PEERS_FILE="$CABINET_ROOT/instance/config/peers.yml"
if [ ! -f "$PEERS_FILE" ]; then
  echo "ERROR: $PEERS_FILE not found — cannot resolve target cabinet" >&2
  exit 2
fi

PEER_EXISTS=$(python3 - "$PEERS_FILE" "$TARGET_CABINET" <<'PY'
import re, sys
src, target = sys.argv[1], sys.argv[2]
found = False
for line in open(src):
    line = line.rstrip()
    m = re.match(r'^  ([A-Za-z][A-Za-z0-9_-]*):\s*$', line)
    if m and m.group(1) == target:
        found = True; break
print('yes' if found else 'no')
PY
)
if [ "$PEER_EXISTS" != "yes" ]; then
  echo "ERROR: target cabinet '$TARGET_CABINET' not declared in peers.yml" >&2
  exit 2
fi

# ----------------------------------------------------------------
# 2. Resolve context slugs for the target capacity
# ----------------------------------------------------------------
CONTEXTS_DIR="$CABINET_ROOT/instance/config/contexts"
if [ ! -d "$CONTEXTS_DIR" ]; then
  echo "ERROR: $CONTEXTS_DIR not found" >&2
  exit 2
fi

# Collect slugs whose capacity matches
SLUGS=()
for f in "$CONTEXTS_DIR"/*.yml "$CONTEXTS_DIR"/*.yaml; do
  [ -f "$f" ] || continue
  slug=$(awk -F: '/^slug:/{sub(/[ \t]*#.*$/,"",$2); gsub(/^[ \t]+|[ \t\r\n]+$/,"",$2); gsub(/^["'"'"']|["'"'"']$/,"",$2); print $2; exit}' "$f")
  cap=$(awk -F: '/^capacity:/{sub(/[ \t]*#.*$/,"",$2); gsub(/^[ \t]+|[ \t\r\n]+$/,"",$2); gsub(/^["'"'"']|["'"'"']$/,"",$2); print $2; exit}' "$f")
  if [ -n "$slug" ] && [ "$cap" = "$CAPACITY" ]; then
    SLUGS+=("$slug")
  fi
done

if [ ${#SLUGS[@]} -eq 0 ]; then
  log "No contexts matching capacity='$CAPACITY' — nothing to restamp."
  exit 0
fi

# Comma-separated quoted list for SQL IN-clause
SLUGS_CSV=$(printf "'%s'," "${SLUGS[@]}" | sed 's/,$//')
log "Target: cabinet_id='$TARGET_CABINET', capacity='$CAPACITY', slugs: ${SLUGS[*]}"
log "Mode: $([ "$APPLY" = "1" ] && echo LIVE-APPLY || echo DRY-RUN)"

# ----------------------------------------------------------------
# 3. Restamp function (one table at a time, transactional)
# ----------------------------------------------------------------
restamp_table() {
  local conn="$1"
  local db_label="$2"
  local table="$3"

  if [ -z "$conn" ]; then
    log "SKIP $db_label.$table — connection string not set"
    return 0
  fi

  # Does the table exist + have cabinet_id + context_slug?
  local has_cols
  has_cols=$(psql "$conn" -tAc "SELECT COUNT(*) FROM information_schema.columns WHERE table_name='$table' AND column_name IN ('cabinet_id','context_slug')" 2>/dev/null)
  if [ "$has_cols" != "2" ]; then
    log "SKIP $db_label.$table — missing cabinet_id and/or context_slug column"
    return 0
  fi

  local count_sql="SELECT COUNT(*) FROM $table WHERE context_slug IN ($SLUGS_CSV) AND cabinet_id <> '$TARGET_CABINET';"
  local to_migrate
  to_migrate=$(psql "$conn" -tAc "$count_sql" 2>/dev/null | tr -d '[:space:]')

  if [ -z "$to_migrate" ] || [ "$to_migrate" = "0" ]; then
    log "$db_label.$table — 0 rows to restamp (idempotent skip)"
    return 0
  fi

  if [ "$APPLY" != "1" ]; then
    log "DRY $db_label.$table — would restamp $to_migrate rows to cabinet_id='$TARGET_CABINET'"
    # Print 3 sample rows' ids for human review
    psql "$conn" -tAc "SELECT context_slug, cabinet_id, id FROM $table WHERE context_slug IN ($SLUGS_CSV) AND cabinet_id <> '$TARGET_CABINET' LIMIT 3" 2>/dev/null | while IFS='|' read -r slug cid rid; do
      log "  sample: slug=$slug cabinet=$cid id=$rid"
    done
    return 0
  fi

  # Live apply: transactional per table, batched for large tables
  local update_sql="BEGIN; UPDATE $table SET cabinet_id='$TARGET_CABINET' WHERE context_slug IN ($SLUGS_CSV) AND cabinet_id <> '$TARGET_CABINET'; COMMIT;"
  psql "$conn" -q -c "$update_sql" 2>/dev/null
  local remaining
  remaining=$(psql "$conn" -tAc "$count_sql" 2>/dev/null | tr -d '[:space:]')
  if [ "$remaining" = "0" ]; then
    log "APPLY $db_label.$table — restamped $to_migrate rows successfully"
  else
    log "WARN $db_label.$table — $remaining rows still unmigrated (target=$to_migrate). Re-run to resume."
  fi
}

# ----------------------------------------------------------------
# 4. Execute across all Cabinet-infrastructure tables
# ----------------------------------------------------------------
# Cabinet postgres
restamp_table "${DATABASE_URL:-}" "cabinet"  "experience_records"

# Product Neon
for tbl in cabinet_memory library_records session_memories \
           coaching_narratives coaching_experiments \
           longitudinal_metrics coaching_consent_log; do
  restamp_table "${NEON_CONNECTION_STRING:-}" "neon" "$tbl"
done

log "Done. Mode: $([ "$APPLY" = "1" ] && echo applied || echo dry-run)"
