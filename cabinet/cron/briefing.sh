#!/bin/bash
# briefing.sh — Triggers CoS to produce a daily briefing
# Runs at 07:00 and 19:00 CET via cron
[ -f /etc/environment.cabinet ] && source /etc/environment.cabinet
#
# Delivery mechanism:
#   1. Redis RPUSH → post-tool-use hook surfaces it to Officer (RELIABLE)
#   2. Inbox file append → backup audit trail (PASSIVE)

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
BRIEFING_TYPE="${1:-morning}"

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

TRIGGER_MSG="[$TIMESTAMP] Daily $BRIEFING_TYPE briefing due. Compile status from all Officers and send briefing to Warroom Telegram group. Include: progress since last briefing, current blockers, upcoming priorities, decisions needed from Captain."

# PRIMARY: Push to Redis Stream — surfaced by post-tool-use hook, crash-safe
. /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh
OFFICER_NAME=cron trigger_send cos "$TRIGGER_MSG"

echo "[$TIMESTAMP] Briefing trigger pushed ($BRIEFING_TYPE)"
