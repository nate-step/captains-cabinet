#!/bin/bash
# cabinet/scripts/captain-rules/refine-pass.sh — Spec 047 v2 AC #4
#
# Sonnet refine-pass for Captain-reply drafts that tripped H1/H2 hooks.
# Reads the draft + flag list from argv, calls Anthropic API directly with
# the pinned refine-prompt.md template, returns JSON: {suggested_rewrite,
# fix_summary, claim_verification[]}.
#
# Usage:
#   refine-pass.sh <draft> <flags-json>
# Returns:
#   stdout: JSON object per refine-prompt.md output contract
#   exit 0 always (anti-FW-042; never block reply)
#
# Failure modes graceful: missing API key, API error, JSON parse fail
# → empty stdout, caller falls through with original flag list only.

set -u

DRAFT="${1:-}"
FLAGS_JSON="${2:-}"

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
PROMPT_TEMPLATE="$REPO_ROOT/cabinet/scripts/captain-rules/refine-prompt.md"
RULES_INDEX="$REPO_ROOT/shared/interfaces/captain-rules-index.yaml"

if [ -z "$DRAFT" ] || [ -z "$FLAGS_JSON" ]; then
  exit 0
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "[refine-pass] ANTHROPIC_API_KEY not set — skip refine" >&2
  exit 0
fi

if [ ! -r "$PROMPT_TEMPLATE" ]; then
  echo "[refine-pass] prompt template missing at $PROMPT_TEMPLATE" >&2
  exit 0
fi

PROMPT_BODY="$(cat "$PROMPT_TEMPLATE")"
RULES_BODY="$([ -r "$RULES_INDEX" ] && cat "$RULES_INDEX" | head -200 || echo "")"

# Build the user message: prompt template + DRAFT + FLAGS + RULES_INDEX excerpt.
USER_CONTENT="$(python3 -c '
import json, sys, os
prompt = sys.argv[1]
draft = sys.argv[2]
flags = sys.argv[3]
rules = sys.argv[4]
content = (
    prompt + "\n\n"
    "---\nDRAFT:\n" + draft + "\n\n"
    "---\nFLAGS:\n" + flags + "\n\n"
    "---\nRULES_INDEX (excerpt):\n" + rules
)
sys.stdout.write(json.dumps(content))
' "$PROMPT_BODY" "$DRAFT" "$FLAGS_JSON" "$RULES_BODY")"

REQUEST="$(python3 -c '
import json, sys
content = json.loads(sys.argv[1])
body = {
    "model": "claude-sonnet-4-6",
    "max_tokens": 2048,
    "messages": [{"role": "user", "content": content}],
}
sys.stdout.write(json.dumps(body))
' "$USER_CONTENT")"

# Fast Sonnet call. 30s ceiling; refine pass should be sub-10s typical.
RESPONSE="$(curl -sS --max-time 30 -X POST "https://api.anthropic.com/v1/messages" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d "$REQUEST" 2>/dev/null)"

if [ -z "$RESPONSE" ]; then
  echo "[refine-pass] empty response from API" >&2
  exit 0
fi

# Extract content[0].text from the API response, then re-parse the JSON
# the model returned per refine-prompt.md output contract. Pass RESPONSE
# via stdin to avoid shell-substitution quoting hazards.
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
# Strip markdown fences if the model wrapped its JSON.
if text.startswith("```"):
    text = re.sub(r"^```(?:json)?\s*", "", text)
    text = re.sub(r"\s*```\s*$", "", text)
try:
    parsed = json.loads(text)
    sys.stdout.write(json.dumps(parsed))
except json.JSONDecodeError:
    sys.stdout.write(json.dumps({"suggested_rewrite": text, "fix_summary": "(unparsed model output)", "claim_verification": []}))
' 2>/dev/null
