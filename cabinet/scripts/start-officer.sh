#!/bin/bash
OFFICER="${1:?Usage: start-officer.sh <cos|cto|cro|cpo>}"
case "$OFFICER" in
  cos) BOT_TOKEN="${TELEGRAM_COS_TOKEN:?not set}" ;;
  cto) BOT_TOKEN="${TELEGRAM_CTO_TOKEN:?not set}" ;;
  cro) BOT_TOKEN="${TELEGRAM_CRO_TOKEN:?not set}" ;;
  cpo) BOT_TOKEN="${TELEGRAM_CPO_TOKEN:?not set}" ;;
  *) echo "Unknown: $OFFICER"; exit 1 ;;
esac

WINDOW="officer-$OFFICER"
STATE_DIR="/home/cabinet/.claude-channels/$OFFICER"
mkdir -p "$STATE_DIR/telegram"
echo "TELEGRAM_BOT_TOKEN=$BOT_TOKEN" > "$STATE_DIR/telegram/.env"

# Kill any existing session for this officer
tmux kill-window -t "cabinet:$WINDOW" 2>/dev/null

tmux new-window -t cabinet -n "$WINDOW"
tmux send-keys -t "cabinet:$WINDOW" \
  "export OFFICER_NAME=$OFFICER TELEGRAM_STATE_DIR=$STATE_DIR TELEGRAM_BOT_TOKEN=$BOT_TOKEN TELEGRAM_HQ_CHAT_ID=\$TELEGRAM_HQ_CHAT_ID && cd /opt/founders-cabinet && claude --continue --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions --effort max" \
  Enter

echo "Started $OFFICER in cabinet:$WINDOW"
