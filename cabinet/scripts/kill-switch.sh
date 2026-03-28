#!/bin/bash
# kill-switch.sh — Emergency halt / resume for all Officers
# Usage: kill-switch.sh activate | deactivate | status

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

ACTION="${1:?Usage: kill-switch.sh activate|deactivate|status}"

case "$ACTION" in
  activate)
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET cabinet:killswitch active > /dev/null
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') — KILL SWITCH ACTIVATED"
    echo "All Officer operations will halt on their next tool invocation."
    ;;
  deactivate)
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL cabinet:killswitch > /dev/null
    echo "$(date -u '+%Y-%m-%d %H:%M:%S UTC') — KILL SWITCH DEACTIVATED"
    echo "Officers will resume normal operation."
    ;;
  status)
    STATE=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
    if [ "$STATE" = "active" ]; then
      echo "Kill switch: ACTIVE (all operations halted)"
    else
      echo "Kill switch: INACTIVE (normal operation)"
    fi
    ;;
  *)
    echo "Usage: kill-switch.sh activate|deactivate|status"
    exit 1
    ;;
esac
