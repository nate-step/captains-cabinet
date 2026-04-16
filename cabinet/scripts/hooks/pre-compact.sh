#!/bin/bash
# pre-compact.sh — Captures officer operational state BEFORE context compaction
# Writes to local file (fast, never fails) + PostgreSQL (persistent, async-tolerant)
# The post-compact hook reads this state and injects it back into context.

OFFICER="${OFFICER_NAME:-unknown}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"

STATE_DIR="/opt/founders-cabinet/instance/memory/tier2/$OFFICER"
STATE_FILE="$STATE_DIR/.session-state.json"
mkdir -p "$STATE_DIR"

# ============================================================
# 1. Collect Redis operational state
# ============================================================
TOOL_CALLS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:toolcalls:$OFFICER" 2>/dev/null | grep -o '[0-9]*' || echo "0")
. /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh 2>/dev/null
TRIGGER_COUNT=$(trigger_count "$OFFICER" 2>/dev/null | grep -o '[0-9]*' || echo "0")

# Collect schedule timestamps — use jq for safe JSON construction
SCHEDULE_JSON="{}"
while read -r key; do
  [ -z "$key" ] && continue
  task="${key##*:}"
  val=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$key" 2>/dev/null)
  SCHEDULE_JSON=$(echo "$SCHEDULE_JSON" | jq --arg k "$task" --arg v "$val" '. + {($k): $v}')
done < <(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" KEYS "cabinet:schedule:last-run:$OFFICER:*" 2>/dev/null)

# ============================================================
# 2. Write local state file using jq (always valid JSON)
# ============================================================
jq -n \
  --arg officer "$OFFICER" \
  --arg captured_at "$TIMESTAMP" \
  --argjson tool_calls "${TOOL_CALLS:-0}" \
  --argjson pending_triggers "${TRIGGER_COUNT:-0}" \
  --argjson schedules "$SCHEDULE_JSON" \
  '{officer: $officer, captured_at: $captured_at, tool_calls: $tool_calls, pending_triggers: $pending_triggers, schedules: $schedules}' \
  > "$STATE_FILE"

# ============================================================
# 3. Store to PostgreSQL for cross-session persistence (best-effort)
# ============================================================
# Source env if NEON_CONNECTION_STRING not already set
[ -z "$NEON_CONNECTION_STRING" ] && source /opt/founders-cabinet/cabinet/.env 2>/dev/null

if [ -n "$NEON_CONNECTION_STRING" ]; then
  NOTES_FILE="/opt/founders-cabinet/instance/memory/tier2/$OFFICER/working-notes.md"
  WORKING_NOTES=""
  [ -f "$NOTES_FILE" ] && WORKING_NOTES=$(tail -c 3000 "$NOTES_FILE")

  # Use psql variables (:'var' syntax) via heredoc for injection-safe parameterized insert
  # Note: :'var' only works via stdin/heredoc, NOT with -c flag
  psql "$NEON_CONNECTION_STRING" -q \
    -v officer="$OFFICER" \
    -v content="$WORKING_NOTES" \
    -v state="$(cat "$STATE_FILE")" \
    2>/dev/null <<'SQLEOF' &
INSERT INTO session_memories (officer, snapshot_type, content, structured_state) VALUES (:'officer', 'pre_compact', :'content', :'state'::jsonb);
SQLEOF
  # Run async — don't block compaction for a DB write
fi

# Always exit 0 — hooks should never block
exit 0
