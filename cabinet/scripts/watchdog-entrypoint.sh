#!/bin/bash
# watchdog-entrypoint.sh — Makes env vars available to cron jobs

echo "============================================"
echo " Sensed Cabinet — Watchdog Starting"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# Cron doesn't inherit environment variables from Docker,
# so we dump them to a file that scripts can source
printenv | grep -E '^(TELEGRAM_|CAPTAIN_|REDIS_|DATABASE_|POSTGRES_)' > /etc/environment.cabinet

# Scripts source this file themselves — no sed injection needed
chmod 644 /etc/environment.cabinet

echo "Cron schedule:"
echo "  Health check:     every 5 min"
echo "  Token watch:      every 15 min"
echo "  Morning briefing: 06:00 UTC (07:00 CET)"
echo "  Evening briefing: 18:00 UTC (19:00 CET)"
echo "  Research sweep:   every 4h"
echo "  Backlog refine:   every 12h"
echo "  Retrospective:    every 3 days at 06:00 UTC"
echo ""
echo "Watchdog running."

# Start cron in foreground
exec cron -f
