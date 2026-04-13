#!/bin/bash
# pre-compact.sh — Captures officer operational state BEFORE context compaction
# Writes to local file (fast, never fails) + PostgreSQL (persistent, async-tolerant)
# The post-compact hook reads this state and injects it back into context.

OFFICER="${OFFICER_NAME:-unknown}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"

STATE_DIR="/opt/founders-cabinet/memory/tier2/$OFFICER"
STATE_FILE="$STATE_DIR/.session-state.json"
mkdir -p "$STATE_DIR"

# ============================================================
# 1. Collect Redis operational state
# ============================================================
TOOL_CALLS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:toolcalls:$OFFICER" 2>/dev/null | grep -o '[0-9]*' || echo "0")
TRIGGER_COUNT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LLEN "cabinet:triggers:$OFFICER" 2>/dev/null | grep -o '[0-9]*' || echo "0")

# Collect schedule timestamps
SCHEDULE_JSON="{"
FIRST=true
for key in $(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" KEYS "cabinet:schedule:last-run:$OFFICER:*" 2>/dev/null); do
  task="${key##*:}"
  val=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$key" 2>/dev/null)
  if [ "$FIRST" = true ]; then
    FIRST=false
  else
    SCHEDULE_JSON="$SCHEDULE_JSON,"
  fi
  SCHEDULE_JSON="$SCHEDULE_JSON\"$task\":\"$val\""
done
SCHEDULE_JSON="$SCHEDULE_JSON}"

# ============================================================
# 2. Write local state file (fast — this is the critical path)
# ============================================================
cat > "$STATE_FILE" << STATEEOF
{
  "officer": "$OFFICER",
  "captured_at": "$TIMESTAMP",
  "tool_calls": $TOOL_CALLS,
  "pending_triggers": $TRIGGER_COUNT,
  "schedules": $SCHEDULE_JSON
}
STATEEOF

# ============================================================
# 3. Store to PostgreSQL for cross-session persistence (best-effort)
# ============================================================
if [ -n "$NEON_CONNECTION_STRING" ]; then
  # Read working notes tail for content field (escaped for SQL)
  NOTES_FILE="/opt/founders-cabinet/memory/tier2/$OFFICER/working-notes.md"
  if [ -f "$NOTES_FILE" ]; then
    WORKING_NOTES=$(tail -c 3000 "$NOTES_FILE" | sed "s/'/''/g")
  else
    WORKING_NOTES="No working notes found."
  fi

  STATE_JSON=$(cat "$STATE_FILE" | sed "s/'/''/g")

  psql "$NEON_CONNECTION_STRING" -q -c \
    "INSERT INTO session_memories (officer, snapshot_type, content, structured_state) VALUES ('$OFFICER', 'pre_compact', '$WORKING_NOTES', '$STATE_JSON'::jsonb);" \
    2>/dev/null &
  # Run async — don't block compaction for a DB write
fi

# Always exit 0 — hooks should never block
exit 0
