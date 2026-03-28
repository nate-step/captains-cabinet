#!/bin/bash
# token-refresh-watch.sh — Runs every 15 min via cron
[ -f /etc/environment.cabinet ] && source /etc/environment.cabinet
# Monitors Officer logs for authentication failures and alerts Captain.
# With subscription auth, token refresh is manual — this is the early warning system.

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

TELEGRAM_COS_TOKEN="${TELEGRAM_COS_TOKEN:?not set}"
CAPTAIN_TELEGRAM_ID="${CAPTAIN_TELEGRAM_ID:?not set}"

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
LOG_DIR="/opt/founders-cabinet/memory/logs"
TODAY=$(date -u +%Y-%m-%d)

send_alert() {
  local message="$1"
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_COS_TOKEN}/sendMessage" \
    -d chat_id="$CAPTAIN_TELEGRAM_ID" \
    -d text="🔑 Auth Alert ($TIMESTAMP)

$message" > /dev/null 2>&1
}

# Check today's logs for auth-related errors
AUTH_ERRORS=0
if [ -f "$LOG_DIR/${TODAY}.jsonl" ]; then
  AUTH_ERRORS=$(grep -ci -E "auth|token|credential|login|401|403|unauthorized" "$LOG_DIR/${TODAY}.jsonl" 2>/dev/null || echo "0")
fi

# Check if we already alerted today (avoid alert storms)
ALREADY_ALERTED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:auth:alerted:$TODAY" 2>/dev/null)

if [ "$AUTH_ERRORS" -gt 3 ] && [ "$ALREADY_ALERTED" != "yes" ]; then
  send_alert "Detected $AUTH_ERRORS auth-related errors in today's logs. An Officer's OAuth token may have expired.

To fix: SSH into the server, exec into the officers container, attach to the affected Officer's tmux window, and run \`claude /login\`.

Command:
\`\`\`
docker exec -it \$(docker ps -qf name=-officers) bash
tmux attach -t cabinet
\`\`\`"

  # Mark as alerted to avoid repeats
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:auth:alerted:$TODAY" "yes" EX 86400 > /dev/null 2>&1
  echo "[$TIMESTAMP] Auth alert sent to Captain ($AUTH_ERRORS errors detected)"
else
  echo "[$TIMESTAMP] Auth check OK (errors: $AUTH_ERRORS)"
fi
