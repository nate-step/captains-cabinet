#!/bin/bash
# send-to-group.sh — Send a message to the Sensed HQ Telegram group
# Called by Officers via bash when they need to broadcast.
#
# Usage: send-to-group.sh "Your message here"
# Uses the calling Officer's bot token (TELEGRAM_BOT_TOKEN must be set)

MESSAGE="${1:?Usage: send-to-group.sh \"message\"}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set}"
TELEGRAM_HQ_CHAT_ID="${TELEGRAM_HQ_CHAT_ID:?TELEGRAM_HQ_CHAT_ID not set}"

RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="$TELEGRAM_HQ_CHAT_ID" \
  -d text="$MESSAGE" \
  -d parse_mode="Markdown")

# Check success
OK=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null)
if [ "$OK" = "true" ]; then
  echo "Message sent to Sensed HQ group"
else
  echo "Failed to send: $RESPONSE" >&2
  exit 1
fi
