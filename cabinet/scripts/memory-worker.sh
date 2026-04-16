#!/bin/bash
# memory-worker.sh — Background worker that processes the memory embed queue
# Reads from Redis Stream cabinet:memory:embed_queue, embeds, inserts to cabinet_memory
# Retries on failure. Run as a long-lived process (systemd, supervisor, or cron every 1min).

set -uo pipefail

source /opt/founders-cabinet/cabinet/scripts/lib/memory.sh

GROUP="memory-worker"
CONSUMER="${HOSTNAME:-worker}"
MAX_DELIVERIES=5
DLQ_KEY="cabinet:memory:dead_letter"

# Ensure consumer group exists
redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XGROUP CREATE "$MEM_QUEUE_KEY" "$GROUP" 0 MKSTREAM > /dev/null 2>&1

log() { echo "[memory-worker $(date -u +%H:%M:%S)] $1"; }

# Check delivery count for a message. If it exceeds MAX_DELIVERIES, move to DLQ + ACK.
# Returns 0 if message should be processed, 1 if it was moved to DLQ.
# XPENDING output (per message, --raw): line1=id, line2=consumer, line3=idle_ms, line4=deliveries
check_poison_message() {
  local msg_id="$1"
  local payload="$2"
  local count
  count=$(redis-cli --raw -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" \
    XPENDING "$MEM_QUEUE_KEY" "$GROUP" "$msg_id" "$msg_id" 1 2>/dev/null \
    | awk 'NR==4{print; exit}')
  count=${count:-0}
  if [ "$count" -ge "$MAX_DELIVERIES" ]; then
    redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" \
      RPUSH "$DLQ_KEY" "$(jq -nc --arg id "$msg_id" --arg payload "$payload" --arg count "$count" \
        '{id: $id, payload: $payload, deliveries: ($count|tonumber), parked_at: now|todate}')" > /dev/null 2>&1
    redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" \
      XACK "$MEM_QUEUE_KEY" "$GROUP" "$msg_id" > /dev/null 2>&1
    log "poison message $msg_id → DLQ after $count deliveries"
    return 1
  fi
  return 0
}

# Re-deliver pending messages that have been idle > 30s so they get retried.
# Without this, a single worker that fails a message never re-sees it (XREADGROUP '>' = new only).
reclaim_stale_pending() {
  redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" \
    XAUTOCLAIM "$MEM_QUEUE_KEY" "$GROUP" "$CONSUMER" 30000 0 COUNT 50 > /dev/null 2>&1
}

# Process one batch; exits after processing if --once passed
MODE="${1:-loop}"

process_batch() {
  # Reclaim stale pending messages first (retries for previously-failed items)
  reclaim_stale_pending

  local output
  output=$(redis-cli --raw -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" \
    XREADGROUP GROUP "$GROUP" "$CONSUMER" COUNT 10 BLOCK 5000 \
    STREAMS "$MEM_QUEUE_KEY" '>' 2>/dev/null)

  [ -z "$output" ] && return 0

  # Parse: extract message IDs + payload values
  local ids=()
  local payloads=()
  local expecting="id"
  local skip_next=false
  while IFS= read -r line; do
    if [ "$skip_next" = true ]; then
      # This line is the payload value
      payloads+=("$line")
      skip_next=false
      expecting="id"
      continue
    fi
    if [[ "$line" =~ ^[0-9]+-[0-9]+$ ]]; then
      ids+=("$line")
      expecting="payload_key"
    elif [ "$expecting" = "payload_key" ] && [ "$line" = "payload" ]; then
      skip_next=true
    fi
  done <<< "$output"

  local success=0
  local failed=0

  for i in "${!ids[@]}"; do
    local id="${ids[$i]}"
    local payload="${payloads[$i]:-}"
    # Empty payload = unparseable → ACK and drop (prevents infinite retry)
    if [ -z "$payload" ]; then
      redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XACK "$MEM_QUEUE_KEY" "$GROUP" "$id" > /dev/null 2>&1
      failed=$((failed+1))
      continue
    fi

    # Poison message check — move to DLQ after MAX_DELIVERIES attempts
    if ! check_poison_message "$id" "$payload"; then
      failed=$((failed+1))
      continue
    fi

    # Parse JSON payload
    local source_type source_id officer sender content metadata source_ts
    source_type=$(echo "$payload" | jq -r '.source_type // empty' 2>/dev/null)
    source_id=$(echo "$payload" | jq -r '.source_id // empty' 2>/dev/null)
    officer=$(echo "$payload" | jq -r '.officer // empty' 2>/dev/null)
    sender=$(echo "$payload" | jq -r '.sender // empty' 2>/dev/null)
    content=$(echo "$payload" | jq -r '.content // empty' 2>/dev/null)
    metadata=$(echo "$payload" | jq -c '.metadata // {}' 2>/dev/null)
    source_ts=$(echo "$payload" | jq -r '.source_ts // empty' 2>/dev/null)

    if [ -z "$content" ]; then
      redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XACK "$MEM_QUEUE_KEY" "$GROUP" "$id" > /dev/null 2>&1
      failed=$((failed+1))
      continue
    fi

    # Try to embed + insert
    if memory_embed "$source_type" "$source_id" "$officer" "$sender" "$content" "$metadata" "$source_ts" > /dev/null 2>&1; then
      redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XACK "$MEM_QUEUE_KEY" "$GROUP" "$id" > /dev/null 2>&1
      success=$((success+1))
    else
      # Don't ACK — message stays pending, will be retried
      failed=$((failed+1))
    fi
  done

  [ "$success" -gt 0 ] || [ "$failed" -gt 0 ] && log "processed: $success ok, $failed failed"
}

if [ "$MODE" = "--once" ]; then
  process_batch
  exit 0
fi

log "Starting memory worker (group=$GROUP, consumer=$CONSUMER)"
while true; do
  process_batch
done
