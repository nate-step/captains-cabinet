#!/bin/bash
# resume-officer.sh — Re-hire a suspended officer
# Restores state and starts the officer session.
#
# Usage: resume-officer.sh <officer>
# Example: resume-officer.sh cro

set -uo pipefail

OFFICER="${1:?Usage: resume-officer.sh <officer>}"

CABINET_ROOT="/opt/founders-cabinet"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

log() { echo "[resume-officer] $1"; }

# === Verify officer was suspended ===
STATUS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:officer:expected:$OFFICER" 2>/dev/null)
if [ "$STATUS" != "suspended" ]; then
  log "WARNING: Officer $OFFICER is not suspended (status: ${STATUS:-unknown}). Continuing anyway."
fi

# === Check exit record ===
EXIT_RECORD="$CABINET_ROOT/instance/memory/tier2/$OFFICER/.exit-record.md"
if [ -f "$EXIT_RECORD" ]; then
  log "Exit record found. Reason for suspension:"
  grep "^**Reason:**" "$EXIT_RECORD" 2>/dev/null || echo "  (no reason recorded)"
  log ""
fi

# === Verify required files exist ===
ROLE_FILE="$CABINET_ROOT/.claude/agents/$OFFICER.md"
TIER2_DIR="$CABINET_ROOT/instance/memory/tier2/$OFFICER"
SKILLS_FILE="$CABINET_ROOT/cabinet/officer-skills/$OFFICER.txt"

MISSING=false
[ ! -f "$ROLE_FILE" ] && log "ERROR: Role definition missing: $ROLE_FILE" && MISSING=true
[ ! -d "$TIER2_DIR" ] && log "ERROR: Tier2 directory missing: $TIER2_DIR" && MISSING=true

if [ "$MISSING" = true ]; then
  log "Cannot resume — required files are missing. Use create-officer.sh instead."
  exit 1
fi

[ ! -f "$SKILLS_FILE" ] && log "WARNING: Skills file missing: $SKILLS_FILE (officer will use default post-compaction refresh)"

# === Check bot token ===
OFFICER_UPPER="${OFFICER^^}"
TOKEN_VAR="TELEGRAM_${OFFICER_UPPER}_TOKEN"
source "$CABINET_ROOT/cabinet/.env" 2>/dev/null
TOKEN="${!TOKEN_VAR:-}"
if [ -z "$TOKEN" ]; then
  log "ERROR: No Telegram bot token found ($TOKEN_VAR not in .env)"
  log "Add the bot token to cabinet/.env and try again."
  exit 1
fi

# === Mark as active ===
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:officer:expected:$OFFICER" "active" > /dev/null 2>&1
log "Marked as active in Redis"

# === Start the officer ===
log "Starting officer session..."
bash "$CABINET_ROOT/cabinet/scripts/start-officer.sh" "$OFFICER"

# === Notify other officers ===
source "$CABINET_ROOT/cabinet/scripts/lib/triggers.sh" 2>/dev/null
for other in $(ls "$CABINET_ROOT/instance/memory/tier2/" 2>/dev/null); do
  [ "$other" = "$OFFICER" ] && continue
  EXPECTED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:officer:expected:$other" 2>/dev/null)
  [ "$EXPECTED" = "active" ] && OFFICER_NAME=supervisor trigger_send "$other" "OFFICER RE-HIRED: ${OFFICER^^} is back online. Check exit record for context on what they were doing before suspension."
done

# === Announce ===
if [ -n "${TELEGRAM_HQ_CHAT_ID:-}" ]; then
  bash "$CABINET_ROOT/cabinet/scripts/send-to-group.sh" "<b>Officer re-hired: ${OFFICER^^}</b>
Previously suspended. Now active and booting." 2>/dev/null || true
fi

log ""
log "=========================================="
log " Officer ${OFFICER^^} resumed successfully"
log "=========================================="
log ""
log "Exit record preserved at: $EXIT_RECORD"
log "Tier2 notes intact: $TIER2_DIR/"
log "Session starting with context recovery"
