#!/bin/bash
# cost-dashboard.sh — Reads Redis cost counters and sends a formatted
# summary to the Captain via Telegram. Run daily by watchdog cron, or
# on-demand via: bash /opt/founders-cabinet/cabinet/scripts/cost-dashboard.sh
[ -f /etc/environment.cabinet ] && source /etc/environment.cabinet

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

TELEGRAM_COS_TOKEN="${TELEGRAM_COS_TOKEN:?not set}"
CAPTAIN_TELEGRAM_ID="${CAPTAIN_TELEGRAM_ID:?not set}"

TODAY=$(date -u +%Y-%m-%d)
YESTERDAY=$(date -u -d "yesterday" +%Y-%m-%d 2>/dev/null || date -u -v-1d +%Y-%m-%d 2>/dev/null)
MONTH=$(date -u +%Y-%m)
TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

# ============================================================
# Gather cost data from Redis
# ============================================================
DAILY_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:daily:$TODAY" 2>/dev/null)
DAILY_COST=${DAILY_COST:-0}

YESTERDAY_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:daily:$YESTERDAY" 2>/dev/null)
YESTERDAY_COST=${YESTERDAY_COST:-0}

MONTHLY_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:monthly:$MONTH" 2>/dev/null)
MONTHLY_COST=${MONTHLY_COST:-0}

# Per-officer today
COS_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:officer:cos:$TODAY" 2>/dev/null)
COS_COST=${COS_COST:-0}
CTO_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:officer:cto:$TODAY" 2>/dev/null)
CTO_COST=${CTO_COST:-0}
CPO_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:officer:cpo:$TODAY" 2>/dev/null)
CPO_COST=${CPO_COST:-0}
CRO_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:officer:cro:$TODAY" 2>/dev/null)
CRO_COST=${CRO_COST:-0}

# Restart counts
COS_RESTARTS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:supervisor:restart-count:cos" 2>/dev/null)
COS_RESTARTS=${COS_RESTARTS:-0}
CTO_RESTARTS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:supervisor:restart-count:cto" 2>/dev/null)
CTO_RESTARTS=${CTO_RESTARTS:-0}
CPO_RESTARTS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:supervisor:restart-count:cpo" 2>/dev/null)
CPO_RESTARTS=${CPO_RESTARTS:-0}
CRO_RESTARTS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:supervisor:restart-count:cro" 2>/dev/null)
CRO_RESTARTS=${CRO_RESTARTS:-0}

# Heartbeat status
check_heartbeat() {
  local hb
  hb=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:heartbeat:$1" 2>/dev/null)
  if [ -n "$hb" ] && [ "$hb" != "" ]; then
    echo "✅"
  else
    local expected
    expected=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:officer:expected:$1" 2>/dev/null)
    if [ "$expected" = "active" ]; then
      echo "🔴"
    else
      echo "⏸️"
    fi
  fi
}

COS_STATUS=$(check_heartbeat cos)
CTO_STATUS=$(check_heartbeat cto)
CPO_STATUS=$(check_heartbeat cpo)
CRO_STATUS=$(check_heartbeat cro)

# Daily limit info
DAILY_LIMIT=30000  # cents = $300

# Format as dollars
fmt() {
  local cents=$1
  local dollars=$((cents / 100))
  local remainder=$((cents % 100))
  printf '$%d.%02d' "$dollars" "$remainder"
}

# Trend indicator
if [ "$DAILY_COST" -gt "$YESTERDAY_COST" ] && [ "$YESTERDAY_COST" -gt 0 ]; then
  TREND="📈"
elif [ "$DAILY_COST" -lt "$YESTERDAY_COST" ] && [ "$YESTERDAY_COST" -gt 0 ]; then
  TREND="📉"
else
  TREND="➡️"
fi

# Daily limit percentage
if [ "$DAILY_LIMIT" -gt 0 ]; then
  LIMIT_PCT=$((DAILY_COST * 100 / DAILY_LIMIT))
else
  LIMIT_PCT=0
fi

# Build progress bar (10 blocks)
FILLED=$((LIMIT_PCT / 10))
EMPTY=$((10 - FILLED))
BAR=""
for ((i=0; i<FILLED; i++)); do BAR+="█"; done
for ((i=0; i<EMPTY; i++)); do BAR+="░"; done

TOTAL_RESTARTS=$((COS_RESTARTS + CTO_RESTARTS + CPO_RESTARTS + CRO_RESTARTS))

# ============================================================
# Build message
# ============================================================
MESSAGE="📊 *Cabinet Cost Dashboard*
_${TIMESTAMP}_

*Today* ${TREND}
${BAR} ${LIMIT_PCT}% of daily limit
Total: $(fmt $DAILY_COST) / $(fmt $DAILY_LIMIT)
Yesterday: $(fmt $YESTERDAY_COST)
Month: $(fmt $MONTHLY_COST)

*Per Officer (today)*
${COS_STATUS} CoS: $(fmt $COS_COST)
${CTO_STATUS} CTO: $(fmt $CTO_COST)
${CPO_STATUS} CPO: $(fmt $CPO_COST)
${CRO_STATUS} CRO: $(fmt $CRO_COST)

*Stability*
Auto-restarts (all time): ${TOTAL_RESTARTS}
  CoS: ${COS_RESTARTS} | CTO: ${CTO_RESTARTS}
  CPO: ${CPO_RESTARTS} | CRO: ${CRO_RESTARTS}"

# Add warning if approaching limit
if [ "$LIMIT_PCT" -ge 80 ]; then
  MESSAGE+="

⚠️ *Approaching daily limit!* Consider pausing non-critical work."
fi

# ============================================================
# Send to Captain
# ============================================================
if [ "${1:-}" = "--stdout" ]; then
  echo "$MESSAGE"
else
  curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_COS_TOKEN}/sendMessage" \
    -d chat_id="$CAPTAIN_TELEGRAM_ID" \
    -d text="$MESSAGE" \
    -d parse_mode="Markdown" > /dev/null 2>&1
  echo "[$TIMESTAMP] Cost dashboard sent to Captain"
fi
