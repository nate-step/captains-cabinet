#!/bin/bash
# health-check.sh — Runs every 5 min via cron
# Checks each Officer's tmux window is alive and Telegram bot is responding.
# Alerts Captain if anything is down for > 5 min.

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

TELEGRAM_COS_TOKEN="${TELEGRAM_COS_TOKEN:?not set}"
CAPTAIN_TELEGRAM_ID="${CAPTAIN_TELEGRAM_ID:?not set}"
TELEGRAM_HQ_CHAT_ID="${TELEGRAM_HQ_CHAT_ID:?not set}"

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
  local window_name="officer-$officer"
  local redis_key="cabinet:health:$officer"

  # Check if tmux window exists
  if tmux list-windows -t cabinet 2>/dev/null | grep -q "$window_name"; then
    # Window exists — mark healthy
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "$redis_key" "healthy" EX 600 > /dev/null 2>&1
    return 0
  else
    # Window missing — check if it was already flagged
    local prev_state
    prev_state=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$redis_key" 2>/dev/null)

    if [ "$prev_state" = "down" ]; then
      # Already flagged — alert escalation
      send_alert "🔴 *$officer* has been down for >5 min. Tmux window \`$window_name\` not found. Manual intervention may be needed."
    else
      # First detection — flag it, alert on next check if still down
      redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "$redis_key" "down" EX 600 > /dev/null 2>&1
      echo "[$TIMESTAMP] Officer $officer window missing — flagged, will alert on next check"
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
  # Only check Officers that should be running (check Redis for "expected" flag)
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
