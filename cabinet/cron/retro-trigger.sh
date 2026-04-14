#!/bin/bash
# retro-trigger.sh — Fires retro when reflection threshold reached
# Replaces the time-based 24h retro with event-based: every 5 reflections cabinet-wide
# OR every 24h as a safety floor (so retros happen even on quiet days)
[ -f /etc/environment.cabinet ] && source /etc/environment.cabinet

REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
CABINET_ROOT="/opt/founders-cabinet"

. "$CABINET_ROOT/cabinet/scripts/lib/triggers.sh"

# Threshold: 5 reflections since last retro
THRESHOLD=5

REFLECTIONS_NOW=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:reflections:count" 2>/dev/null || echo 0)
LAST_RETRO_COUNT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:reflections:count_at_last_retro" 2>/dev/null || echo 0)

REFLECTIONS_SINCE=$((REFLECTIONS_NOW - LAST_RETRO_COUNT))

# Safety floor: also fire if last retro was 48h ago (catches quiet periods)
LAST_RETRO_TS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:schedule:last-run:cos:retro" 2>/dev/null)
LAST_RETRO_EPOCH=$(date -d "$LAST_RETRO_TS" +%s 2>/dev/null || echo 0)
NOW_EPOCH=$(date -u +%s)
HOURS_SINCE_RETRO=$(( (NOW_EPOCH - LAST_RETRO_EPOCH) / 3600 ))

SHOULD_FIRE=false
REASON=""

if [ "$REFLECTIONS_SINCE" -ge "$THRESHOLD" ]; then
  SHOULD_FIRE=true
  REASON="$REFLECTIONS_SINCE reflections since last retro (threshold: $THRESHOLD)"
elif [ "$HOURS_SINCE_RETRO" -ge 48 ]; then
  SHOULD_FIRE=true
  REASON="${HOURS_SINCE_RETRO}h since last retro (safety floor: 48h)"
fi

if [ "$SHOULD_FIRE" = true ]; then
  TRIGGER_MSG="[$TIMESTAMP] RETRO + EVOLUTION DUE — $REASON.

INPUTS to retro (gather BEFORE writing):
1. Experience records since last retro: ls memory/tier3/experience-records/
2. Reflections since last retro: find memory/tier2/*/reflections/ -newer (last retro timestamp) — includes L1/L2/L3 self-assessments
3. Meta-improvement contributions surfaced to CoS: search recent triggers for L3 ideas
4. Captain corrections (negative feedback patterns): grep memory/tier2/*/corrections.md — rising = drift, falling = calibration
5. Captain decisions: shared/interfaces/captain-decisions.md
6. Org health audit: bash cabinet/scripts/org-health-audit.sh — workload distribution, capability gaps, idle vs busy
7. Cross-validation / peer review activity: redis-cli KEYS 'cabinet:notified:*' — were reviewers actually triggered? Did they respond?
8. Auto-compact interventions: redis-cli MGET cabinet:supervisor:autocompact-count:* — officers needing safety net suggest context exhaustion patterns
9. Officer lifecycle events: any suspended or re-hired officers since last retro
10. Supervisor restarts: redis-cli MGET cabinet:supervisor:restart-count:* — high count signals instability
11. Trigger ACK health: which officers had pending triggers age too long

Phase 1 RETRO: Cross-officer patterns, handoff quality, coordination gaps. Score the cabinet on improving the WORK, the WORKFLOW, the IMPROVEMENT itself (3 levels).
Phase 2 EVOLUTION: Validate draft skills against golden evals, promote validated skills.

After: redis-cli -h $REDIS_HOST -p $REDIS_PORT SET cabinet:schedule:last-run:cos:retro \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" && redis-cli -h $REDIS_HOST -p $REDIS_PORT SET cabinet:reflections:count_at_last_retro \"$REFLECTIONS_NOW\""

  OFFICER_NAME=cron trigger_send cos "$TRIGGER_MSG"
  echo "[$TIMESTAMP] Retro trigger fired: $REASON"
else
  echo "[$TIMESTAMP] No retro yet: $REFLECTIONS_SINCE/$THRESHOLD reflections, ${HOURS_SINCE_RETRO}h since last (floor: 48h)"
fi
