#!/bin/bash
# send-voice.sh — Generate and send a voice message via Telegram
# Uses ElevenLabs TTS to convert text to audio, then sends via Telegram Bot API.
#
# Usage: send-voice.sh <chat_id> "Your message text"
# Optional: VOICE_ID env var overrides the officer's configured voice
#
# Requires: ELEVENLABS_API_KEY, TELEGRAM_BOT_TOKEN in environment
# Voice IDs configured in config/product.yml under voice.voices.<officer>

CHAT_ID="${1:?Usage: send-voice.sh <chat_id> \"message text\"}"
TEXT="${2:?Usage: send-voice.sh <chat_id> \"message text\"}"

ELEVENLABS_API_KEY="${ELEVENLABS_API_KEY:?ELEVENLABS_API_KEY not set}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set}"
OFFICER="${OFFICER_NAME:-unknown}"

# Read voice config from product.yml
CONFIG_FILE="/opt/founders-cabinet/config/product.yml"

# Check if voice is enabled
VOICE_ENABLED=$(grep -A1 "^voice:" "$CONFIG_FILE" | grep "enabled:" | awk '{print $2}' | tr -d ' ')
if [ "$VOICE_ENABLED" != "true" ]; then
  echo "Voice messages disabled in config/product.yml"
  exit 0
fi

# Get voice ID for this officer (can be overridden by VOICE_ID env var)
if [ -z "$VOICE_ID" ]; then
  VOICE_ID=$(grep -A10 "voices:" "$CONFIG_FILE" | grep "${OFFICER}:" | awk '{print $2}' | tr -d '"' | tr -d "'")
fi

if [ -z "$VOICE_ID" ]; then
  echo "No voice_id configured for $OFFICER in config/product.yml"
  exit 1
fi

# Get model from config (default: eleven_flash_v2_5)
MODEL=$(grep -A5 "^voice:" "$CONFIG_FILE" | grep "model:" | awk '{print $2}' | tr -d ' ')
MODEL="${MODEL:-eleven_flash_v2_5}"

# Generate audio via ElevenLabs
TMPFILE=$(mktemp /tmp/voice-XXXXXX.mp3)

HTTP_CODE=$(curl -s -w "%{http_code}" -o "$TMPFILE" \
  -X POST "https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID}" \
  -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{
    \"text\": $(echo "$TEXT" | jq -Rs '.'),
    \"model_id\": \"${MODEL}\",
    \"voice_settings\": {
      \"stability\": 0.5,
      \"similarity_boost\": 0.75
    }
  }")

if [ "$HTTP_CODE" != "200" ]; then
  echo "ElevenLabs API error (HTTP $HTTP_CODE)" >&2
  rm -f "$TMPFILE"
  exit 1
fi

# Send voice message via Telegram
RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendVoice" \
  -F chat_id="$CHAT_ID" \
  -F voice=@"$TMPFILE")

rm -f "$TMPFILE"

OK=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null)
if [ "$OK" = "true" ]; then
  echo "Voice message sent"
else
  echo "Failed to send voice: $RESPONSE" >&2
  exit 1
fi
