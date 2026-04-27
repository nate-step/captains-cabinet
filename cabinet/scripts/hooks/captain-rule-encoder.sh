#!/bin/bash
# cabinet/scripts/hooks/captain-rule-encoder.sh — Spec 048 v2 Phase 1
#
# Sibling UserPromptSubmit hook to pre-captain-dm.sh. When an inbound
# Captain DM contains an encode-signal phrase ("remember", "always",
# "never", "encode", "save as", etc.), this hook:
#   1. Appends an entry to captain-patterns.md (or captain-intents.md
#      based on signal class) using the existing append-only format.
#   2. Fires async classifier (Sonnet via classify-rule.sh) in the
#      background — does NOT block the Captain-acknowledge reply path.
#   3. Writes audit JSONL to cabinet/logs/rule-promotions.jsonl with
#      classifier verdict (when async result lands) for retrospection.
#
# Phase 2 (separate PR) consumes the classifier output to generate hook
# + skill drafts and surface them in the next outbound Captain reply
# for ratify.
#
# Per Spec 048 v2 anti-FW-042 + A6 minimal-change:
#   - Warn-only / side-effect-only. NEVER exits non-zero. NEVER blocks.
#   - Env-var disable: RULE_ENCODER_HOOK_ENABLED=0
#   - Captain-only by chat_id (default-deny on missing config).
#   - Anti-over-hooking floor enforced in classify-rule.sh (≥3 triggers).
#
# Reversibility: rm this file + drop UserPromptSubmit registration.

set -u

if [ "${RULE_ENCODER_HOOK_ENABLED:-1}" = "0" ]; then
  exit 0
fi

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
SIGNALS_YAML="$REPO_ROOT/cabinet/scripts/captain-rules/encode-signals.yaml"
CLASSIFIER="$REPO_ROOT/cabinet/scripts/captain-rules/classify-rule.sh"
PATTERNS_FILE="$REPO_ROOT/shared/interfaces/captain-patterns.md"
INTENTS_FILE="$REPO_ROOT/shared/interfaces/captain-intents.md"
LOG_DIR="$REPO_ROOT/cabinet/logs"
AUDIT_LOG="$LOG_DIR/rule-promotions.jsonl"
PRODUCT_YML="$REPO_ROOT/instance/config/product.yml"
PLATFORM_YML="$REPO_ROOT/instance/config/platform.yml"

OFFICER="${OFFICER_NAME:-${CABINET_OFFICER:-unknown}}"
NOW_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

INPUT="$(cat)"
[ -z "$INPUT" ] && exit 0

PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)"
[ -z "$PROMPT" ] && exit 0

# Captain-only filter: same default-deny pattern as pre-captain-dm.sh.
if ! printf '%s' "$PROMPT" | grep -q '<channel source="telegram"'; then
  exit 0
fi
CAPTAIN_CHAT_ID="$(grep -E '^[[:space:]]*captain_telegram_chat_id:' "$PRODUCT_YML" "$PLATFORM_YML" 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '"' | tr -d ' ')"
[ -z "$CAPTAIN_CHAT_ID" ] && exit 0
if ! printf '%s' "$PROMPT" | grep -qE "<channel source=\"telegram\"[^>]*chat_id=\"$CAPTAIN_CHAT_ID\""; then
  exit 0
fi

# Extract DM body (between channel open + close tags).
DM_BODY="$(printf '%s' "$PROMPT" | python3 -c '
import sys, re
text = sys.stdin.read()
m = re.search(r"<channel source=\"telegram\"[^>]*>(.*?)</channel>", text, re.DOTALL)
sys.stdout.write(m.group(1).strip() if m else "")
' 2>/dev/null)"
[ -z "$DM_BODY" ] && exit 0

# Detect encode signals via the YAML regex list. Pass DM_BODY via argv
# (heredoc consumes stdin, so piping echo doesn't reach the script).
MATCHED_SIGNAL="$(python3 - "$SIGNALS_YAML" "$DM_BODY" <<'PYEOF' 2>/dev/null
import sys, re
yaml_path = sys.argv[1]
text = sys.argv[2]
patterns = []
try:
    with open(yaml_path) as f:
        in_signals = False
        for line in f:
            stripped = line.rstrip("\n")
            if stripped.startswith("signals:"):
                in_signals = True
                continue
            if in_signals and stripped and not stripped.startswith(" ") and not stripped.startswith("-"):
                in_signals = False
            if in_signals and stripped.lstrip().startswith("- "):
                val = stripped.lstrip()[2:].strip()
                if (val.startswith("'") and val.endswith("'")) or (val.startswith('"') and val.endswith('"')):
                    val = val[1:-1]
                patterns.append(val)
except FileNotFoundError:
    sys.exit(0)
for pat in patterns:
    try:
        m = re.search(pat, text, re.IGNORECASE)
        if m:
            sys.stdout.write(m.group(0))
            sys.exit(0)
    except re.error:
        continue
PYEOF
)"

[ -z "$MATCHED_SIGNAL" ] && exit 0

# Generate a stable rule_id from the DM body hash for audit trail.
RULE_ID="C-$(printf '%s' "$DM_BODY" | sha1sum | awk '{print substr($1,1,8)}')"

# Append entry to captain-patterns.md using the existing format.
# Files are gitignored (shared/interfaces/**/*.md); writes are runtime-only.
mkdir -p "$LOG_DIR" 2>/dev/null

if [ -w "$PATTERNS_FILE" ] || [ ! -e "$PATTERNS_FILE" ]; then
  {
    printf '\n---\n\n'
    printf '### Auto-encoded rule %s (%s)\n\n' "$RULE_ID" "$NOW_ISO"
    printf -- '- **Trigger signal:** `%s`\n' "$MATCHED_SIGNAL"
    printf -- '- **Captain DM body (verbatim):**\n\n  > %s\n\n' "$(printf '%s' "$DM_BODY" | tr '\n' ' ' | head -c 500)"
    printf -- '- **Encoded by:** captain-rule-encoder.sh (Spec 048 v2 Phase 1)\n'
    printf -- '- **Source:** %s\n' "$OFFICER"
    printf -- '- **Classifier verdict:** PENDING (async; check audit log)\n'
  } >> "$PATTERNS_FILE" 2>/dev/null
fi

# Audit log: pre-classifier entry. Phase 2 will append a follow-up line
# with the classifier verdict + Captain ratify state.
PRE_LOG="$(jq -cn \
  --arg ts "$NOW_ISO" \
  --arg officer "$OFFICER" \
  --arg rule_id "$RULE_ID" \
  --arg matched "$MATCHED_SIGNAL" \
  --arg body "$DM_BODY" \
  --arg phase "encoded" \
  '{ts:$ts, officer:$officer, rule_id:$rule_id, matched_signal:$matched, dm_body:$body, phase:$phase}' 2>/dev/null)"
[ -n "$PRE_LOG" ] && echo "$PRE_LOG" >> "$AUDIT_LOG"

# Fire async classifier — fully detached from this hook's lifetime.
# stdout of classifier appended to audit log when it completes.
if [ -x "$CLASSIFIER" ]; then
  (
    CLASS_RESULT="$(bash "$CLASSIFIER" "$DM_BODY" 2>/dev/null)"
    if [ -n "$CLASS_RESULT" ]; then
      POST_LOG="$(jq -cn \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg rule_id "$RULE_ID" \
        --argjson classifier "$CLASS_RESULT" \
        --arg phase "classified" \
        '{ts:$ts, rule_id:$rule_id, classifier:$classifier, phase:$phase}' 2>/dev/null)"
      [ -n "$POST_LOG" ] && echo "$POST_LOG" >> "$AUDIT_LOG"
    fi
  ) >/dev/null 2>&1 &
  disown
fi

# Hook silent on stdout (no additionalContext); side-effect-only.
exit 0
