#!/bin/bash
# send-voice.sh — Generate and send a voice message via Telegram
# Uses ElevenLabs TTS to convert text to audio, then sends via Telegram Bot API.
# Optionally rewrites structured text into natural speech via Haiku before TTS.
#
# Usage: send-voice.sh <chat_id> "Your message text" ["context/captain's message"]
# Optional: VOICE_ID env var overrides the officer's configured voice
#
# Requires: ELEVENLABS_API_KEY, TELEGRAM_BOT_TOKEN in environment
# Optional: ANTHROPIC_API_KEY for voice.naturalize feature
# Voice IDs configured in config/product.yml under voice.voices.<officer>

CHAT_ID="${1:?Usage: send-voice.sh <chat_id> \"message text\"}"
TEXT="${2:?Usage: send-voice.sh <chat_id> \"message text\"}"
CONTEXT="${3:-}"

ELEVENLABS_API_KEY="${ELEVENLABS_API_KEY:?ELEVENLABS_API_KEY not set}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set}"
OFFICER="${OFFICER_NAME:-unknown}"

# Read voice config from product.yml
CONFIG_FILE="/opt/founders-cabinet/config/product.yml"

# --- YAML parsing helpers ---
# All config reads use awk with section isolation to avoid cross-section bleed.
# Pattern: enter voice block on ^voice:, enter subsection on indented key, exit on next sibling.
voice_field() {
  awk '/^voice:/{v=1} v && /^  '"$1"':/{print $2;exit}' "$CONFIG_FILE" | tr -d ' '
}
voice_subsection_field() {
  local section="$1" key="$2"
  awk '/^voice:/{v=1} v && /^  '"$section"':/{s=1;next} v && s && /'"$key"':/{print $2;exit} v && s && /^  [a-z]/{exit}' "$CONFIG_FILE" | tr -d '"' | tr -d "'"
}
voice_subsection_value() {
  local section="$1" key="$2"
  awk '/^voice:/{v=1} v && /^  '"$section"':/{s=1;next} v && s && /'"$key"':/{sub(/^[[:space:]]*'"$key"':[[:space:]]*/,"");print;exit} v && s && /^  [a-z]/{exit}' "$CONFIG_FILE" | tr -d '"' | tr -d "'"
}

# Check if voice is enabled
VOICE_ENABLED=$(voice_field "enabled")
if [ "$VOICE_ENABLED" != "true" ]; then
  echo "Voice messages disabled in config/product.yml"
  exit 0
fi

# Get voice ID for this officer (can be overridden by VOICE_ID env var)
if [ -z "$VOICE_ID" ]; then
  VOICE_ID=$(voice_subsection_field "voices" "$OFFICER")
fi

if [ -z "$VOICE_ID" ]; then
  echo "No voice_id configured for $OFFICER in config/product.yml"
  exit 1
fi

# Get model: check per-officer override in voice.models, then global default
OFFICER_MODEL=$(voice_subsection_field "models" "$OFFICER")
if [ -n "$OFFICER_MODEL" ]; then
  MODEL="$OFFICER_MODEL"
else
  MODEL=$(voice_field "model")
  MODEL="${MODEL:-eleven_flash_v2_5}"
fi

# --- Naturalize text for speech ---
# Rewrites structured messages into natural spoken language using Haiku.
# Controlled by voice.naturalize in config. Falls back to original text on failure.
naturalize_for_speech() {
  local input="$1"
  local prompt="$2"
  local context="$3"

  if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "$input"
    return
  fi

  local system_prompt="You rewrite structured messages into natural spoken language for text-to-speech.

Rules:
- Output ONLY the rewritten text, nothing else
- Remove ticket IDs (SEN-xxx), PR numbers (#xxx), technical references
- Convert bullet points and lists into flowing sentences
- Keep it brief — a quick verbal update, not a report
- Preserve the meaning and all key information
- No emojis, no markdown, no special characters
- Use natural transitions (\"also\", \"and\", \"meanwhile\")
- Speak as the officer would to their Captain in a quick huddle"

  if [ -n "$prompt" ]; then
    system_prompt="${system_prompt}
- Additional style instruction: ${prompt}"
  fi

  # Build user message with optional context
  local user_content="$input"
  if [ -n "$context" ]; then
    user_content="The Captain said: ${context}

The officer's reply (rewrite this for speech):
${input}"
  fi

  local response
  response=$(curl -s --max-time 10 \
    -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{
      \"model\": \"claude-haiku-4-5-20251001\",
      \"max_tokens\": 1024,
      \"system\": $(echo "$system_prompt" | jq -Rs '.'),
      \"messages\": [{
        \"role\": \"user\",
        \"content\": $(echo "$user_content" | jq -Rs '.')
      }]
    }" 2>/dev/null)

  local naturalized
  naturalized=$(echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null)

  if [ -n "$naturalized" ]; then
    echo "$naturalized"
  else
    echo "$input"
  fi
}

# Check if naturalization is enabled
NATURALIZE=$(voice_field "naturalize")
if [ "$NATURALIZE" = "true" ]; then
  NATURALIZE_PROMPT=$(voice_subsection_value "naturalize_prompts" "$OFFICER")
  TEXT=$(naturalize_for_speech "$TEXT" "$NATURALIZE_PROMPT" "$CONTEXT")
fi

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
