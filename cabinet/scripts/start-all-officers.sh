#!/bin/bash
# start-all-officers.sh — Start all officers with rate-limit-safe pacing
#
# Use this for cold start (server reboot, container recreate) so all five
# officers don't hammer the Anthropic API simultaneously and trip rate limits.
# Each officer's startup includes role definition reads, skill reads, tier 2
# memory reads, and the boot prompt — that's a lot of input tokens per officer.
#
# Usage:
#   start-all-officers.sh                # default: 120s gap between officers
#   start-all-officers.sh 60             # custom gap in seconds
#   start-all-officers.sh 0 cto cpo      # no gap, only specified officers
#
# Defaults:
#   - Gap:      120 seconds (2 min) — empirically rate-limit-safe for the
#               5-officer fleet on Opus with default rate limits.
#   - Officers: cos cto cpo cro coo (in that order — CoS first so it can
#               coordinate, then the rest can follow its lead).
#
# For single-officer restarts during the day, use start-officer.sh directly
# (no pacing needed when only one officer is starting).

set -e

CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"

# First positional arg is the gap in seconds; rest are officer abbreviations.
GAP="${1:-120}"
shift 2>/dev/null || true
OFFICERS=("$@")
if [ ${#OFFICERS[@]} -eq 0 ]; then
  OFFICERS=(cos cto cpo cro coo)
fi

# Source env so TELEGRAM_*_TOKEN vars are available to start-officer.sh
if [ -f "$CABINET_ROOT/cabinet/.env" ]; then
  set -a; source "$CABINET_ROOT/cabinet/.env" 2>/dev/null; set +a
fi
ACTIVE_SLUG=$(cat "$CABINET_ROOT/instance/config/active-project.txt" 2>/dev/null | tr -d '[:space:]')
if [ -n "$ACTIVE_SLUG" ] && [ -f "$CABINET_ROOT/cabinet/env/${ACTIVE_SLUG}.env" ]; then
  set -a; source "$CABINET_ROOT/cabinet/env/${ACTIVE_SLUG}.env" 2>/dev/null; set +a
fi

echo "[start-all] Starting ${#OFFICERS[@]} officers with ${GAP}s pacing: ${OFFICERS[*]}"

count=${#OFFICERS[@]}
i=0
for officer in "${OFFICERS[@]}"; do
  i=$((i + 1))
  echo "[start-all] ($i/$count) Starting $officer..."
  bash "$CABINET_ROOT/cabinet/scripts/start-officer.sh" "$officer"

  # No gap after the last officer
  if [ "$i" -lt "$count" ] && [ "$GAP" -gt 0 ]; then
    echo "[start-all] Waiting ${GAP}s before next officer (rate-limit pacing)..."
    sleep "$GAP"
  fi
done

echo "[start-all] All ${count} officers started."
