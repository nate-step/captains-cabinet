#!/bin/bash
# reply-to-captain.sh — Send a text + voice reply to the Captain's DM
# Use this INSTEAD of the Channels reply tool when voice is enabled.
# Falls back to text-only if voice is disabled or fails.
#
# Usage: reply-to-captain.sh "Your reply message"

MESSAGE="${1:?Usage: reply-to-captain.sh \"message\"}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set}"
CAPTAIN_TELEGRAM_ID="${CAPTAIN_TELEGRAM_ID:?CAPTAIN_TELEGRAM_ID not set}"

# Send text message
RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="$CAPTAIN_TELEGRAM_ID" \
  -d text="$MESSAGE" \
  -d parse_mode="HTML")

OK=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null)
if [ "$OK" = "true" ]; then
  echo "Reply sent to Captain"
else
  echo "Failed to send: $RESPONSE" >&2
  exit 1
fi

# Auto-send voice if enabled (non-blocking)
CONFIG_FILE="/opt/founders-cabinet/config/product.yml"
VOICE_ENABLED=$(grep -A1 "^voice:" "$CONFIG_FILE" 2>/dev/null | grep "enabled:" | awk '{print $2}' | tr -d ' ')
VOICE_MODE=$(grep -A4 "^voice:" "$CONFIG_FILE" 2>/dev/null | grep "mode:" | awk '{print $2}' | tr -d ' ')

if [ "$VOICE_ENABLED" = "true" ] && [ "$VOICE_MODE" = "all" -o "$VOICE_MODE" = "captain-dm" ]; then
  PLAIN_TEXT=$(echo "$MESSAGE" | sed 's/<[^>]*>//g')
  bash /opt/founders-cabinet/cabinet/scripts/send-voice.sh "$CAPTAIN_TELEGRAM_ID" "$PLAIN_TEXT" &
fi
