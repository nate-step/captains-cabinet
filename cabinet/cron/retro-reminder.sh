#!/bin/bash
# retro-reminder.sh — Fires retro+evolution trigger to CoS every 24h
# Ensures retros actually happen on schedule rather than relying on CoS initiative
[ -f /etc/environment.cabinet ] && source /etc/environment.cabinet

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
CABINET_ROOT="/opt/founders-cabinet"

. "$CABINET_ROOT/cabinet/scripts/lib/triggers.sh"

TRIGGER_MSG="[$TIMESTAMP] RETRO + EVOLUTION DUE (every 24h). Phase 1: Review all experience records since last retro, focus on cross-officer patterns (handoffs, trigger responsiveness, coordination gaps). Run opportunity scan. Draft improvement proposals for Captain. Phase 2: Review draft skills, validate against golden evals, promote validated skills. Record the evolution loop itself as an experience. After: redis-cli -h redis -p 6379 SET cabinet:schedule:last-run:cos:retro \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

OFFICER_NAME=cron trigger_send cos "$TRIGGER_MSG"

echo "[$TIMESTAMP] Retro reminder pushed to CoS"
