#!/bin/bash
# retrospective.sh — Triggers CoS to run a Cabinet retrospective
# Runs every 3 days via cron
[ -f /etc/environment.cabinet ] && source /etc/environment.cabinet

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

TRIGGER_MSG="[$TIMESTAMP] Scheduled Cabinet retrospective. Run the Reflection Loop: 1) Review all experience records since last retro, 2) Identify recurring patterns (note at 2x, propose change at 3x), 3) Draft improvement proposals, 4) Validate against known-good scenarios, 5) Submit proposals to Captain via Telegram, 6) Update skill library."

# PRIMARY: Push to Redis
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" RPUSH "cabinet:triggers:cos" "$TRIGGER_MSG" > /dev/null 2>&1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:triggers:cos" 21600 > /dev/null 2>&1

echo "[$TIMESTAMP] Retrospective trigger pushed"
