#!/bin/bash
# backfill-context-slug.sh — Assign context_slug to legacy rows.
#
# Phase 1 CP2 (Captain 2026-04-16). All records written before CP1 landed
# have NULL context_slug. This script backfills them with a default slug
# derived from the active-project config (typically 'sensed').
#
# Safe to re-run. Only touches rows where context_slug IS NULL. Does NOT
# overwrite any row that already has a slug.
#
# Usage:
#   bash cabinet/scripts/backfill-context-slug.sh [--slug <slug>] [--dry-run]
#
# Defaults:
#   --slug = active-project slug from instance/config/active-project.txt
#   --dry-run off (applies the update)
#
# Tables touched:
#   cabinet postgres : experience_records
#   product Neon     : cabinet_memory, library_records

set -uo pipefail

CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
SLUG_ARG=""
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --slug) SLUG_ARG="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$SLUG_ARG" ]; then
  DEFAULT_SLUG="$SLUG_ARG"
else
  DEFAULT_SLUG=$(cat "$CABINET_ROOT/instance/config/active-project.txt" 2>/dev/null | tr -d '[:space:]')
  DEFAULT_SLUG="${DEFAULT_SLUG:-sensed}"
fi

# Verify the slug exists in contexts yaml
SLUG_FILE="$CABINET_ROOT/instance/config/contexts/${DEFAULT_SLUG}.yml"
if [ ! -f "$SLUG_FILE" ]; then
  echo "ERROR: no yaml for slug '$DEFAULT_SLUG' at $SLUG_FILE" >&2
  echo "Known slugs: $(ls "$CABINET_ROOT/instance/config/contexts/"*.yml 2>/dev/null | xargs -n1 basename | sed 's/\.yml$//' | tr '\n' ' ')" >&2
  exit 2
fi

log() { echo "[backfill-context-slug $(date -u +%H:%M:%S)] $1" >&2; }

run_update() {
  local conn="$1"
  local db_label="$2"
  local table="$3"

  if [ -z "$conn" ]; then
    log "SKIP $db_label.$table — connection string not set"
    return 0
  fi

  local sql_count="SELECT COUNT(*) FROM $table WHERE context_slug IS NULL;"
  local sql_update="UPDATE $table SET context_slug = '$DEFAULT_SLUG' WHERE context_slug IS NULL;"

  local before
  before=$(psql "$conn" -tAc "$sql_count" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$before" ]; then
    log "WARN $db_label.$table — could not count (table missing? column missing?)"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY $db_label.$table — would set $before rows to context_slug='$DEFAULT_SLUG'"
  else
    psql "$conn" -q -c "$sql_update" > /dev/null 2>&1
    local after
    after=$(psql "$conn" -tAc "$sql_count" 2>/dev/null | tr -d '[:space:]')
    log "$db_label.$table — backfilled $before rows (remaining NULL: $after)"
  fi
}

log "Slug: $DEFAULT_SLUG (dry-run=$DRY_RUN)"

run_update "${DATABASE_URL:-}"            "cabinet"  "experience_records"
run_update "${NEON_CONNECTION_STRING:-}"  "neon"     "cabinet_memory"
run_update "${NEON_CONNECTION_STRING:-}"  "neon"     "library_records"

log "Done."
