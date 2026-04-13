#!/bin/bash
# research-sweep.sh — Triggers CRO to run a research sweep
# Runs every 4 hours via cron
[ -f /etc/environment.cabinet ] && source /etc/environment.cabinet

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

TRIGGER_MSG="[$TIMESTAMP] Scheduled research sweep. Review current product priorities in shared/backlog.md and Notion Product Hub, identify relevant research questions, and produce a research brief to Notion Research Hub."

# PRIMARY: Push to Redis Stream
. /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh
OFFICER_NAME=cron trigger_send cro "$TRIGGER_MSG"

echo "[$TIMESTAMP] Research sweep trigger pushed"
