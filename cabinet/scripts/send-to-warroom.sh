#!/bin/bash
# send-to-warroom.sh — Send a message to a context-scoped Warroom.
#
# Phase 1 CP7 (Captain decision 2026-04-16 CD3 "auto-migrate").
# Existing send-to-group.sh wraps this script with context=sensed so no
# legacy call sites break. New callers should prefer send-to-warroom.sh
# directly with an explicit context.
#
# Mapping lives in instance/config/warrooms.yml:
#
#     sensed:   "<chat_id>"
#     step:     "<chat_id>"
#     personal: "<chat_id>"
#
# For Phase 1 only the `sensed` warroom exists; it maps to
# $TELEGRAM_HQ_CHAT_ID so the current container env keeps working.
# Adding a new warroom: declare the context_slug in
# instance/config/contexts/<slug>.yml AND add its chat_id here.
#
# Usage:
#   send-to-warroom.sh <context_slug> "<message>"
#
# Example:
#   send-to-warroom.sh sensed "Deploy green. PR 547 shipped."

CONTEXT="${1:?Usage: send-to-warroom.sh <context_slug> \"message\"}"
MESSAGE="${2:?Usage: send-to-warroom.sh <context_slug> \"message\"}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN not set}"
WARROOMS_FILE="/opt/founders-cabinet/instance/config/warrooms.yml"

# Resolve chat_id for the requested context. Fall back to
# $TELEGRAM_HQ_CHAT_ID when context=sensed and the mapping file is
# absent (back-compat with pre-CP7 setups).
resolve_chat_id() {
  local ctx="$1"
  if [ -f "$WARROOMS_FILE" ]; then
    # Flat yaml: "<slug>: <chat_id>" with optional quotes. Python stdlib
    # parse is more robust than custom awk and consistent with the rest
    # of the framework's yaml readers.
    local id
    id=$(python3 - "$WARROOMS_FILE" "$ctx" <<'PY' 2>/dev/null
import re, sys
path, key = sys.argv[1], sys.argv[2]
pat = re.compile(r'^' + re.escape(key) + r':\s*(.*?)\s*$')
with open(path) as f:
    for line in f:
        m = pat.match(line)
        if m:
            val = m.group(1).strip()
            # Strip surrounding matching quotes, either single or double.
            if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
                val = val[1:-1]
            print(val)
            break
PY
)
    if [ -n "$id" ]; then
      # Allow ${VAR} interpolation in the yaml value. Prefer envsubst
      # when available — it only substitutes variables, never executes.
      # Fallback: restrict to a single ${VAR} token pattern, else emit
      # as-is (a malicious $(cmd) passes through as literal text).
      if command -v envsubst >/dev/null 2>&1; then
        echo "$id" | envsubst
      else
        if echo "$id" | grep -qE '^\$\{[A-Za-z_][A-Za-z0-9_]*\}$'; then
          var_name=$(echo "$id" | sed 's/^\${//;s/}$//')
          eval "printf '%s' \"\${$var_name}\""
        else
          echo "$id"
        fi
      fi
      return 0
    fi
  fi
  if [ "$ctx" = "sensed" ] && [ -n "${TELEGRAM_HQ_CHAT_ID:-}" ]; then
    echo "$TELEGRAM_HQ_CHAT_ID"
    return 0
  fi
  return 1
}

CHAT_ID=$(resolve_chat_id "$CONTEXT")
if [ -z "$CHAT_ID" ]; then
  echo "ERROR: no warroom chat_id for context '$CONTEXT' — declare it in $WARROOMS_FILE" >&2
  exit 1
fi

# Send
RESPONSE=$(curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d text="$MESSAGE" \
  -d parse_mode="HTML")

OK=$(echo "$RESPONSE" | jq -r '.ok' 2>/dev/null)
if [ "$OK" = "true" ]; then
  echo "Message sent to $CONTEXT warroom"
else
  echo "Failed to send to $CONTEXT warroom: $RESPONSE" >&2
  exit 1
fi

# Auto-send voice if enabled (non-blocking)
CONFIG_FILE="/opt/founders-cabinet/instance/config/product.yml"
VOICE_ENABLED=$(grep -A1 "^voice:" "$CONFIG_FILE" 2>/dev/null | grep "enabled:" | awk '{print $2}' | tr -d ' ')
VOICE_MODE=$(grep -A4 "^voice:" "$CONFIG_FILE" 2>/dev/null | grep "mode:" | awk '{print $2}' | tr -d ' ')

if [ "$VOICE_ENABLED" = "true" ] && [ "$VOICE_MODE" = "all" -o "$VOICE_MODE" = "group" ]; then
  PLAIN_TEXT=$(echo "$MESSAGE" | sed 's/<[^>]*>//g')
  bash /opt/founders-cabinet/cabinet/scripts/send-voice.sh "$CHAT_ID" "$PLAIN_TEXT" &
fi
