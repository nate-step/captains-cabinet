#!/bin/bash
# org-health-audit.sh — Cabinet Organizational Health Audit
# Run by CoS periodically to assess officer effectiveness, gaps, and workload.
# Output: per-officer health report + cabinet-wide recommendations.
#
# Usage: org-health-audit.sh [--json]
# --json: output machine-readable JSON instead of human-readable text

CABINET_ROOT="/opt/founders-cabinet"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
JSON_MODE="${1:-}"
TODAY=$(date -u +%Y-%m-%d)
NOW_EPOCH=$(date -u +%s)

# Discover active officers dynamically
OFFICERS=()
for dir in "$CABINET_ROOT"/instance/memory/tier2/*/; do
  [ -d "$dir" ] && OFFICERS+=("$(basename "$dir")")
done

# ============================================================
# Per-Officer Health Metrics
# ============================================================
echo "=== Cabinet Organizational Health Audit ==="
echo "Date: $(TZ=${CAPTAIN_TIMEZONE:-Europe/Berlin} date '+%Y-%m-%d %H:%M')"
echo "Officers: ${#OFFICERS[@]} (${OFFICERS[*]})"
echo ""

for officer in "${OFFICERS[@]}"; do
  echo "--- $officer ---"

  # 1. Heartbeat status
  HB=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:heartbeat:$officer" 2>/dev/null)
  if [ -n "$HB" ] && [ "$HB" != "(nil)" ]; then
    HB_EPOCH=$(date -d "$HB" +%s 2>/dev/null || echo 0)
    HB_AGO=$(( (NOW_EPOCH - HB_EPOCH) / 60 ))
    if [ "$HB_AGO" -lt 5 ]; then
      echo "  Status: ACTIVE (heartbeat ${HB_AGO}m ago)"
    elif [ "$HB_AGO" -lt 15 ]; then
      echo "  Status: IDLE (heartbeat ${HB_AGO}m ago)"
    else
      echo "  Status: DOWN (heartbeat ${HB_AGO}m ago — TTL likely expired)"
    fi
  else
    echo "  Status: DOWN (no heartbeat)"
  fi

  # 2. Tool calls today
  CALLS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:toolcalls:$officer" 2>/dev/null)
  [[ "$CALLS" =~ ^[0-9]+$ ]] || CALLS=0
  echo "  Tool calls today: $CALLS"

  # 3. Experience records today
  RECORDS=$(ls "$CABINET_ROOT/memory/tier3/experience-records/$TODAY-${officer}-"*.md 2>/dev/null | wc -l)
  echo "  Experience records today: $RECORDS"

  # 4. Last tool call (idle time)
  LAST_CALL=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:last-toolcall:$officer" 2>/dev/null)
  if [ -n "$LAST_CALL" ] && [ "$LAST_CALL" != "(nil)" ]; then
    LC_EPOCH=$(date -d "$LAST_CALL" +%s 2>/dev/null || echo 0)
    IDLE_MIN=$(( (NOW_EPOCH - LC_EPOCH) / 60 ))
    echo "  Idle time: ${IDLE_MIN}m"
  else
    echo "  Idle time: unknown"
  fi

  # 5. Context window
  CTX_PCT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "cabinet:cost:tokens:$officer" last_context_pct 2>/dev/null)
  [[ "$CTX_PCT" =~ ^[0-9]+$ ]] || CTX_PCT="?"
  echo "  Context window: ${CTX_PCT}%"

  # 6. Pending triggers (unACK'd)
  source "$CABINET_ROOT/cabinet/scripts/lib/triggers.sh" 2>/dev/null
  PENDING=$(trigger_count "$officer" 2>/dev/null)
  [[ "$PENDING" =~ ^[0-9]+$ ]] || PENDING=0
  echo "  Pending triggers: $PENDING"

  # 7. Correction count (role fitness signal)
  CORRECTIONS_FILE="$CABINET_ROOT/instance/memory/tier2/$officer/corrections.md"
  if [ -f "$CORRECTIONS_FILE" ]; then
    CORRECTION_COUNT=$(grep -c '^-\|^\*\|^[0-9]' "$CORRECTIONS_FILE" 2>/dev/null || echo 0)
    echo "  Corrections logged: $CORRECTION_COUNT"
  else
    echo "  Corrections logged: 0 (no corrections.md)"
  fi

  # 8. Assessment
  if [ "$CALLS" -eq 0 ] && [ "${IDLE_MIN:-999}" -gt 30 ]; then
    echo "  Assessment: INACTIVE — no tool calls and idle >30m"
  elif [ "$RECORDS" -eq 0 ] && [ "$CALLS" -gt 50 ]; then
    echo "  Assessment: BUSY BUT NO OUTPUT — $CALLS calls but 0 records"
  elif [ "$RECORDS" -ge 3 ]; then
    echo "  Assessment: PRODUCTIVE"
  elif [ "$RECORDS" -ge 1 ]; then
    echo "  Assessment: ACTIVE"
  else
    echo "  Assessment: LOW OUTPUT"
  fi

  echo ""
done

# ============================================================
# Cabinet-Wide Analysis
# ============================================================
echo "=== Cabinet-Wide ==="

# Workload distribution
echo "Workload distribution (tool calls):"
TOTAL_CALLS=0
for officer in "${OFFICERS[@]}"; do
  CALLS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:toolcalls:$officer" 2>/dev/null)
  [[ "$CALLS" =~ ^[0-9]+$ ]] || CALLS=0
  TOTAL_CALLS=$((TOTAL_CALLS + CALLS))
done
for officer in "${OFFICERS[@]}"; do
  CALLS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:toolcalls:$officer" 2>/dev/null)
  [[ "$CALLS" =~ ^[0-9]+$ ]] || CALLS=0
  if [ "$TOTAL_CALLS" -gt 0 ]; then
    PCT=$((CALLS * 100 / TOTAL_CALLS))
  else
    PCT=0
  fi
  printf "  %-4s %5d calls (%2d%%)\n" "$officer" "$CALLS" "$PCT"
done

# Experience record distribution
echo ""
echo "Output distribution (experience records today):"
TOTAL_RECORDS=0
for officer in "${OFFICERS[@]}"; do
  RECORDS=$(ls "$CABINET_ROOT/memory/tier3/experience-records/$TODAY-${officer}-"*.md 2>/dev/null | wc -l)
  TOTAL_RECORDS=$((TOTAL_RECORDS + RECORDS))
  printf "  %-4s %d records\n" "$officer" "$RECORDS"
done
echo "  Total: $TOTAL_RECORDS"

# Officers with high pending triggers (broken/ignoring)
echo ""
echo "Trigger health:"
for officer in "${OFFICERS[@]}"; do
  PENDING=$(trigger_count "$officer" 2>/dev/null)
  [[ "$PENDING" =~ ^[0-9]+$ ]] || PENDING=0
  if [ "$PENDING" -gt 3 ]; then
    echo "  WARNING: $officer has $PENDING unACK'd triggers — may be ignoring or broken"
  elif [ "$PENDING" -gt 0 ]; then
    echo "  $officer: $PENDING pending (normal)"
  fi
done

# Capabilities coverage
echo ""
echo "Capability coverage:"
CAP_FILE="$CABINET_ROOT/cabinet/officer-capabilities.conf"
for cap in deploys_code validates_deployments reviews_implementations logs_captain_decisions reviews_specs reviews_research; do
  OWNERS=$(grep ":${cap}$" "$CAP_FILE" 2>/dev/null | cut -d: -f1 | tr '\n' ', ' | sed 's/,$//')
  if [ -n "$OWNERS" ]; then
    echo "  $cap: $OWNERS"
  else
    echo "  $cap: UNASSIGNED — no officer has this capability"
  fi
done

echo ""
echo "=== End of Audit ==="
