#!/bin/bash
# triggers.sh — Shared trigger functions using Redis Streams
# Source this: . /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh
#
# Redis Streams give us: crash recovery (pending until ACK'd),
# delivery audit trail (XINFO), automatic message IDs + timestamps.

TRIG_REDIS_HOST="${REDIS_HOST:-redis}"
TRIG_REDIS_PORT="${REDIS_PORT:-6379}"

# Send a trigger to an officer
# Usage: trigger_send <target_officer> "<message>"
trigger_send() {
  local target="$1" message="$2"
  local sender="${OFFICER_NAME:-unknown}"
  local timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

  # Ensure consumer group exists for the target
  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XGROUP CREATE "cabinet:triggers:$target" "officer-$target" 0 MKSTREAM > /dev/null 2>&1

  # Add message to stream
  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XADD "cabinet:triggers:$target" '*' \
    sender "$sender" \
    message "[$timestamp] From $sender: $message" \
    > /dev/null 2>&1
}

# Read NEW triggers for an officer (marks them as pending until ACK'd)
# Usage: trigger_read <officer>
# Outputs: message content lines (one per trigger)
# Sets TRIGGER_IDS variable with space-separated message IDs for ACK
trigger_read() {
  local officer="$1"

  # Ensure consumer group exists (silence BUSYGROUP if already exists)
  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XGROUP CREATE "cabinet:triggers:$officer" "officer-$officer" 0 MKSTREAM > /dev/null 2>&1

  local output
  output=$(redis-cli --raw -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XREADGROUP GROUP "officer-$officer" worker COUNT 50 \
    STREAMS "cabinet:triggers:$officer" '>' 2>/dev/null)

  if [ -z "$output" ]; then
    echo "" > /tmp/.trigger_ids_${officer}
    return 1
  fi

  # Write message IDs to temp file (survives subshell capture)
  echo "$output" | grep -E '^[0-9]+-[0-9]+$' | tr '\n' ' ' > /tmp/.trigger_ids_${officer}
  # Output message content
  echo "$output" | awk '/^message$/{getline; print}'
}

# Read PENDING (unacknowledged) triggers — for crash recovery
# Usage: trigger_read_pending <officer>
trigger_read_pending() {
  local officer="$1"

  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XGROUP CREATE "cabinet:triggers:$officer" "officer-$officer" 0 MKSTREAM > /dev/null 2>&1

  local output
  output=$(redis-cli --raw -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XREADGROUP GROUP "officer-$officer" worker COUNT 50 \
    STREAMS "cabinet:triggers:$officer" '0' 2>/dev/null)

  if [ -z "$output" ]; then
    echo "" > /tmp/.trigger_ids_${officer}
    return 1
  fi

  echo "$output" | grep -E '^[0-9]+-[0-9]+$' | tr '\n' ' ' > /tmp/.trigger_ids_${officer}
  echo "$output" | awk '/^message$/{getline; print}'
}

# Acknowledge triggers (mark as processed)
# Usage: trigger_ack <officer> "<id1> <id2> ..."
trigger_ack() {
  local officer="$1" ids="$2"
  [ -z "$ids" ] && return

  for id in $ids; do
    redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
      XACK "cabinet:triggers:$officer" "officer-$officer" "$id" > /dev/null 2>&1
  done

  # Trim acknowledged messages (keep stream lean)
  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XTRIM "cabinet:triggers:$officer" MAXLEN '~' 100 > /dev/null 2>&1
}

# Count pending (unacknowledged) triggers
# Usage: trigger_count <officer>
trigger_count() {
  local officer="$1"

  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XGROUP CREATE "cabinet:triggers:$officer" "officer-$officer" 0 MKSTREAM > /dev/null 2>&1

  local pending
  pending=$(redis-cli --raw -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XPENDING "cabinet:triggers:$officer" "officer-$officer" 2>/dev/null | head -1)

  echo "${pending:-0}"
}
