#!/bin/bash
# post-reply-memory.sh — Embed outgoing Telegram replies to Cabinet Memory
# Triggered by PostToolUse hook with matcher "reply" (Channels plugin)
# Claude Code passes JSON on stdin: { tool_name, tool_input, tool_response }

HOOK_INPUT=$(cat)
OFFICER="${OFFICER_NAME:-unknown}"

# Extract the reply text (same extraction logic as post-reply-voice.sh)
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

# Extract chat_id and message_id for metadata
CHAT_ID=$(echo "$HOOK_INPUT" | jq -r '.tool_input.chat_id // empty' 2>/dev/null)
REPLY_TO=$(echo "$HOOK_INPUT" | jq -r '.tool_input.reply_to // empty' 2>/dev/null)

if [ -z "$REPLY_TEXT" ] || [ "$REPLY_TEXT" = "null" ]; then
  exit 0
fi

# Source memory library
if [ ! -f /opt/founders-cabinet/cabinet/scripts/lib/memory.sh ]; then
  exit 0
fi

# Run embed in background so hook doesn't block
(
  set -a
  source /opt/founders-cabinet/cabinet/.env 2>/dev/null
  set +a
  source /opt/founders-cabinet/cabinet/scripts/lib/memory.sh

  if ! declare -f memory_queue_embed > /dev/null; then
    exit 0
  fi

  source_id="tg-out-$(date -u +%Y%m%dT%H%M%S)-${OFFICER}"
  metadata=$(jq -nc \
    --arg chat_id "$CHAT_ID" \
    --arg reply_to "$REPLY_TO" \
    --arg direction "outgoing" \
    '{chat_id: $chat_id, reply_to: $reply_to, direction: $direction}')

  memory_queue_embed "telegram_dm" "$source_id" "$OFFICER" "$OFFICER" \
    "$REPLY_TEXT" "$metadata" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
) > /dev/null 2>&1 &

exit 0
