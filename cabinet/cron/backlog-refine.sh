#!/bin/bash
# backlog-refine.sh — Triggers CPO to refine the backlog
# Runs every 12 hours via cron
[ -f /etc/environment.cabinet ] && source /etc/environment.cabinet

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

TRIGGER_MSG="[$TIMESTAMP] Scheduled backlog refinement. Review Linear issues, incorporate recent research briefs from Notion Research Hub, update priorities in shared/backlog.md, and ensure top items have specs in Notion Product Hub."

# PRIMARY: Push to Redis
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" RPUSH "cabinet:triggers:cpo" "$TRIGGER_MSG" > /dev/null 2>&1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:triggers:cpo" 21600 > /dev/null 2>&1

echo "[$TIMESTAMP] Backlog refinement trigger pushed"
