#!/bin/bash
# cabinet/scripts/hooks/pre-captain-dm.sh — Spec 042 Phase 2 hook
#
# Wired as a UserPromptSubmit hook in .claude/settings.json. Fires on every
# user prompt; only acts when the prompt contains a Captain Telegram DM.
#
# Flow:
#   1. Read JSON stdin (`.prompt` is the user-prompt body).
#   2. If no <channel source="telegram"> tag → exit silently (no injection).
#   3. Capability gate: if officer lacks `captain_rules_retrieval`, exit silently.
#   4. 60s identical-DM dedup: skip injection if same DM body fired <60s ago.
#   5. Run cabinet/scripts/captain-rules/query.sh → structured block.
#   6. Emit JSON `{hookSpecificOutput: {additionalContext: "<system-reminder>...</system-reminder>"}}`.
#
# Failure modes are non-fatal: any error → empty stdout → no injection. The
# officer's reply happens normally; the rules just aren't auto-surfaced for
# that turn.
#
# Reversibility: rm this file + delete the UserPromptSubmit entry in
# .claude/settings.json → patterns + intents fall back to always-loaded.

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
QUERY_SH="$REPO_ROOT/cabinet/scripts/captain-rules/query.sh"
CAP_FILE="$REPO_ROOT/cabinet/officer-capabilities.conf"

# Officer slug — the runtime sets OFFICER_NAME (e.g. cto, cos, cpo).
OFFICER="${OFFICER_NAME:-${CABINET_OFFICER:-unknown}}"
DEDUP_WINDOW_SECONDS=60
DEDUP_FILE="/tmp/.captain-rules-last-block-$OFFICER"

# Read JSON stdin; jq is used everywhere else in the cabinet hooks for parsing.
INPUT="$(cat)"
if [ -z "$INPUT" ]; then
  exit 0
fi

# Extract the prompt body. jq returns "" on missing key, which is fine.
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)"
if [ -z "$PROMPT" ]; then
  exit 0
fi

# Detect a Captain Telegram DM. The cabinet wraps incoming Telegram messages
# in <channel source="telegram" ...> tags via the channels plugin. We look
# for that opening tag with chat_id matching the configured Captain chat.
if ! printf '%s' "$PROMPT" | grep -q '<channel source="telegram"'; then
  exit 0
fi

CAPTAIN_CHAT_ID="$(grep -E '^[[:space:]]*captain_telegram_chat_id:' "$REPO_ROOT/instance/config/product.yml" "$REPO_ROOT/instance/config/platform.yml" 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '"' | tr -d ' ')"
# Default-deny: missing captain_telegram_chat_id means we cannot tell Captain
# DMs from group @-mentions or other-user DMs. Refuse to inject rather than
# firing on every Telegram channel and polluting the officer's context.
if [ -z "$CAPTAIN_CHAT_ID" ]; then
  echo "[pre-captain-dm] WARN: captain_telegram_chat_id missing from instance/config/{product,platform}.yml — retrieval injection skipped" >&2
  exit 0
fi
if ! printf '%s' "$PROMPT" | grep -qE "<channel source=\"telegram\"[^>]*chat_id=\"$CAPTAIN_CHAT_ID\""; then
  # Telegram channel but not from Captain — skip silently.
  exit 0
fi

# Capability gate. Default ON for officers listed in the conf.
# -F (fixed-string) avoids regex metachar issues if OFFICER ever contains them.
if [ -f "$CAP_FILE" ]; then
  if ! grep -qxF "${OFFICER}:captain_rules_retrieval" "$CAP_FILE" 2>/dev/null; then
    exit 0
  fi
fi

# Extract the DM body (between the channel open tag and </channel>).
# Use python to handle multi-line bodies + escape chars cleanly.
DM_BODY="$(printf '%s' "$PROMPT" | python3 -c '
import sys, re
text = sys.stdin.read()
m = re.search(r"<channel source=\"telegram\"[^>]*>(.*?)</channel>", text, re.DOTALL)
sys.stdout.write(m.group(1).strip() if m else "")
' 2>/dev/null)"

if [ -z "$DM_BODY" ]; then
  exit 0
fi

# Spec 046 — voice flow parity. If the channel block carries a voice
# attachment, download it via Telegram Bot API, transcribe via Scribe,
# cache by message_id, and replace DM_BODY with the transcript so the
# downstream retrieval + dedup operate on the actual words instead of
# the literal "(voice message)" placeholder.
#
# Failure modes are non-fatal at every step: missing bot token, getFile
# error, download error, transcription error → DM_BODY keeps the
# placeholder, the existing flow continues (anchors-only retrieval).
#
# Env-var disable: VOICE_TRANSCRIBE_HOOK_ENABLED=0 skips the voice path.
VOICE_BLOCK=""
if [ "${VOICE_TRANSCRIBE_HOOK_ENABLED:-1}" != "0" ]; then
  VOICE_INFO="$(printf '%s' "$PROMPT" | python3 -c '
import sys, re
text = sys.stdin.read()
m = re.search(r"<channel source=\"telegram\"([^>]*)>", text)
if not m:
    sys.exit(0)
attrs = m.group(1)
def find_attr(name):
    am = re.search(name + r"=\"([^\"]*)\"", attrs)
    return am.group(1) if am else ""
kind = find_attr("attachment_kind")
mime = find_attr("attachment_mime")
file_id = find_attr("attachment_file_id")
msg_id = find_attr("message_id")
is_voice = kind == "voice" or mime.startswith("audio/")
if is_voice and file_id and msg_id:
    sys.stdout.write(file_id + "\t" + msg_id + "\t" + mime + "\t" + kind)
' 2>/dev/null)"

  if [ -n "$VOICE_INFO" ]; then
    IFS=$'\t' read -r FILE_ID MSG_ID MIME KIND <<< "$VOICE_INFO"
    CACHE_DIR="$REPO_ROOT/cabinet/cache/voice-transcripts"
    CACHE_FILE="$CACHE_DIR/$MSG_ID.txt"
    TRANSCRIPT=""

    # Cache hit (24h TTL per Spec 046 AC #9)?
    if [ -f "$CACHE_FILE" ]; then
      cache_age=$(( $(date +%s) - $(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ))
      if [ "$cache_age" -lt 86400 ]; then
        TRANSCRIPT="$(cat "$CACHE_FILE" 2>/dev/null)"
      fi
    fi

    # Cache miss → download + transcribe.
    if [ -z "$TRANSCRIPT" ] && [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
      mkdir -p "$CACHE_DIR" 2>/dev/null
      TMP_AUDIO="/tmp/.captain-voice-$$.audio"

      # Two-step Telegram download: getFile → file_path → download URL.
      FILE_PATH="$(curl -sS --max-time 10 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getFile?file_id=$FILE_ID" 2>/dev/null | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin).get("result", {})
    sys.stdout.write(r.get("file_path", ""))
except Exception:
    pass
' 2>/dev/null)"

      if [ -n "$FILE_PATH" ]; then
        VOICE_START_MS="$(date +%s%3N)"
        if curl -sS --max-time 30 -o "$TMP_AUDIO" "https://api.telegram.org/file/bot$TELEGRAM_BOT_TOKEN/$FILE_PATH" 2>/dev/null && [ -s "$TMP_AUDIO" ]; then
          TRANSCRIPT="$(bash "$REPO_ROOT/cabinet/scripts/transcribe-voice.sh" "$TMP_AUDIO" 2>/dev/null)"
          VOICE_END_MS="$(date +%s%3N)"
          VOICE_LATENCY_MS=$((VOICE_END_MS - VOICE_START_MS))
          if [ -n "$TRANSCRIPT" ]; then
            # Cache + cost log per Spec 046 AC #4 + #10.
            printf '%s' "$TRANSCRIPT" > "$CACHE_FILE"
            mkdir -p "$REPO_ROOT/cabinet/logs" 2>/dev/null
            AUDIO_BYTES="$(stat -c %s "$TMP_AUDIO" 2>/dev/null || echo 0)"
            VOICE_LOG="$(jq -cn \
              --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              --arg message_id "$MSG_ID" \
              --argjson audio_bytes "$AUDIO_BYTES" \
              --argjson latency_ms "$VOICE_LATENCY_MS" \
              '{ts:$ts, message_id:$message_id, audio_bytes:$audio_bytes, latency_ms:$latency_ms}' 2>/dev/null)"
            [ -n "$VOICE_LOG" ] && echo "$VOICE_LOG" >> "$REPO_ROOT/cabinet/logs/voice-transcripts.jsonl"
          fi
        fi
        rm -f "$TMP_AUDIO" 2>/dev/null
      fi
    fi

    # If we have a transcript, replace DM_BODY so retrieval matches against
    # actual words. Build a voice-header block; the additional-context emit
    # at the end concatenates it BEFORE the retrieval block per Spec 046 AC #5.
    if [ -n "$TRANSCRIPT" ]; then
      VOICE_BLOCK="$(printf '🎙️ VOICE TRANSCRIPT (auto-transcribed from Captain voice DM):\n\n%s\n\n(original "(voice message)" placeholder + audio attachment_file_id %s retained for fallback)' "$TRANSCRIPT" "$FILE_ID")"
      DM_BODY="$TRANSCRIPT"
    fi
  fi
fi

# 60s dedup: hash the DM body, compare with last hash + timestamp.
HASH="$(printf '%s' "$DM_BODY" | sha1sum | awk '{print $1}')"
NOW_TS="$(date +%s)"
LAST_HASH=""
LAST_TS=0
if [ -f "$DEDUP_FILE" ]; then
  read -r LAST_HASH LAST_TS < "$DEDUP_FILE" || true
fi
if [ "$HASH" = "$LAST_HASH" ] && [ -n "$LAST_TS" ] && [ $((NOW_TS - LAST_TS)) -lt $DEDUP_WINDOW_SECONDS ]; then
  exit 0
fi
# Atomic dedup write — printf > then mv leaves a brief window where two
# concurrent hooks both pass the check; tmp + rename is single-step on
# POSIX. Burst-DM in-flight collisions are rare but possible.
DEDUP_TMP="${DEDUP_FILE}.$$"
printf '%s %s\n' "$HASH" "$NOW_TS" > "$DEDUP_TMP" && mv "$DEDUP_TMP" "$DEDUP_FILE"

# Run retrieval. Preserve stderr so freshness warnings reach the operator
# (the hook owns the budget for any noise; query.sh only emits warnings on
# genuine drift, so the signal-to-noise is fine).
BLOCK="$(bash "$QUERY_SH" "$OFFICER" "$DM_BODY")"
if [ -z "$BLOCK" ]; then
  exit 0
fi

# Emit Claude Code hook output: additionalContext gets injected pre-prompt.
# Wrap the block in <system-reminder> so it lands tier-1. When a voice
# transcript was captured (Spec 046), prepend it as a separate
# <system-reminder> block so retrieval reasoning sees both surfaces.
if [ -n "$VOICE_BLOCK" ]; then
  WRAPPED="$(printf '<system-reminder>\n%s\n</system-reminder>\n\n<system-reminder>\n%s\n</system-reminder>' "$VOICE_BLOCK" "$BLOCK")"
else
  WRAPPED="$(printf '<system-reminder>\n%s\n</system-reminder>' "$BLOCK")"
fi
printf '%s' "$WRAPPED" | jq -R -s '{hookSpecificOutput: {additionalContext: .}}'
