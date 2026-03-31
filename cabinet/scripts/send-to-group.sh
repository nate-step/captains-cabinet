#!/bin/bash
# send-to-group.sh — Send a message to the Warroom Telegram group
# Called by Officers via bash when they need to broadcast.
# Automatically sends a voice version if voice is enabled in config.
#
# Usage: send-to-group.sh "Your message here"
# Uses the calling Officer's bot token (TELEGRAM_BOT_TOKEN must be set)

MESSAGE="${1:?Usage: send-to-group.sh \"message\"}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set}"
TELEGRAM_HQ_CHAT_ID="${TELEGRAM_HQ_CHAT_ID:?TELEGRAM_HQ_CHAT_ID not set}"

# Send text message
RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="$TELEGRAM_HQ_CHAT_ID" \
  -d text="$MESSAGE" \
  -d parse_mode="HTML")

OK=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null)
if [ "$OK" = "true" ]; then
  echo "Message sent to Warroom group"
else
  echo "Failed to send: $RESPONSE" >&2
  exit 1
fi

# Auto-send voice if enabled (non-blocking, runs in background)
CONFIG_FILE="/opt/founders-cabinet/config/product.yml"
VOICE_ENABLED=$(grep -A1 "^voice:" "$CONFIG_FILE" 2>/dev/null | grep "enabled:" | awk '{print $2}' | tr -d ' ')
VOICE_MODE=$(grep -A4 "^voice:" "$CONFIG_FILE" 2>/dev/null | grep "mode:" | awk '{print $2}' | tr -d ' ')

if [ "$VOICE_ENABLED" = "true" ] && [ "$VOICE_MODE" = "all" -o "$VOICE_MODE" = "group" ]; then
  # Strip HTML tags for TTS (voice doesn't need formatting)
  PLAIN_TEXT=$(echo "$MESSAGE" | sed 's/<[^>]*>//g')
  bash /opt/founders-cabinet/cabinet/scripts/send-voice.sh "$TELEGRAM_HQ_CHAT_ID" "$PLAIN_TEXT" &
fi
