#!/bin/bash
# health-check.sh — Runs every 5 min via cron (in Watchdog container)
[ -f /etc/environment.cabinet ] && source /etc/environment.cabinet
# Checks each Officer's Redis heartbeat (set by post-tool-use hook in Officers container).
# Alerts Captain if an Officer's heartbeat is stale (>15 min).

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

TELEGRAM_COS_TOKEN="${TELEGRAM_COS_TOKEN:?not set}"
CAPTAIN_TELEGRAM_ID="${CAPTAIN_TELEGRAM_ID:?not set}"

OFFICERS=("cos" "cto" "cro" "cpo")
TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

send_alert() {
  local message="$1"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_COS_TOKEN}/sendMessage" \
    -d chat_id="$CAPTAIN_TELEGRAM_ID" \
    -d text="⚠️ Cabinet Health Alert ($TIMESTAMP)

$message" \
    -d parse_mode="Markdown" > /dev/null 2>&1
}

check_officer() {
  local officer="$1"
  local redis_key="cabinet:heartbeat:$officer"

  # Check if heartbeat exists (TTL of 900s = 15 min, set by post-tool-use hook)
  local heartbeat
  heartbeat=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$redis_key" 2>/dev/null)

  if [ -n "$heartbeat" ] && [ "$heartbeat" != "" ]; then
    # Heartbeat exists and hasn't expired — Officer is alive
    echo "[$TIMESTAMP] Officer $officer: healthy (last heartbeat: $heartbeat)"
    return 0
  else
    # No heartbeat — check if we already flagged this
    local flag_key="cabinet:health:alert-sent:$officer"
    local already_alerted
    already_alerted=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$flag_key" 2>/dev/null)

    if [ "$already_alerted" = "yes" ]; then
      echo "[$TIMESTAMP] Officer $officer: still down (alert already sent)"
    else
      send_alert "🔴 *$officer* has no heartbeat. The Officer may have crashed or stalled. Check tmux in the Officers container."
      redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "$flag_key" "yes" EX 3600 > /dev/null 2>&1
      echo "[$TIMESTAMP] Officer $officer: DOWN — alert sent to Captain"
    fi
    return 1
  fi
}

# ============================================================
# Run checks
# ============================================================
echo "[$TIMESTAMP] Running health checks..."

DOWN_COUNT=0
for officer in "${OFFICERS[@]}"; do
  # Only check Officers that should be running
  EXPECTED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:officer:expected:$officer" 2>/dev/null)
  if [ "$EXPECTED" = "active" ]; then
    if ! check_officer "$officer"; then
      DOWN_COUNT=$((DOWN_COUNT + 1))
    fi
  fi
done

# Check Redis kill switch state
KILLSWITCH=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
if [ "$KILLSWITCH" = "active" ]; then
  echo "[$TIMESTAMP] Kill switch is ACTIVE — skipping further checks"
fi

# Log overall status
echo "[$TIMESTAMP] Health check complete. Down: $DOWN_COUNT"
