#!/bin/bash
# cabinet/scripts/hooks/captain-reply-refine.sh — Spec 047 v2 Phase 2+3
#
# PreToolUse(reply) wrapper that runs the existing H1 (gate-language) +
# H2 (Captain-Posture) hooks BEFORE the Captain reply tool call lands,
# aggregates their flags, escalates to a Sonnet refine-pass when flags
# fire, and emits one consolidated `additionalContext` so the officer
# sees warnings + suggested rewrite BEFORE send.
#
# Per Captain msg 2042 anchor A6: minimal change. This wrapper invokes
# the existing H1/H2 scripts unmodified — no parallel orchestrator,
# no duplicate detection logic. The only structural change: H1/H2 move
# from PostToolUse(reply) → PreToolUse(reply) via this wrapper.
#
# Anti-FW-042 discipline preserved:
#   - Warn-only. NEVER exits non-zero. NEVER blocks the reply.
#   - Env-var disable: REPLY_REFINE_HOOK_ENABLED=0
#   - Iter-cap (default 3) enforced via /tmp/.captain-reply-iter-<officer>-<sha1>
#   - 50-char trivial-skip
#   - Audit log: cabinet/logs/captain-reply-reviews.jsonl
#
# Reversibility: drop the PreToolUse(reply) entry from settings.json,
# move H1+H2 back to PostToolUse(reply), rm this script + refine-pass.sh.

set -u

if [ "${REPLY_REFINE_HOOK_ENABLED:-1}" = "0" ]; then
  exit 0
fi

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
LOG_DIR="$REPO_ROOT/cabinet/logs"
AUDIT_LOG="$LOG_DIR/captain-reply-reviews.jsonl"
ITER_CAP="${REFINE_MAX_CYCLES:-3}"
TRIVIAL_THRESHOLD="${REFINE_TRIVIAL_CHARS:-50}"
PRODUCT_YML="$REPO_ROOT/instance/config/product.yml"
PLATFORM_YML="$REPO_ROOT/instance/config/platform.yml"

H1="$REPO_ROOT/cabinet/scripts/hooks/captain-gate-language.sh"
H2="$REPO_ROOT/cabinet/scripts/hooks/captain-posture-compliance.sh"
REFINE="$REPO_ROOT/cabinet/scripts/captain-rules/refine-pass.sh"

OFFICER="${OFFICER_NAME:-${CABINET_OFFICER:-unknown}}"
NOW_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

INPUT="$(cat)"
[ -z "$INPUT" ] && exit 0

CAPTAIN_CHAT_ID="$(grep -E '^[[:space:]]*captain_telegram_chat_id:' "$PRODUCT_YML" "$PLATFORM_YML" 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '"' | tr -d ' ')"
[ -z "$CAPTAIN_CHAT_ID" ] && exit 0
REPLY_CHAT_ID="$(printf '%s' "$INPUT" | jq -r '.tool_input.chat_id // empty' 2>/dev/null)"
[ "$REPLY_CHAT_ID" != "$CAPTAIN_CHAT_ID" ] && exit 0

DRAFT="$(printf '%s' "$INPUT" | jq -r '.tool_input.text // .tool_input.content // .tool_input.message // .tool_input.body // empty' 2>/dev/null)"
[ -z "$DRAFT" ] && exit 0

DRAFT_LEN="${#DRAFT}"
[ "$DRAFT_LEN" -lt "$TRIVIAL_THRESHOLD" ] && exit 0

# Run H1 + H2 against the same PreToolUse JSON; capture additionalContext.
H1_RAW="$(printf '%s' "$INPUT" | bash "$H1" 2>/dev/null || true)"
H2_RAW="$(printf '%s' "$INPUT" | bash "$H2" 2>/dev/null || true)"
H1_CTX="$(printf '%s' "$H1_RAW" | jq -r '.additionalContext // empty' 2>/dev/null)"
H2_CTX="$(printf '%s' "$H2_RAW" | jq -r '.additionalContext // empty' 2>/dev/null)"

if [ -z "$H1_CTX" ] && [ -z "$H2_CTX" ]; then
  exit 0
fi

FLAG_BLOCK=""
if [ -n "$H1_CTX" ]; then
  FLAG_BLOCK+="$H1_CTX"
fi
if [ -n "$H2_CTX" ]; then
  if [ -n "$FLAG_BLOCK" ]; then
    FLAG_BLOCK+=$'\n\n---\n\n'
  fi
  FLAG_BLOCK+="$H2_CTX"
fi

DRAFT_HASH="$(printf '%s' "$DRAFT" | sha1sum | awk '{print $1}')"
ITER_FILE="/tmp/.captain-reply-iter-$OFFICER-$DRAFT_HASH"
ITER=0
if [ -f "$ITER_FILE" ]; then
  ITER="$(cat "$ITER_FILE" 2>/dev/null | head -1 | tr -d '[:space:]' || echo 0)"
  case "$ITER" in
    ''|*[!0-9]*) ITER=0 ;;
  esac
fi
ITER=$((ITER + 1))
echo "$ITER" > "$ITER_FILE"

mkdir -p "$LOG_DIR" 2>/dev/null

if [ "$ITER" -gt "$ITER_CAP" ]; then
  WARN="<review-budget-exhausted: $((ITER - 1)) refine cycles, flags unresolved>

The following violations remained after $ITER_CAP refine cycles. Send the
draft as-is or rewrite manually before retrying.

$FLAG_BLOCK"

  AUDIT_LINE="$(jq -cn \
    --arg ts "$NOW_ISO" \
    --arg officer "$OFFICER" \
    --argjson iter "$ITER" \
    --arg draft "$DRAFT" \
    --arg flags "$FLAG_BLOCK" \
    --arg outcome "budget-exhausted" \
    '{ts:$ts, officer:$officer, iter_n:$iter, draft:$draft, flags:$flags, outcome:$outcome}' 2>/dev/null)"
  [ -n "$AUDIT_LINE" ] && echo "$AUDIT_LINE" >> "$AUDIT_LOG"

  jq -n --arg ctx "$WARN" '{additionalContext: $ctx}'
  rm -f "$ITER_FILE" 2>/dev/null
  exit 0
fi

REFINE_RESULT=""
if [ -x "$REFINE" ]; then
  REFINE_RESULT="$(bash "$REFINE" "$DRAFT" "$FLAG_BLOCK" 2>/dev/null)"
fi

SUGGESTED_REWRITE=""
FIX_SUMMARY=""
if [ -n "$REFINE_RESULT" ]; then
  SUGGESTED_REWRITE="$(printf '%s' "$REFINE_RESULT" | jq -r '.suggested_rewrite // empty' 2>/dev/null)"
  FIX_SUMMARY="$(printf '%s' "$REFINE_RESULT" | jq -r '.fix_summary // empty' 2>/dev/null)"
fi

WARN="🛑 CAPTAIN REPLY REFINE — flag(s) caught BEFORE send (cycle $ITER / $ITER_CAP)

$FLAG_BLOCK"

if [ -n "$SUGGESTED_REWRITE" ]; then
  WARN+=$'\n\n---\n\n📝 SUGGESTED REWRITE (Sonnet refine-pass)'
  if [ -n "$FIX_SUMMARY" ]; then
    WARN+=$'\n'"Fix summary: $FIX_SUMMARY"
  fi
  WARN+=$'\n\n'"$SUGGESTED_REWRITE"
  WARN+=$'\n\n---\n\nReview the rewrite, retry the reply tool with the new text (or revise further). Each retry counts as a cycle; cap '"$ITER_CAP"' total.'
else
  WARN+=$'\n\n(refine-pass unavailable; review the flags above and rewrite manually before retrying.)'
fi

AUDIT_LINE="$(jq -cn \
  --arg ts "$NOW_ISO" \
  --arg officer "$OFFICER" \
  --argjson iter "$ITER" \
  --arg draft "$DRAFT" \
  --arg flags "$FLAG_BLOCK" \
  --arg suggested_rewrite "$SUGGESTED_REWRITE" \
  --arg outcome "refine-suggested" \
  '{ts:$ts, officer:$officer, iter_n:$iter, draft:$draft, flags:$flags, suggested_rewrite:$suggested_rewrite, outcome:$outcome}' 2>/dev/null)"
[ -n "$AUDIT_LINE" ] && echo "$AUDIT_LINE" >> "$AUDIT_LOG"

jq -n --arg ctx "$WARN" '{additionalContext: $ctx}'
exit 0
