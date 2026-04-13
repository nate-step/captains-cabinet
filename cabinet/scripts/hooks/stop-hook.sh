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
  # Get the last assistant entry with usage data (-c = compact, one JSON object per line)
  # Extract usage + model in one pipeline to ensure they come from the same turn
  LAST_ENTRY=$(tail -100 "$TRANSCRIPT_PATH" | jq -c 'select(.type == "assistant" and .message.usage != null) | {usage: .message.usage, model: .message.model}' 2>/dev/null | tail -1)

  if [ -n "$LAST_ENTRY" ] && [ "$LAST_ENTRY" != "null" ]; then
    INPUT_TOKENS=$(echo "$LAST_ENTRY" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
    OUTPUT_TOKENS=$(echo "$LAST_ENTRY" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
    CACHE_WRITE=$(echo "$LAST_ENTRY" | jq -r '.usage.cache_creation_input_tokens // 0' 2>/dev/null)
    CACHE_READ=$(echo "$LAST_ENTRY" | jq -r '.usage.cache_read_input_tokens // 0' 2>/dev/null)
    MODEL=$(echo "$LAST_ENTRY" | jq -r '.model // "unknown"' 2>/dev/null)

    # Calculate dollar cost in microdollars (millionths of a dollar) for integer math
    # $/MTok = microdollars per token. Cache prices are fractional, so scale via nanodollars.
    # Opus 4.6:  $15/MTok in, $75/MTok out, $3.75/MTok cache_write, $0.30/MTok cache_read
    # Sonnet 4.6: $3/MTok in, $15/MTok out, $0.75/MTok cache_write, $0.06/MTok cache_read
    case "$MODEL" in
      *opus*)
        COST_MICRO=$(( INPUT_TOKENS * 15 + OUTPUT_TOKENS * 75 + CACHE_WRITE * 3750 / 1000 + CACHE_READ * 300 / 1000 ))
        ;;
      *)
        # Default to Sonnet pricing
        COST_MICRO=$(( INPUT_TOKENS * 3 + OUTPUT_TOKENS * 15 + CACHE_WRITE * 750 / 1000 + CACHE_READ * 60 / 1000 ))
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

# ============================================================
# 3. CONTEXT-AWARE SESSION SNAPSHOTS
# ============================================================
# Snapshot when context window reaches 50%, 75%, 90% — smarter
# than "every N tool calls" because it triggers exactly when
# compaction is approaching.
if [ -n "$LAST_ENTRY" ] && [ "$LAST_ENTRY" != "null" ]; then
  # Total context = input_tokens + cache_write (input_tokens already includes cache_read)
  CONTEXT_TOKENS=$(( INPUT_TOKENS + CACHE_WRITE ))
  CONTEXT_WINDOW=${CONTEXT_WINDOW_SIZE:-1000000}  # 1M default (Opus 4.6 beta)

  # Calculate percentage (integer math)
  if [ "$CONTEXT_WINDOW" -gt 0 ] 2>/dev/null; then
    CONTEXT_PCT=$(( CONTEXT_TOKENS * 100 / CONTEXT_WINDOW ))

    # Determine threshold tier
    THRESHOLD=""
    if [ "$CONTEXT_PCT" -ge 90 ]; then
      THRESHOLD="90"
    elif [ "$CONTEXT_PCT" -ge 75 ]; then
      THRESHOLD="75"
    elif [ "$CONTEXT_PCT" -ge 50 ]; then
      THRESHOLD="50"
    fi

    if [ -n "$THRESHOLD" ]; then
      # Check if this threshold was already hit this session (avoid re-triggering)
      LAST_HIT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:snapshot:threshold:$OFFICER" 2>/dev/null)
      [[ "$LAST_HIT" =~ ^[0-9]+$ ]] || LAST_HIT=0

      if [ "$LAST_HIT" -lt "$THRESHOLD" ] 2>/dev/null; then
        # Mark threshold as hit
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:snapshot:threshold:$OFFICER" "$THRESHOLD" EX 86400 > /dev/null 2>&1

        # Write session state snapshot
        STATE_DIR="/opt/founders-cabinet/memory/tier2/$OFFICER"
        mkdir -p "$STATE_DIR"

        SNAP_SCHEDULES="{}"
        while read -r skey; do
          [ -z "$skey" ] && continue
          stask="${skey##*:}"
          sval=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$skey" 2>/dev/null)
          SNAP_SCHEDULES=$(echo "$SNAP_SCHEDULES" | jq --arg k "$stask" --arg v "$sval" '. + {($k): $v}')
        done < <(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" KEYS "cabinet:schedule:last-run:$OFFICER:*" 2>/dev/null)

        jq -n \
          --arg officer "$OFFICER" \
          --arg captured_at "$TIMESTAMP" \
          --arg snapshot_type "context_${THRESHOLD}pct" \
          --argjson context_pct "$CONTEXT_PCT" \
          --argjson context_tokens "$CONTEXT_TOKENS" \
          --argjson schedules "$SNAP_SCHEDULES" \
          '{officer: $officer, captured_at: $captured_at, snapshot_type: $snapshot_type, context_pct: $context_pct, context_tokens: $context_tokens, schedules: $schedules}' \
          > "$STATE_DIR/.session-state.json"

        # Store to PostgreSQL for cross-session persistence (best-effort, async)
        [ -z "$NEON_CONNECTION_STRING" ] && source /opt/founders-cabinet/cabinet/.env 2>/dev/null
        if [ -n "$NEON_CONNECTION_STRING" ]; then
          WORKING_NOTES=""
          [ -f "$STATE_DIR/working-notes.md" ] && WORKING_NOTES=$(tail -c 3000 "$STATE_DIR/working-notes.md")
          psql "$NEON_CONNECTION_STRING" -q \
            -v officer="$OFFICER" \
            -v content="$WORKING_NOTES" \
            -v state="$(cat "$STATE_DIR/.session-state.json")" \
            2>/dev/null <<'SQLEOF' &
INSERT INTO session_memories (officer, snapshot_type, content, structured_state) VALUES (:'officer', 'context_threshold', :'content', :'state'::jsonb);
SQLEOF
        fi
      fi
    fi
  fi
fi

# Always exit 0
exit 0
