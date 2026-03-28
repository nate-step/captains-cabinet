#!/bin/bash
# research-sweep.sh — Triggers CRO to run a research sweep
# Runs every 4 hours via cron

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

TRIGGER_MSG="[$TIMESTAMP] Scheduled research sweep. Review current product priorities in shared/backlog.md and Notion Product Hub, identify relevant research questions, and produce a research brief to Notion Research Hub."

# PRIMARY: Push to Redis
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" RPUSH "cabinet:triggers:cro" "$TRIGGER_MSG" > /dev/null 2>&1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:triggers:cro" 21600 > /dev/null 2>&1


echo "" >> "$TRIGGER_FILE"
echo "---" >> "$TRIGGER_FILE"
echo "**[SYSTEM TRIGGER — $TIMESTAMP]** Scheduled research sweep." >> "$TRIGGER_FILE"

echo "[$TIMESTAMP] Research sweep trigger pushed"
