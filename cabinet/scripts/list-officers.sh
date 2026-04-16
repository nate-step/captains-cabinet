#!/bin/bash
# list-officers.sh — Show all officers and their status
# Usage: list-officers.sh

CABINET_ROOT="/opt/founders-cabinet"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
NOW_EPOCH=$(date -u +%s)

printf "%-6s %-8s %-10s %-8s %-6s %s\n" "OFFICER" "STATUS" "TYPE" "CALLS" "CTX%" "IDLE"
printf "%-6s %-8s %-10s %-8s %-6s %s\n" "------" "------" "--------" "-----" "----" "----"

for dir in "$CABINET_ROOT"/instance/memory/tier2/*/; do
  [ ! -d "$dir" ] && continue
  officer=$(basename "$dir")

  # Status from Redis
  EXPECTED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:officer:expected:$officer" 2>/dev/null)
  case "$EXPECTED" in
    active) STATUS="active" ;;
    suspended) STATUS="suspend" ;;
    *) STATUS="unknown" ;;
  esac

  # Check if actually alive (heartbeat)
  HB=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:heartbeat:$officer" 2>/dev/null)
  if [ "$STATUS" = "active" ] && { [ -z "$HB" ] || [ "$HB" = "(nil)" ]; }; then
    STATUS="dead"
  fi

  # Officer type
  TYPE=$(grep "^  ${officer}:.*type:" "$CABINET_ROOT/instance/config/platform.yml" 2>/dev/null | grep -oP 'type:\s*\K\w+' || echo "fulltime")

  # Tool calls
  CALLS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:toolcalls:$officer" 2>/dev/null)
  [[ "$CALLS" =~ ^[0-9]+$ ]] || CALLS="-"

  # Context %
  CTX=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "cabinet:cost:tokens:$officer" last_context_pct 2>/dev/null)
  [[ "$CTX" =~ ^[0-9]+$ ]] || CTX="-"

  # Idle time
  LAST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:last-toolcall:$officer" 2>/dev/null)
  if [ -n "$LAST" ] && [ "$LAST" != "(nil)" ]; then
    LC_EPOCH=$(date -d "$LAST" +%s 2>/dev/null || echo 0)
    IDLE="$((( NOW_EPOCH - LC_EPOCH ) / 60))m"
  else
    IDLE="-"
  fi

  printf "%-6s %-8s %-10s %-8s %-6s %s\n" "$officer" "$STATUS" "$TYPE" "$CALLS" "${CTX}%" "$IDLE"
done
