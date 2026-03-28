#!/bin/bash
# start-officer.sh — Start a single Officer in a tmux window
# Usage: ./start-officer.sh <officer-name>
# Example: ./start-officer.sh cos

set -e

OFFICER="${1:?Usage: start-officer.sh <cos|cto|cro|cpo>}"

# Map officer to environment variables
case "$OFFICER" in
  cos)
    TOKEN_VAR="TELEGRAM_COS_TOKEN"
    BOT_TOKEN="${TELEGRAM_COS_TOKEN:?TELEGRAM_COS_TOKEN not set}"
    ;;
  cto)
    TOKEN_VAR="TELEGRAM_CTO_TOKEN"
    BOT_TOKEN="${TELEGRAM_CTO_TOKEN:?TELEGRAM_CTO_TOKEN not set}"
    ;;
  cro)
    TOKEN_VAR="TELEGRAM_CRO_TOKEN"
    BOT_TOKEN="${TELEGRAM_CRO_TOKEN:?TELEGRAM_CRO_TOKEN not set}"
    ;;
  cpo)
    TOKEN_VAR="TELEGRAM_CPO_TOKEN"
    BOT_TOKEN="${TELEGRAM_CPO_TOKEN:?TELEGRAM_CPO_TOKEN not set}"
    ;;
  *)
    echo "Unknown officer: $OFFICER"
    echo "Valid officers: cos, cto, cro, cpo"
    exit 1
    ;;
esac

STATE_DIR="/home/cabinet/.claude-channels/$OFFICER"
WINDOW_NAME="officer-$OFFICER"

echo "Starting Officer: $OFFICER"
echo "  Telegram token: ${BOT_TOKEN:0:10}..."
echo "  State dir: $STATE_DIR"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Write the bot token to the officer-specific state directory
mkdir -p "$STATE_DIR/telegram"
echo "TELEGRAM_BOT_TOKEN=$BOT_TOKEN" > "$STATE_DIR/telegram/.env"

# Check if tmux window already exists
if tmux list-windows -t cabinet 2>/dev/null | grep -q "$WINDOW_NAME"; then
  echo "Window $WINDOW_NAME already exists. Kill it first with:"
  echo "  tmux kill-window -t cabinet:$WINDOW_NAME"
  exit 1
fi

# Create a new tmux window for this Officer
tmux new-window -t cabinet -n "$WINDOW_NAME"

# Send the launch command to the tmux window
# TELEGRAM_STATE_DIR tells the plugin where to find its config
# OFFICER_NAME is used by hooks for logging and trigger delivery
# TELEGRAM_BOT_TOKEN + TELEGRAM_HQ_CHAT_ID are used by send-to-group.sh
tmux send-keys -t "cabinet:$WINDOW_NAME" \
  "export TELEGRAM_STATE_DIR=$STATE_DIR && export OFFICER_NAME=$OFFICER && export TELEGRAM_BOT_TOKEN=$BOT_TOKEN && export TELEGRAM_HQ_CHAT_ID=${TELEGRAM_HQ_CHAT_ID} && cd /opt/founders-cabinet && claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions" \
  Enter

echo "Officer $OFFICER started in tmux window: cabinet:$WINDOW_NAME"
echo ""
echo "To attach: tmux attach -t cabinet:$WINDOW_NAME"
echo "To pair Telegram: DM the bot, then run the pairing command in the session"
