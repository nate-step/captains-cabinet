#!/bin/bash
# post-reply-voice.sh — Auto-send voice message after Channels plugin reply
# Triggered by PostToolUse hook with matcher "reply"
# Claude Code passes JSON on stdin: { tool_name, tool_input, tool_response }

HOOK_INPUT=$(cat)
OFFICER="${OFFICER_NAME:-unknown}"

# Check if voice is enabled
CONFIG_FILE="/opt/founders-cabinet/config/product.yml"
VOICE_ENABLED=$(grep -A1 "^voice:" "$CONFIG_FILE" 2>/dev/null | grep "enabled:" | awk '{print $2}' | tr -d ' ')
if [ "$VOICE_ENABLED" != "true" ]; then
  exit 0
fi

# Check voice mode — for reply tool, this is a Captain DM
VOICE_MODE=$(grep -A4 "^voice:" "$CONFIG_FILE" 2>/dev/null | grep "mode:" | awk '{print $2}' | tr -d ' ')
if [ "$VOICE_MODE" != "all" ] && [ "$VOICE_MODE" != "captain-dm" ]; then
  exit 0
fi

# Extract the reply text from tool input
# The Channels reply tool input may have various field names
REPLY_TEXT=$(echo "$HOOK_INPUT" | jq -r '
  .tool_input |
  if type == "string" then .
  elif .text then .text
  elif .content then .content
  elif .message then .message
  elif .body then .body
  else empty
  end
' 2>/dev/null)

if [ -z "$REPLY_TEXT" ] || [ "$REPLY_TEXT" = "null" ]; then
  exit 0
fi

# Send voice message in background (don't block the hook)
CAPTAIN_TELEGRAM_ID="${CAPTAIN_TELEGRAM_ID:-}"
if [ -n "$CAPTAIN_TELEGRAM_ID" ]; then
  # Strip any HTML tags for clean TTS
  PLAIN_TEXT=$(echo "$REPLY_TEXT" | sed 's/<[^>]*>//g')
  bash /opt/founders-cabinet/cabinet/scripts/send-voice.sh "$CAPTAIN_TELEGRAM_ID" "$PLAIN_TEXT" > /dev/null 2>&1 &
fi

exit 0
