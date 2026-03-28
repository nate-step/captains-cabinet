#!/bin/bash
# post-tool-use.sh — Runs after every tool invocation
# Logs the action and increments cost counters.
#
# Arguments:
#   $1 = TOOL_NAME
#   $2 = TOOL_INPUT (JSON)
#   $3 = TOOL_OUTPUT (may be truncated)

TOOL_NAME="$1"
TOOL_INPUT="$2"
TOOL_OUTPUT="$3"

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

LOG_DIR="/opt/founders-cabinet/memory/logs"
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date -u +%Y-%m-%d)
OFFICER="${OFFICER_NAME:-unknown}"

# ============================================================
# 1. STRUCTURED LOG ENTRY
# ============================================================
LOG_FILE="$LOG_DIR/${TODAY}.jsonl"

# Truncate output for logging (max 500 chars)
TRUNCATED_OUTPUT=$(echo "$TOOL_OUTPUT" | head -c 500)

# Write JSON log line
echo "{\"ts\":\"$TIMESTAMP\",\"officer\":\"$OFFICER\",\"tool\":\"$TOOL_NAME\",\"input\":$(echo "$TOOL_INPUT" | jq -c '.' 2>/dev/null || echo '{}'),\"output_preview\":$(echo "$TRUNCATED_OUTPUT" | jq -Rs '.' 2>/dev/null || echo '""')}" >> "$LOG_FILE"

# ============================================================
# 2. COST TRACKING (rough estimate)
# ============================================================
# Estimate cost based on tool type and input/output size
# These are rough approximations — real cost comes from API usage
INPUT_TOKENS=$(echo "$TOOL_INPUT" | wc -c)
OUTPUT_TOKENS=$(echo "$TOOL_OUTPUT" | wc -c)

# Rough cost estimate in cents (very approximate)
# Opus: ~$15/MTok input, ~$75/MTok output → ~0.0015¢/char in, ~0.0075¢/char out
# Using ~4 chars per token as rough estimate
COST_CENTS=$(( (INPUT_TOKENS * 15 / 4000000 + OUTPUT_TOKENS * 75 / 4000000) ))
COST_CENTS=$((COST_CENTS > 0 ? COST_CENTS : 1))  # minimum 1 cent per action

# Increment daily cost counter (expires after 48h)
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INCRBY "cabinet:cost:daily:$TODAY" "$COST_CENTS" > /dev/null 2>&1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:cost:daily:$TODAY" 172800 > /dev/null 2>&1

# Increment per-officer daily counter
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INCRBY "cabinet:cost:officer:$OFFICER:$TODAY" "$COST_CENTS" > /dev/null 2>&1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:cost:officer:$OFFICER:$TODAY" 172800 > /dev/null 2>&1

# Increment monthly counter
MONTH=$(date -u +%Y-%m)
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INCRBY "cabinet:cost:monthly:$MONTH" "$COST_CENTS" > /dev/null 2>&1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:cost:monthly:$MONTH" 2764800 > /dev/null 2>&1

# ============================================================
# 3. CHECK FOR PENDING TRIGGERS
# ============================================================
# Cron jobs and other Officers push triggers to Redis.
# We check here because this hook runs after every tool call —
# the most reliable way to deliver notifications.

TRIGGERS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LRANGE "cabinet:triggers:$OFFICER" 0 -1 2>/dev/null)

if [ -n "$TRIGGERS" ] && [ "$TRIGGERS" != "" ]; then
  echo ""
  echo "⏰ PENDING TRIGGERS FOR $OFFICER:"
  echo "$TRIGGERS" | while IFS= read -r trigger; do
    [ -n "$trigger" ] && echo "  → $trigger"
  done
  echo ""
  echo "Process these triggers now."
  
  # Clear delivered triggers
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "cabinet:triggers:$OFFICER" > /dev/null 2>&1
fi

# Always exit 0 — post-hooks should never block
exit 0
