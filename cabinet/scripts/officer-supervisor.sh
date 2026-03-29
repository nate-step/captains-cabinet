#!/bin/bash
# officer-supervisor.sh — Background loop inside the Officers container.
# Checks every 2 minutes if any Officer tmux windows have died, restarts them.
# Started by entrypoint.sh as a background process.

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

OFFICERS=("cos" "cto" "cro" "cpo")
CHECK_INTERVAL=120  # 2 minutes
RESTART_COOLDOWN=300  # 5 minutes between restarts of the same officer

log() {
  echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [supervisor] $1"
}

get_token_var() {
  case "$1" in
    cos) echo "TELEGRAM_COS_TOKEN" ;;
    cto) echo "TELEGRAM_CTO_TOKEN" ;;
    cro) echo "TELEGRAM_CRO_TOKEN" ;;
    cpo) echo "TELEGRAM_CPO_TOKEN" ;;
  esac
}

send_restart_alert() {
  local officer="$1"
  local reason="$2"
  local token="${TELEGRAM_COS_TOKEN:-}"
  local captain="${CAPTAIN_TELEGRAM_ID:-}"
  [ -z "$token" ] || [ -z "$captain" ] && return

  curl -s -X POST "https://api.telegram.org/bot${token}/sendMessage" \
    -d chat_id="$captain" \
    -d text="🔄 Auto-restart: *${officer}* — ${reason}" \
    -d parse_mode="Markdown" > /dev/null 2>&1
}

log "Officer supervisor starting. Check interval: ${CHECK_INTERVAL}s"

while true; do
  sleep "$CHECK_INTERVAL"

  # Check kill switch — don't restart if Cabinet is halted
  KILLSWITCH=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
  if [ "$KILLSWITCH" = "active" ]; then
    log "Kill switch active — skipping restart checks"
    continue
  fi

  for officer in "${OFFICERS[@]}"; do
    WINDOW="officer-$officer"

    # Only check officers marked as expected-active
    EXPECTED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:officer:expected:$officer" 2>/dev/null)
    [ "$EXPECTED" != "active" ] && continue

    # Check cooldown — don't restart too fast
    LAST_RESTART=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:supervisor:last-restart:$officer" 2>/dev/null)
    NOW=$(date +%s)
    if [ -n "$LAST_RESTART" ] && [ "$LAST_RESTART" != "" ]; then
      ELAPSED=$((NOW - LAST_RESTART))
      if [ "$ELAPSED" -lt "$RESTART_COOLDOWN" ]; then
        continue
      fi
    fi

    # Check if the tmux window exists
    if ! tmux has-session -t cabinet 2>/dev/null; then
      log "CRITICAL: tmux session 'cabinet' is gone! Recreating..."
      tmux new-session -d -s cabinet -n main
      # All officers need restart
      for o in "${OFFICERS[@]}"; do
        E=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:officer:expected:$o" 2>/dev/null)
        if [ "$E" = "active" ]; then
          log "Restarting $o after tmux session recovery"
          /home/cabinet/start-officer.sh "$o"
          redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:supervisor:last-restart:$o" "$NOW" EX 600 > /dev/null 2>&1
          redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INCR "cabinet:supervisor:restart-count:$o" > /dev/null 2>&1
          send_restart_alert "$o" "tmux session lost, recovered"
          sleep 5  # stagger restarts
        fi
      done
      break  # skip individual checks, we just restarted everything
    fi

    # Check if this officer's window exists
    if ! tmux list-windows -t cabinet -F '#{window_name}' 2>/dev/null | grep -q "^${WINDOW}$"; then
      log "Window '$WINDOW' missing — restarting $officer"
      /home/cabinet/start-officer.sh "$officer"
      redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:supervisor:last-restart:$officer" "$NOW" EX 600 > /dev/null 2>&1
      redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INCR "cabinet:supervisor:restart-count:$officer" > /dev/null 2>&1
      send_restart_alert "$officer" "tmux window disappeared"
      continue
    fi

    # Check if the process in the window is still alive (not just a dead shell)
    OFFICER_ALIVE=false
    PANE_PID=$(tmux list-panes -t "cabinet:$WINDOW" -F '#{pane_pid}' 2>/dev/null | head -1)
    if [ -n "$PANE_PID" ]; then
      # Check if the pane has child processes (claude should be running)
      CHILDREN=$(ps --ppid "$PANE_PID" -o pid= 2>/dev/null | wc -l)
      if [ "$CHILDREN" -eq 0 ]; then
        # Shell exists but claude isn't running — check if pane shows a prompt
        # (capture last line of the pane)
        LAST_LINE=$(tmux capture-pane -t "cabinet:$WINDOW" -p -S -1 2>/dev/null | tail -1)
        if echo "$LAST_LINE" | grep -qE '(\$|#|>)\s*$'; then
          log "Officer $officer window alive but claude exited — restarting"
          tmux kill-window -t "cabinet:$WINDOW" 2>/dev/null
          sleep 2
          /home/cabinet/start-officer.sh "$officer"
          redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:supervisor:last-restart:$officer" "$NOW" EX 600 > /dev/null 2>&1
          redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INCR "cabinet:supervisor:restart-count:$officer" > /dev/null 2>&1
          send_restart_alert "$officer" "claude process exited"
          continue
        fi
      else
        OFFICER_ALIVE=true
      fi
    fi

    # Refresh heartbeat for alive officers — prevents false health alerts
    # when an officer is idle (waiting for Telegram messages, no tool calls).
    # The post-tool-use hook also sets this, but idle officers need coverage too.
    if [ "$OFFICER_ALIVE" = true ]; then
      TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:heartbeat:$officer" "$TIMESTAMP" EX 900 > /dev/null 2>&1
    fi
  done
done
