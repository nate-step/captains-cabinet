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

  TRIGGER_MSG="[$TIMESTAMP] REFLECTION (3 levels — read memory/skills/holistic-thinking.md). Write your reflection to memory/tier2/$officer/reflections/\$(date -u +%Y-%m-%d-%H%M).md covering ALL THREE LEVELS:

L1 WORK: What did I do? What worked, what failed, what did I learn?
L2 WORKFLOW: What about my process could be better? Where do I waste effort? What handoffs were lossy?
L3 META-IMPROVEMENT: What about the cabinet's improvement process itself could be better? What patterns am I noticing that should improve the framework, not just my domain?

Then: surface any L2/L3 ideas to CoS via notify-officer.sh. After writing: redis-cli -h redis -p 6379 SET cabinet:schedule:last-run:$officer:reflection \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" && redis-cli -h redis -p 6379 INCR cabinet:reflections:count"

  OFFICER_NAME=cron trigger_send "$officer" "$TRIGGER_MSG"
done

echo "[$TIMESTAMP] Reflection triggers pushed to all active officers"
