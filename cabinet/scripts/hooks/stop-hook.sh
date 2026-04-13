#!/bin/bash
# stop-hook.sh — Fires every time an officer finishes responding
# Lightweight session state update + cost tracking preparation
# Receives on stdin: { session_id, transcript_path, cwd, permission_mode, hook_event_name }

HOOK_INPUT=$(cat)
OFFICER="${OFFICER_NAME:-unknown}"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"

# Extract transcript path for cost tracking
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# ============================================================
# 1. Update session state timestamp (proves officer is active)
# ============================================================
STATE_DIR="/opt/founders-cabinet/memory/tier2/$OFFICER"
STATE_FILE="$STATE_DIR/.session-state.json"

if [ -f "$STATE_FILE" ]; then
  # Update captured_at in existing state file (lightweight — no Redis calls)
  UPDATED=$(jq --arg ts "$TIMESTAMP" --arg sid "$SESSION_ID" \
    '.captured_at = $ts | .session_id = $sid' "$STATE_FILE" 2>/dev/null)
  if [ -n "$UPDATED" ]; then
    echo "$UPDATED" > "$STATE_FILE"
  fi
fi

# ============================================================
# 2. Extract actual token costs from transcript (replaces byte estimation)
# ============================================================
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  # Get the last assistant entry with usage data
  USAGE=$(tail -100 "$TRANSCRIPT_PATH" | jq -r 'select(.type == "assistant" and .message.usage != null) | .message.usage' 2>/dev/null | tail -1)

  if [ -n "$USAGE" ] && [ "$USAGE" != "null" ]; then
    INPUT_TOKENS=$(echo "$USAGE" | jq -r '.input_tokens // 0' 2>/dev/null)
    OUTPUT_TOKENS=$(echo "$USAGE" | jq -r '.output_tokens // 0' 2>/dev/null)
    CACHE_WRITE=$(echo "$USAGE" | jq -r '.cache_creation_input_tokens // 0' 2>/dev/null)
    CACHE_READ=$(echo "$USAGE" | jq -r '.cache_read_input_tokens // 0' 2>/dev/null)

    # Detect model for pricing (Opus vs Sonnet)
    MODEL=$(tail -100 "$TRANSCRIPT_PATH" | jq -r 'select(.type == "assistant" and .message.model != null) | .message.model' 2>/dev/null | tail -1)

    # Calculate dollar cost in microdollars (millionths of a dollar) for integer math
    # Opus 4.6:  $15/MTok in, $75/MTok out, $3.75/MTok cache_write, $0.30/MTok cache_read
    # Sonnet 4.6: $3/MTok in, $15/MTok out, $0.75/MTok cache_write, $0.06/MTok cache_read
    case "$MODEL" in
      *opus*)
        COST_MICRO=$(( INPUT_TOKENS * 15 / 1000 + OUTPUT_TOKENS * 75 / 1000 + CACHE_WRITE * 3750 / 1000000 + CACHE_READ * 300 / 1000000 ))
        ;;
      *)
        # Default to Sonnet pricing
        COST_MICRO=$(( INPUT_TOKENS * 3 / 1000 + OUTPUT_TOKENS * 15 / 1000 + CACHE_WRITE * 750 / 1000000 + CACHE_READ * 60 / 1000000 ))
        ;;
    esac

    # Store latest turn: tokens + cost
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HSET "cabinet:cost:tokens:$OFFICER" \
      last_input "$INPUT_TOKENS" \
      last_output "$OUTPUT_TOKENS" \
      last_cache_write "$CACHE_WRITE" \
      last_cache_read "$CACHE_READ" \
      last_cost_micro "$COST_MICRO" \
      last_model "$MODEL" \
      last_updated "$TIMESTAMP" \
      > /dev/null 2>&1
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:cost:tokens:$OFFICER" 86400 > /dev/null 2>&1

    # Accumulate daily totals: tokens + cost
    TODAY=$(date -u +%Y-%m-%d)
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HINCRBY "cabinet:cost:tokens:daily:$TODAY" \
      "${OFFICER}_input" "$INPUT_TOKENS" > /dev/null 2>&1
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HINCRBY "cabinet:cost:tokens:daily:$TODAY" \
      "${OFFICER}_output" "$OUTPUT_TOKENS" > /dev/null 2>&1
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HINCRBY "cabinet:cost:tokens:daily:$TODAY" \
      "${OFFICER}_cache_write" "$CACHE_WRITE" > /dev/null 2>&1
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HINCRBY "cabinet:cost:tokens:daily:$TODAY" \
      "${OFFICER}_cache_read" "$CACHE_READ" > /dev/null 2>&1
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HINCRBY "cabinet:cost:tokens:daily:$TODAY" \
      "${OFFICER}_cost_micro" "$COST_MICRO" > /dev/null 2>&1
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:cost:tokens:daily:$TODAY" 172800 > /dev/null 2>&1
  fi
fi

# Always exit 0
exit 0
