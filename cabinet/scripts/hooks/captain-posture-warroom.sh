#!/bin/bash
# cabinet/scripts/hooks/captain-posture-warroom.sh — Spec 047 Phase 1
#
# Extends Captain Posture compliance (Spec 043 H2) to warroom posts.
# Captain msg 2024 caught CoS leaking spec/FW refs in an evening warroom
# briefing — H2 was scoped to Telegram DM replies and missed the warroom
# surface entirely. This hook closes the gap.
#
# Wired as PostToolUse(Bash). Detects send-to-group.sh / send-to-warroom.sh
# invocations, extracts the message arg, runs the same captain-posture-rules.yaml
# detection used by the DM-reply hook, emits a system-reminder warn.
#
# Anti-FW-042 discipline (same as Spec 043 H1-H4):
#   - Warn-only. NEVER exits non-zero. NEVER blocks.
#   - Env-var disable: POSTURE_WARROOM_HOOK_ENABLED=0
#   - FP-rate logging to cabinet/logs/hook-fires/captain-posture-warroom.jsonl
#   - Reuses configurable rules at cabinet/scripts/hooks/captain-posture-rules.yaml.
#
# Reversibility: rm this file + drop the settings.json registration.

set -u

if [ "${POSTURE_WARROOM_HOOK_ENABLED:-1}" = "0" ]; then
  exit 0
fi

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
LOG_DIR="$REPO_ROOT/cabinet/logs/hook-fires"
LOG_FILE="$LOG_DIR/captain-posture-warroom.jsonl"
RULES_YML="$REPO_ROOT/cabinet/scripts/hooks/captain-posture-rules.yaml"

OFFICER="${OFFICER_NAME:-${CABINET_OFFICER:-unknown}}"
NOW_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

INPUT="$(cat)"
[ -z "$INPUT" ] && exit 0

# Extract command from PreToolUse / PostToolUse Bash JSON.
COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$COMMAND" ] && exit 0

# Match warroom-post invocations only.
# Forms covered:
#   bash /opt/.../send-to-group.sh "msg"
#   send-to-group.sh "msg"
#   bash /opt/.../send-to-warroom.sh sensed "msg"
#   send-to-warroom.sh sensed "msg"
# Ignore unrelated Bash calls.
if ! printf '%s' "$COMMAND" | grep -qE '(^|/| )(send-to-group|send-to-warroom)\.sh\b'; then
  exit 0
fi

# Extract the message arg. The wrappers take the message as the LAST quoted
# string on the command line. Use a Python pass for robustness against
# nested quotes / escapes.
WARROOM_MSG="$(printf '%s' "$COMMAND" | python3 -c '
import sys, shlex
cmd = sys.stdin.read()
try:
    parts = shlex.split(cmd)
except ValueError:
    sys.exit(0)
# The script positional arg layout:
#   send-to-group.sh   <msg>
#   send-to-warroom.sh <context> <msg>
# Both end with the message as the trailing arg.
if not parts:
    sys.exit(0)
script_idx = -1
for i, p in enumerate(parts):
    if p.endswith("send-to-group.sh") or p.endswith("send-to-warroom.sh"):
        script_idx = i
        break
if script_idx < 0 or script_idx + 1 >= len(parts):
    sys.exit(0)
# Last positional after the script path is the message.
sys.stdout.write(parts[-1])
' 2>/dev/null)"

[ -z "$WARROOM_MSG" ] && exit 0

# Run the same posture-rules.yaml detection as the DM-reply hook. Pass the
# message text via argv[2] (heredoc + argv pattern from Spec 043 H2).
VIOLATIONS_JSON="$(python3 - "$RULES_YML" "$WARROOM_MSG" <<'PYEOF'
import sys, re

rules_path = sys.argv[1]
text = sys.argv[2]

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

for p in rules['path_patterns']:
    if p in text:
        violations['path'].append(p)

for pat in rules['id_patterns']:
    try:
        for m in re.findall(pat, text):
            violations['id'].append(m)
    except re.error:
        continue

text_lower = text.lower()
for term in rules['jargon_terms']:
    pattern = r'\b' + re.escape(term.lower()) + r'\b'
    if re.search(pattern, text_lower):
        violations['jargon'].append(term)

for tz in rules['tz_abbreviations']:
    pattern = r'\b\d{1,2}:\d{2}(?::\d{2})?\s*' + re.escape(tz) + r'\b'
    if re.search(pattern, text):
        violations['timezone'].append(tz)

import json
nonempty = {k: sorted(set(v)) for k, v in violations.items() if v}
sys.stdout.write(json.dumps(nonempty) if nonempty else '')
PYEOF
)"

if [ -z "$VIOLATIONS_JSON" ] || [ "$VIOLATIONS_JSON" = "{}" ]; then
  exit 0
fi

EXCERPT="$(printf '%s' "$WARROOM_MSG" | head -c 200 | tr '\n' ' ' | head -c 200)"

mkdir -p "$LOG_DIR" 2>/dev/null
LOG_LINE="$(jq -cn \
  --arg ts "$NOW_ISO" \
  --arg officer "$OFFICER" \
  --argjson violations "$VIOLATIONS_JSON" \
  --arg excerpt "$EXCERPT" \
  '{ts:$ts, hook:"captain-posture-warroom", officer:$officer, violations:$violations, excerpt:$excerpt}' 2>/dev/null)"
[ -n "$LOG_LINE" ] && echo "$LOG_LINE" >> "$LOG_FILE"

SUMMARY="$(printf '%s' "$VIOLATIONS_JSON" | python3 -c '
import json, sys
v = json.load(sys.stdin)
labels = {"path": "PATHS", "id": "IDs", "jargon": "TECH-JARGON", "timezone": "TIMEZONE-ABBREVIATIONS"}
parts = []
for k, items in v.items():
    parts.append(labels.get(k, k.upper()) + ": " + ", ".join(items))
sys.stdout.write(" | ".join(parts))
')"

WARN="CAPTAIN POSTURE VIOLATIONS in warroom post.

$SUMMARY

Excerpt: \"$EXCERPT\"

A2 (Captain Posture, msg 1839): casual conversational, no IDs/paths/timezone-abbreviations/tech-talk. Captain reads the warroom — same register as DMs.

Rewrite recipes (S1 captain-posture-compliance skill):
- file paths → describe what changed instead of pointing
- IDs → \"the cron fix\" / \"the latest one\" instead of SEN-N / PR #N / Spec N / FW-N
- timezone abbreviations → drop them; \"18:00\" not \"18:00 CEST\"
- tech-jargon → describe what changed, not the mechanism

If the violation is intentional (Captain explicitly asked for the spec ID): override is fine.

Hook: warn-only. Disable via POSTURE_WARROOM_HOOK_ENABLED=0."

jq -n --arg ctx "$WARN" '{additionalContext: $ctx}'
exit 0
