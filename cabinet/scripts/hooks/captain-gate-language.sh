#!/bin/bash
# cabinet/scripts/hooks/captain-gate-language.sh — Spec 043 H1
#
# Soft-warn detector for gate-language in Captain replies. Catches the
# "awaiting your sign-off / OK to proceed?" instinct that has cost the
# Captain decision budget on reversible work (msg 1791, 1935, 1968).
#
# Wired as PostToolUse(mcp__plugin_telegram_telegram__reply). Fires after
# the reply is sent. Surfaces a system-reminder in the next turn so the
# officer can self-correct via the captain-autonomy-discipline skill —
# "Scratch that — shipping it. Reversible."
#
# Spec 043 AC #1, #6, #9, #10. Anti-FW-042 discipline:
#   - Warn-only. NEVER exits non-zero. NEVER blocks the tool.
#   - Env-var disable: GATE_LANGUAGE_HOOK_ENABLED=0
#   - FP-rate logging to cabinet/logs/hook-fires/captain-gate-language.jsonl
#   - All match decisions get logged with the matched phrase for analysis.
#
# Reversibility: rm this file + drop the settings.json registration.

set -u

# Emergency kill switch.
if [ "${GATE_LANGUAGE_HOOK_ENABLED:-1}" = "0" ]; then
  exit 0
fi

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
LOG_DIR="$REPO_ROOT/cabinet/logs/hook-fires"
LOG_FILE="$LOG_DIR/captain-gate-language.jsonl"
PRODUCT_YML="$REPO_ROOT/instance/config/product.yml"
PLATFORM_YML="$REPO_ROOT/instance/config/platform.yml"

OFFICER="${OFFICER_NAME:-${CABINET_OFFICER:-unknown}}"
NOW_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

INPUT="$(cat)"
[ -z "$INPUT" ] && exit 0

# Captain Telegram chat_id — load from instance config. If missing, the H2
# default-deny stance applies: don't fire (we can't tell Captain DMs apart
# from group @-mentions or other-user DMs).
CAPTAIN_CHAT_ID="$(grep -E '^[[:space:]]*captain_telegram_chat_id:' "$PRODUCT_YML" "$PLATFORM_YML" 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '"' | tr -d ' ')"
if [ -z "$CAPTAIN_CHAT_ID" ]; then
  exit 0
fi

# Extract reply text + chat_id from PostToolUse JSON.
REPLY_TEXT="$(printf '%s' "$INPUT" | jq -r '.tool_input.text // .tool_input.content // .tool_input.message // .tool_input.body // empty' 2>/dev/null)"
REPLY_CHAT_ID="$(printf '%s' "$INPUT" | jq -r '.tool_input.chat_id // empty' 2>/dev/null)"

# Captain-only: chat_id must match. Skip group/other-user replies silently.
if [ -z "$REPLY_TEXT" ] || [ "$REPLY_CHAT_ID" != "$CAPTAIN_CHAT_ID" ]; then
  exit 0
fi

# Lowercase text for case-insensitive scan.
REPLY_LOWER="$(printf '%s' "$REPLY_TEXT" | tr '[:upper:]' '[:lower:]')"

# Gate-language phrases — sourced at run-time from the canonical skill at
# memory/skills/evolved/captain-autonomy-discipline.md per Spec 043 §H1
# amendment. Adding a new phrase to the skill's "Pre-send gate-language
# detector" section automatically propagates to this hook without code or
# spec edits. Falls back to a hardcoded 6 if the skill file is missing.
SKILL_FILE="$REPO_ROOT/memory/skills/evolved/captain-autonomy-discipline.md"
PHRASES=()
if [ -r "$SKILL_FILE" ]; then
  # Extract every double-quoted string from the gate-language detector
  # section. awk pulls the section between "## Pre-send gate-language
  # detector" and the next "## ..." heading; grep extracts the quoted
  # phrases; tr lowercases for case-insensitive comparison; sort -u dedupes.
  while IFS= read -r phrase; do
    [ -n "$phrase" ] && PHRASES+=("$phrase")
  done < <(awk '/^## Pre-send gate-language detector/{flag=1; next} /^## /{flag=0} flag' "$SKILL_FILE" \
    | grep -oE '"[^"]+"' | tr -d '"' | tr '[:upper:]' '[:lower:]' | sort -u)
fi
# Fallback: spec's original 6 phrases (case-insensitive substring).
if [ ${#PHRASES[@]} -eq 0 ]; then
  PHRASES=(
    "for your sign-off"
    "awaiting your reply"
    "ok to proceed?"
    "ready for your review"
    "want me to wait"
    "pending your sign-off"
  )
fi

MATCHED=""
for phrase in "${PHRASES[@]}"; do
  if printf '%s' "$REPLY_LOWER" | grep -qF "$phrase"; then
    MATCHED="$phrase"
    break
  fi
done

if [ -z "$MATCHED" ]; then
  exit 0
fi

# Build the cross-reference. Prefer query.sh-resolved A1 if available
# (Spec 042 Phase 2 query.sh ships this). Fall back to a static reference
# if query.sh is missing or fails.
A1_CONTEXT="A1 (Reversibility-gated autonomy): Default = SHIP, not GATE. If reversible in <5 min, CoS owns the call. Only gate Captain on genuinely irreversible actions."
QUERY_SH="$REPO_ROOT/cabinet/scripts/captain-rules/query.sh"
if [ -x "$QUERY_SH" ]; then
  RESOLVED="$(QUERY_TOP_N=0 bash "$QUERY_SH" "$OFFICER" "$REPLY_TEXT" 2>/dev/null | grep -A1 '^  A1' | head -2 | xargs)"
  if [ -n "$RESOLVED" ]; then
    A1_CONTEXT="$RESOLVED"
  fi
fi

# Truncate the reply excerpt to keep the warn payload compact.
EXCERPT="$(printf '%s' "$REPLY_TEXT" | head -c 200 | tr '\n' ' ' | head -c 200)"

# Log to FP-rate JSONL — every fire gets one line.
mkdir -p "$LOG_DIR" 2>/dev/null
LOG_LINE="$(jq -cn \
  --arg ts "$NOW_ISO" \
  --arg officer "$OFFICER" \
  --arg phrase "$MATCHED" \
  --arg excerpt "$EXCERPT" \
  --arg chat_id "$REPLY_CHAT_ID" \
  '{ts:$ts, hook:"captain-gate-language", officer:$officer, matched_phrase:$phrase, excerpt:$excerpt, chat_id:$chat_id}' 2>/dev/null)"
[ -n "$LOG_LINE" ] && echo "$LOG_LINE" >> "$LOG_FILE"

# Build the warning system-reminder.
WARN="GATE-LANGUAGE DETECTED in Captain reply.

Matched phrase: \"$MATCHED\"
Excerpt: \"$EXCERPT\"

$A1_CONTEXT

If the action is reversible in <5 min (schema migration, branch ops, file edits, MCP scope, /tasks creation, sync-framework run): self-correct via the captain-autonomy-discipline skill — send a follow-up \"Scratch that — shipping it. Reversible.\" Don't leave Captain holding a non-question.

If genuinely irreversible (payments, public announcements, production DELETE, contracts, relationship-shifting): the gate is correct. Make irreversibility explicit in the next reply.

Hook: warn-only. Disable via GATE_LANGUAGE_HOOK_ENABLED=0."

# Emit the additionalContext JSON for next-turn injection.
jq -n --arg ctx "$WARN" '{additionalContext: $ctx}'
exit 0
