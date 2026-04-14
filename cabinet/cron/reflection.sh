#!/bin/bash
# reflection.sh — Fires reflection trigger to ALL active officers every 6h
# Replaces the old /loop-based self-reminder now that we use Redis Channel
[ -f /etc/environment.cabinet ] && source /etc/environment.cabinet

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
CABINET_ROOT="/opt/founders-cabinet"

. "$CABINET_ROOT/cabinet/scripts/lib/triggers.sh"

# Fire to all active officers (not suspended)
for dir in "$CABINET_ROOT"/memory/tier2/*/; do
  [ ! -d "$dir" ] && continue
  officer=$(basename "$dir")

  # Skip suspended officers
  EXPECTED=$(redis-cli -h redis -p 6379 GET "cabinet:officer:expected:$officer" 2>/dev/null)
  [ "$EXPECTED" = "suspended" ] && continue

  TRIGGER_MSG="[$TIMESTAMP] Scheduled reflection (every 6h). Review your recent experience records, self-assess quality standards, pattern-detect failures at 3+ threshold, ask 'Am I being fully utilized?' and surface ideas to CoS. Update Tier 2 notes with new knowledge. After: redis-cli -h redis -p 6379 SET cabinet:schedule:last-run:$officer:reflection \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

  OFFICER_NAME=cron trigger_send "$officer" "$TRIGGER_MSG"
done

echo "[$TIMESTAMP] Reflection triggers pushed to all active officers"
