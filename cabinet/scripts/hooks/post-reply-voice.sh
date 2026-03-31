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

  # Try to get Captain's last message from MCP logs for context
  CAPTAIN_MSG=""
  LOG_DIR="/home/cabinet/.cache/claude-cli-nodejs/-opt-founders-cabinet-officers-${OFFICER}/mcp-logs-plugin-telegram-telegram"
  if [ -d "$LOG_DIR" ]; then
    LATEST_LOG=$(ls -t "$LOG_DIR"/*.jsonl 2>/dev/null | head -1)
    if [ -n "$LATEST_LOG" ]; then
      CAPTAIN_MSG=$(grep 'notifications/claude/channel:' "$LATEST_LOG" 2>/dev/null | tail -1 | sed 's/.*notifications\/claude\/channel: //' | sed 's/",.*//' | tr -d '"')
    fi
  fi

  bash /opt/founders-cabinet/cabinet/scripts/send-voice.sh "$CAPTAIN_TELEGRAM_ID" "$PLAIN_TEXT" "$CAPTAIN_MSG" > /dev/null 2>&1 &
fi

exit 0
