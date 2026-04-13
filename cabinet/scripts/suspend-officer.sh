#!/bin/bash
# suspend-officer.sh — Gracefully suspend an officer with structured exit record
# Archives state for potential re-hire. Does NOT delete anything.
#
# Usage: suspend-officer.sh <officer> "<reason>"
# Example: suspend-officer.sh cro "Consolidating research into CPO role"

set -uo pipefail

OFFICER="${1:?Usage: suspend-officer.sh <officer> \"<reason>\"}"
REASON="${2:?Usage: suspend-officer.sh <officer> \"<reason>\"}"

CABINET_ROOT="/opt/founders-cabinet"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
WINDOW="officer-$OFFICER"

log() { echo "[suspend-officer] $1"; }

log "Suspending officer: $OFFICER"
log "Reason: $REASON"
log ""

# === Step 1: Create structured exit record ===
TIER2_DIR="$CABINET_ROOT/memory/tier2/$OFFICER"
mkdir -p "$TIER2_DIR"
EXIT_RECORD="$TIER2_DIR/.exit-record.md"

# Gather metrics
TOOL_CALLS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:toolcalls:$OFFICER" 2>/dev/null || echo "?")
RECORDS_TODAY=$(ls "$CABINET_ROOT/memory/tier3/experience-records/$(date -u +%Y-%m-%d)-${OFFICER}-"*.md 2>/dev/null | wc -l)
TOTAL_RECORDS=$(ls "$CABINET_ROOT/memory/tier3/experience-records/"*"-${OFFICER}-"*.md 2>/dev/null | wc -l)

cat > "$EXIT_RECORD" << EXITEOF
# Officer Exit Record — ${OFFICER^^}
**Suspended:** $TIMESTAMP
**Reason:** $REASON
**Suspended by:** ${OFFICER_NAME:-cos}

## Metrics at Suspension
- Tool calls (current session): ${TOOL_CALLS}
- Experience records today: ${RECORDS_TODAY}
- Total experience records: ${TOTAL_RECORDS}

## Working State
$(cat "$TIER2_DIR/working-notes.md" 2>/dev/null | tail -30 || echo "No working notes found.")

## Recommendations for Re-hire
- Re-read this exit record to understand why the role was suspended
- Check if the reason still applies before reactivating
- Review experience records for lessons learned: memory/tier3/experience-records/*-${OFFICER}-*

## In-Progress Work
- Check Linear for issues assigned to or created by this officer
- Check shared/interfaces/ for artifacts this officer maintained
EXITEOF
log "Created exit record: $EXIT_RECORD"

# === Step 2: Mark as suspended in Redis ===
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:officer:expected:$OFFICER" "suspended" > /dev/null 2>&1
log "Marked as suspended in Redis"

# === Step 3: Kill the tmux window gracefully ===
if tmux list-windows -t cabinet -F '#{window_name}' 2>/dev/null | grep -q "^${WINDOW}$"; then
  tmux kill-window -t "cabinet:$WINDOW" 2>/dev/null
  log "Killed tmux window: $WINDOW"
else
  log "No tmux window found (already stopped)"
fi

# === Step 4: Notify remaining officers ===
source "$CABINET_ROOT/cabinet/scripts/lib/triggers.sh" 2>/dev/null
for other in $(ls "$CABINET_ROOT/memory/tier2/" 2>/dev/null); do
  [ "$other" = "$OFFICER" ] && continue
  EXPECTED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:officer:expected:$other" 2>/dev/null)
  [ "$EXPECTED" = "active" ] && OFFICER_NAME=supervisor trigger_send "$other" "OFFICER SUSPENDED: ${OFFICER^^} has been suspended. Reason: $REASON. Check if any of their work needs handoff."
done

# === Step 5: Announce ===
if [ -n "${TELEGRAM_HQ_CHAT_ID:-}" ]; then
  bash "$CABINET_ROOT/cabinet/scripts/send-to-group.sh" "<b>Officer suspended: ${OFFICER^^}</b>
Reason: $REASON
Status: Archived (can be re-hired later)" 2>/dev/null || true
fi

log ""
log "=========================================="
log " Officer ${OFFICER^^} suspended"
log "=========================================="
log ""
log "Exit record:   $EXIT_RECORD"
log "Redis status:  suspended"
log "Tier2 notes:   preserved at $TIER2_DIR/"
log "Experience:    preserved in memory/tier3/experience-records/"
log ""
log "To re-hire: bash $CABINET_ROOT/cabinet/scripts/resume-officer.sh $OFFICER"
