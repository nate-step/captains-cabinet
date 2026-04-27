#!/bin/bash
# cabinet/scripts/captain-rules/classify-rule.sh — Spec 048 v2 Phase 1
#
# Sonnet classifier that takes a Captain-rule body and returns
# {class, trigger_signals, trigger_surface, confidence, reasoning} JSON
# per the pinned classifier-prompt.md output contract. Anti-over-hooking
# floor (≥3 distinctive trigger phrases) baked into the prompt; if the
# model returns fewer triggers, it should self-classify as values-only.
#
# Usage:
#   classify-rule.sh <rule-body>
# Returns:
#   stdout: JSON object per classifier-prompt.md
#   exit 0 always (anti-FW-042)
#
# Failure modes graceful: missing API key, API error, JSON parse fail
# → empty stdout, caller falls through with values-only default.

set -u

RULE_BODY="${1:-}"
[ -z "$RULE_BODY" ] && exit 0

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
PROMPT_TEMPLATE="$REPO_ROOT/cabinet/scripts/captain-rules/classifier-prompt.md"

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "[classify-rule] ANTHROPIC_API_KEY not set — skip" >&2
  exit 0
fi
if [ ! -r "$PROMPT_TEMPLATE" ]; then
  echo "[classify-rule] prompt template missing at $PROMPT_TEMPLATE" >&2
  exit 0
fi

PROMPT_BODY="$(cat "$PROMPT_TEMPLATE")"

USER_CONTENT="$(python3 -c '
import json, sys
prompt = sys.argv[1]
rule = sys.argv[2]
content = prompt + "\n\n---\nRULE BODY:\n" + rule
sys.stdout.write(json.dumps(content))
' "$PROMPT_BODY" "$RULE_BODY")"

REQUEST="$(python3 -c '
import json, sys
content = json.loads(sys.argv[1])
body = {
    "model": "claude-sonnet-4-6",
    "max_tokens": 1024,
    "messages": [{"role": "user", "content": content}],
}
sys.stdout.write(json.dumps(body))
' "$USER_CONTENT")"

RESPONSE="$(curl -sS --max-time 30 -X POST "https://api.anthropic.com/v1/messages" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d "$REQUEST" 2>/dev/null)"

[ -z "$RESPONSE" ] && exit 0

printf '%s' "$RESPONSE" | python3 -c '
import json, sys, re
raw = sys.stdin.read()
try:
    resp = json.loads(raw)
except json.JSONDecodeError:
    sys.exit(0)
content = resp.get("content", [])
if not content or not isinstance(content, list):
    sys.exit(0)
text = content[0].get("text", "").strip()
if not text:
    sys.exit(0)
if text.startswith("```"):
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```\s*$", "", text)
try:
    parsed = json.loads(text)
except json.JSONDecodeError:
    sys.exit(0)

# Anti-over-hooking floor: enforce values-only when triggers < 3.
triggers = parsed.get("trigger_signals", [])
if not isinstance(triggers, list) or len(triggers) < 3:
    parsed["class"] = "values-only"
    parsed["trigger_surface"] = None
    parsed.setdefault("reasoning", "")
    parsed["reasoning"] = (parsed["reasoning"] + " (auto-downgraded: <3 distinctive triggers)").strip()

sys.stdout.write(json.dumps(parsed))
' 2>/dev/null
