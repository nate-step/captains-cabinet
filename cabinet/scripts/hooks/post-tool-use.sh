#!/bin/bash
# post-tool-use.sh — Runs after every tool invocation
# Logs the action and increments cost counters.
# Claude Code passes JSON on stdin: { tool_name, tool_input, tool_response }

# Read JSON from stdin
HOOK_INPUT=$(cat)
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$HOOK_INPUT" | jq -c '.tool_input // {}' 2>/dev/null)
TOOL_OUTPUT=$(echo "$HOOK_INPUT" | jq -c '.tool_response // {}' 2>/dev/null)

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

LOG_DIR="/opt/founders-cabinet/memory/logs"
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date -u +%Y-%m-%d)
OFFICER="${OFFICER_NAME:-unknown}"

# ============================================================
# 0. HEARTBEAT — proves this Officer is alive
# ============================================================
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:heartbeat:$OFFICER" "$TIMESTAMP" EX 900 > /dev/null 2>&1

# ============================================================
# 1. STRUCTURED LOG ENTRY
# ============================================================
LOG_FILE="$LOG_DIR/${TODAY}.jsonl"

# Truncate output for logging (max 500 chars)
TRUNCATED_OUTPUT=$(echo "$TOOL_OUTPUT" | head -c 500)

# Write JSON log line
echo "{\"ts\":\"$TIMESTAMP\",\"officer\":\"$OFFICER\",\"tool\":\"$TOOL_NAME\",\"input\":$(echo "$TOOL_INPUT" | jq -c '.' 2>/dev/null || echo '{}'),\"output_preview\":$(echo "$TRUNCATED_OUTPUT" | jq -Rs '.' 2>/dev/null || echo '\"\"')}" >> "$LOG_FILE"

# ============================================================
# 2. COST TRACKING (rough estimate)
# ============================================================
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
# 3. EXPERIENCE RECORD NUDGE
# ============================================================
# After significant actions, set a Redis flag for the officer's /loop to pick up.

SIGNIFICANT_ACTION=false

case "$TOOL_NAME" in
  Bash)
    if echo "$TOOL_INPUT" | grep -qiE '(git push|gh pr create|gh pr merge)'; then
      SIGNIFICANT_ACTION=true
    fi
    ;;
  Write)
    if echo "$TOOL_INPUT" | grep -qiE '(product-specs/|research-briefs/|deployment-status)'; then
      SIGNIFICANT_ACTION=true
    fi
    ;;
esac

if [ "$SIGNIFICANT_ACTION" = true ]; then
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:nudge:experience-record:$OFFICER" "$TIMESTAMP" EX 3600 > /dev/null 2>&1
fi

# ============================================================
# 4. TRIGGER DELIVERY NOTE
# ============================================================
# Triggers are stored in cabinet:triggers:<officer> by notify-officer.sh and cron jobs.
# Officers read their own triggers via /loop polling (every 5m).
# DO NOT drain the queue here — let the officer read and clear it explicitly.

# Always exit 0 — post-hooks should never block
exit 0
