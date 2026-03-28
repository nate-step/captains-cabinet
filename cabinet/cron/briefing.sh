#!/bin/bash
# briefing.sh — Triggers CoS to produce a daily briefing
# Runs at 07:00 and 19:00 CET via cron
#
# Delivery mechanism:
#   1. Redis RPUSH → post-tool-use hook surfaces it to Officer (RELIABLE)
#   2. Inbox file append → backup audit trail (PASSIVE)

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
BRIEFING_TYPE="${1:-morning}"

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

TRIGGER_MSG="[$TIMESTAMP] Daily $BRIEFING_TYPE briefing due. Compile status from all Officers and send briefing to Sensed HQ Telegram group. Include: progress since last briefing, current blockers, upcoming priorities, decisions needed from Captain."

# PRIMARY: Push to Redis — will be surfaced by post-tool-use hook
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" RPUSH "cabinet:triggers:cos" "$TRIGGER_MSG" > /dev/null 2>&1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:triggers:cos" 21600 > /dev/null 2>&1


echo "" >> "$TRIGGER_FILE"
echo "---" >> "$TRIGGER_FILE"
echo "**[SYSTEM TRIGGER — $TIMESTAMP]** Daily $BRIEFING_TYPE briefing due." >> "$TRIGGER_FILE"

echo "[$TIMESTAMP] Briefing trigger pushed ($BRIEFING_TYPE)"
