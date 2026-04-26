#!/bin/bash
# cabinet/scripts/hooks/captain-posture-compliance.sh — Spec 043 H2
#
# Soft-warn detector for Captain Posture violations (msg 1839 master
# directive): no IDs, paths, timezone-abbreviations, or tech-jargon in
# Captain replies. Captain shouldn't have to decode our internals to read
# our messages.
#
# Wired as PostToolUse(mcp__plugin_telegram_telegram__reply). Surfaces a
# system-reminder naming the violation class so the officer self-corrects
# next turn (per S1 captain-posture-compliance skill rewrite recipes).
#
# Spec 043 AC #2, #6, #9, #10. Anti-FW-042 discipline:
#   - Warn-only. NEVER exits non-zero. NEVER blocks the tool.
#   - Env-var disable: CAPTAIN_POSTURE_HOOK_ENABLED=0
#   - FP-rate logging to cabinet/logs/hook-fires/captain-posture-compliance.jsonl
#   - Configurable rules at cabinet/scripts/hooks/captain-posture-rules.yaml.
#
# Reversibility: rm this file + the rules YAML + drop settings.json registration.

set -u

if [ "${CAPTAIN_POSTURE_HOOK_ENABLED:-1}" = "0" ]; then
  exit 0
fi

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
LOG_DIR="$REPO_ROOT/cabinet/logs/hook-fires"
LOG_FILE="$LOG_DIR/captain-posture-compliance.jsonl"
PRODUCT_YML="$REPO_ROOT/instance/config/product.yml"
PLATFORM_YML="$REPO_ROOT/instance/config/platform.yml"
RULES_YML="$REPO_ROOT/cabinet/scripts/hooks/captain-posture-rules.yaml"

OFFICER="${OFFICER_NAME:-${CABINET_OFFICER:-unknown}}"
NOW_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

INPUT="$(cat)"
[ -z "$INPUT" ] && exit 0

CAPTAIN_CHAT_ID="$(grep -E '^[[:space:]]*captain_telegram_chat_id:' "$PRODUCT_YML" "$PLATFORM_YML" 2>/dev/null | head -1 | awk -F: '{print $NF}' | tr -d '"' | tr -d ' ')"
[ -z "$CAPTAIN_CHAT_ID" ] && exit 0

REPLY_TEXT="$(printf '%s' "$INPUT" | jq -r '.tool_input.text // .tool_input.content // .tool_input.message // .tool_input.body // empty' 2>/dev/null)"
REPLY_CHAT_ID="$(printf '%s' "$INPUT" | jq -r '.tool_input.chat_id // empty' 2>/dev/null)"

[ -z "$REPLY_TEXT" ] || [ "$REPLY_CHAT_ID" != "$CAPTAIN_CHAT_ID" ] && exit 0

# Detection runs in Python — bash can't do per-class match aggregation
# cleanly with multiple ad-hoc patterns from a YAML config. Pass the reply
# text via stdin (the heredoc reads from a different fd than the pipe).
VIOLATIONS_JSON="$(python3 - "$RULES_YML" "$REPLY_TEXT" <<'PYEOF'
import sys, re

rules_path = sys.argv[1]
text = sys.argv[2]

# Lightweight YAML reader for our rules format (top-level lists keyed by name).
rules = {'path_patterns': [], 'id_patterns': [], 'jargon_terms': [], 'tz_abbreviations': []}
try:
    with open(rules_path) as f:
        cur = None
        for line in f:
            stripped = line.rstrip('\n')
            if not stripped or stripped.lstrip().startswith('#'):
                continue
            if not stripped.startswith(' ') and stripped.endswith(':'):
                cur = stripped[:-1].strip()
                if cur not in rules:
                    cur = None
                continue
            if cur and stripped.lstrip().startswith('- '):
                val = stripped.lstrip()[2:].strip()
                if (val.startswith("'") and val.endswith("'")) or (val.startswith('"') and val.endswith('"')):
                    val = val[1:-1]
                if val:
                    rules[cur].append(val)
except FileNotFoundError:
    pass

violations = {'path': [], 'id': [], 'jargon': [], 'timezone': []}

# Paths — substring match (anchor on path-leading slash or known prefix).
for p in rules['path_patterns']:
    if p in text:
        violations['path'].append(p)

# IDs — regex match (case-sensitive — IDs are uppercase).
for pat in rules['id_patterns']:
    try:
        for m in re.findall(pat, text):
            violations['id'].append(m)
    except re.error:
        continue

# Jargon — case-insensitive whole-word match. Avoid firing on legitimate use
# (e.g. "MCP" inside a code-fenced block where Captain expects technical detail).
text_lower = text.lower()
for term in rules['jargon_terms']:
    pattern = r'\b' + re.escape(term.lower()) + r'\b'
    if re.search(pattern, text_lower):
        violations['jargon'].append(term)

# Timezone abbreviations — bare TZ tags adjacent to a numeric time.
for tz in rules['tz_abbreviations']:
    pattern = r'\b\d{1,2}:\d{2}(?::\d{2})?\s*' + re.escape(tz) + r'\b'
    if re.search(pattern, text):
        violations['timezone'].append(tz)

# Emit a JSON object only if anything matched.
import json
nonempty = {k: sorted(set(v)) for k, v in violations.items() if v}
sys.stdout.write(json.dumps(nonempty) if nonempty else '')
PYEOF
)"

if [ -z "$VIOLATIONS_JSON" ] || [ "$VIOLATIONS_JSON" = "{}" ]; then
  exit 0
fi

EXCERPT="$(printf '%s' "$REPLY_TEXT" | head -c 200 | tr '\n' ' ' | head -c 200)"

mkdir -p "$LOG_DIR" 2>/dev/null
LOG_LINE="$(jq -cn \
  --arg ts "$NOW_ISO" \
  --arg officer "$OFFICER" \
  --argjson violations "$VIOLATIONS_JSON" \
  --arg excerpt "$EXCERPT" \
  --arg chat_id "$REPLY_CHAT_ID" \
  '{ts:$ts, hook:"captain-posture-compliance", officer:$officer, violations:$violations, excerpt:$excerpt, chat_id:$chat_id}' 2>/dev/null)"
[ -n "$LOG_LINE" ] && echo "$LOG_LINE" >> "$LOG_FILE"

# Format violations for the warn message. Use plain concatenation — f-string
# with escaped quotes inside a single-quoted shell heredoc is a syntax trap.
SUMMARY="$(printf '%s' "$VIOLATIONS_JSON" | python3 -c '
import json, sys
v = json.load(sys.stdin)
labels = {"path": "PATHS", "id": "IDs", "jargon": "TECH-JARGON", "timezone": "TIMEZONE-ABBREVIATIONS"}
parts = []
for k, items in v.items():
    parts.append(labels.get(k, k.upper()) + ": " + ", ".join(items))
sys.stdout.write(" | ".join(parts))
')"

WARN="CAPTAIN POSTURE VIOLATIONS in last reply.

$SUMMARY

Excerpt: \"$EXCERPT\"

A2 (Captain Posture, msg 1839): casual conversational, no IDs/paths/timezone-abbreviations/tech-talk. Captain shouldn't decode internals to read messages.

Rewrite recipes (S1 captain-posture-compliance skill):
- file paths → attach via reply files instead of pointing
- IDs → \"the cron fix\" / \"the latest one\" instead of SEN-N / PR #N
- timezone abbreviations → drop them; \"18:00\" not \"18:00 CEST\"
- tech-jargon → describe what changed, not the mechanism

If the violation is intentional (Captain explicitly asked for the spec ID): override is fine. The warn is a self-check cue.

Hook: warn-only. Disable via CAPTAIN_POSTURE_HOOK_ENABLED=0."

jq -n --arg ctx "$WARN" '{additionalContext: $ctx}'
exit 0
