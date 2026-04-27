#!/bin/bash
# cabinet/scripts/captain-rules/draft-generator.sh — Spec 048 v2 Phase 2
#
# Consumes classifier verdict + rule body, emits paired hook + skill
# drafts for Captain ratify. Drafts stay at .draft until ratify-rule.sh
# promotes them. Anti-FW-042: generated hook defaults to warn-mode +
# env-var disable + FP-rate JSONL logging.
#
# Usage:
#   draft-generator.sh <rule_id> <rule_body_file> <classifier_json>
#
# Outputs (paths echoed to stdout, one per line):
#   cabinet/scripts/hooks/draft/<rule_id>.sh.draft
#   memory/skills/evolved/draft/<rule_id>.md.draft

set -u

RULE_ID="${1:?Usage: draft-generator.sh <rule_id> <rule_body_file> <classifier_json>}"
RULE_BODY_FILE="${2:?missing rule body file}"
CLASSIFIER_JSON="${3:?missing classifier JSON}"

[ -r "$RULE_BODY_FILE" ] || { echo "[draft-gen] rule body file unreadable" >&2; exit 0; }

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
DRAFT_HOOK_DIR="$REPO_ROOT/cabinet/scripts/hooks/draft"
DRAFT_SKILL_DIR="$REPO_ROOT/memory/skills/evolved/draft"
OFFICER="${OFFICER_NAME:-${CABINET_OFFICER:-unknown}}"
PENDING_FILE="/tmp/.captain-pending-drafts-$OFFICER"

mkdir -p "$DRAFT_HOOK_DIR" "$DRAFT_SKILL_DIR" 2>/dev/null

# Delegate file generation to Python — bash heredoc nesting is a known
# trap when emitting shell code that itself contains heredocs.
python3 - "$RULE_ID" "$RULE_BODY_FILE" "$CLASSIFIER_JSON" "$DRAFT_HOOK_DIR" "$DRAFT_SKILL_DIR" "$PENDING_FILE" <<'PYEOF'
import json, sys, os, datetime

rule_id, body_path, classifier_json, hook_dir, skill_dir, pending_file = sys.argv[1:7]

with open(body_path) as f:
    rule_body = f.read().strip()

try:
    cls_data = json.loads(classifier_json)
except json.JSONDecodeError:
    sys.exit(0)

if cls_data.get("class") != "operationalizable":
    sys.exit(0)

triggers = cls_data.get("trigger_signals", []) or []
if not isinstance(triggers, list) or not triggers:
    sys.exit(0)

trigger_surface = cls_data.get("trigger_surface") or "Reply"
reasoning = (cls_data.get("reasoning") or "").strip()
confidence = cls_data.get("confidence")

env_slug = "".join(c if c.isalnum() else "_" for c in rule_id.upper())
env_var = f"RULE_{env_slug}_HOOK_ENABLED"
now_iso = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

hook_path = os.path.join(hook_dir, f"{rule_id}.sh.draft")
skill_path = os.path.join(skill_dir, f"{rule_id}.md.draft")

# --- Hook draft ---
trigger_array = "\n".join(f"  {json.dumps(t)}" for t in triggers)
hook_body = f"""#!/bin/bash
# cabinet/scripts/hooks/draft/{rule_id}.sh.draft — auto-drafted by Spec 048 v2
#
# Generated {now_iso} from a Captain encode-signal.
# Classifier: class=operationalizable, surface={trigger_surface}, confidence={confidence}
# Reasoning: {reasoning}
#
# Status: DRAFT. Stays at .draft until Captain ratifies via:
#   bash cabinet/scripts/captain-rules/ratify-rule.sh {rule_id} yes
#
# Anti-FW-042 discipline: warn-mode only, env-var disable, FP-rate JSONL.
# Author should review the trigger list below before ratify — generator
# picks classifier-output literally; tighten to word boundaries if too broad.

set -u

if [ "${{{env_var}:-1}}" = "0" ]; then
  exit 0
fi

REPO_ROOT="${{REPO_ROOT:-/opt/founders-cabinet}}"
LOG_DIR="$REPO_ROOT/cabinet/logs/hook-fires"
LOG_FILE="$LOG_DIR/{rule_id}.jsonl"
OFFICER="${{OFFICER_NAME:-${{CABINET_OFFICER:-unknown}}}}"
NOW_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

INPUT="$(cat)"
[ -z "$INPUT" ] && exit 0

# Trigger phrases per classifier ({trigger_surface} surface).
TRIGGERS=(
{trigger_array}
)

# Detect: scan tool_input.text / .command for any trigger phrase.
TEXT="$(printf '%s' "$INPUT" | jq -r '.tool_input.text // .tool_input.content // .tool_input.command // empty' 2>/dev/null)"
[ -z "$TEXT" ] && exit 0

TEXT_LOWER="$(printf '%s' "$TEXT" | tr '[:upper:]' '[:lower:]')"
MATCHED=""
for trigger in "${{TRIGGERS[@]}}"; do
  trigger_lower="$(printf '%s' "$trigger" | tr '[:upper:]' '[:lower:]')"
  if printf '%s' "$TEXT_LOWER" | grep -qF "$trigger_lower"; then
    MATCHED="$trigger"
    break
  fi
done
[ -z "$MATCHED" ] && exit 0

# FP-rate logging.
mkdir -p "$LOG_DIR" 2>/dev/null
LOG_LINE="$(jq -cn \\
  --arg ts "$NOW_ISO" \\
  --arg officer "$OFFICER" \\
  --arg matched "$MATCHED" \\
  --arg rule_id "{rule_id}" \\
  '{{ts:$ts, hook:$rule_id, officer:$officer, matched_phrase:$matched}}' 2>/dev/null)"
[ -n "$LOG_LINE" ] && echo "$LOG_LINE" >> "$LOG_FILE"

# Emit warn — Captain rule body inline so officer reads it on next turn.
RULE_BODY={json.dumps(rule_body)}
WARN="🛑 CAPTAIN RULE TRIGGERED — {rule_id}

Matched phrase: \\"$MATCHED\\"

--- RULE ---

$RULE_BODY

Disable: {env_var}=0"

jq -n --arg ctx "$WARN" '{{additionalContext: $ctx}}'
exit 0
"""

with open(hook_path, "w") as f:
    f.write(hook_body)

# --- Skill draft ---
trigger_lines = "\n".join(f"- `{t}`" for t in triggers)
skill_body = f"""# Skill — Auto-drafted from Captain rule {rule_id}

**Generated {now_iso} by Spec 048 v2 draft-generator.sh.**
**Status: DRAFT.** Stays at `.md.draft` until Captain ratifies.

## Rule body (verbatim)

{rule_body}

## When to apply

Whenever your draft tool input matches one of the trigger phrases below. The
paired hook at `cabinet/scripts/hooks/{rule_id}.sh` (post-ratify) detects + warns.

## Trigger phrases ({trigger_surface} surface)

{trigger_lines}

## Rewrite recipe

_Author: replace this with the rewrite recipe for this rule. Generator
ships the rule body + triggers; the recipe shape is yours to refine._

Reference patterns (Spec 043 S1–S3):
- `memory/skills/evolved/captain-posture-compliance.md`
- `memory/skills/evolved/personal-work-parity-checklist.md`
- `memory/skills/evolved/build-vs-buy-quickdraw.md`

## Why

Captain encoded this rule via the 4th-loop encode-signal flow. Auto-drafted
alongside the memory-file write because the classifier judged it
operationalizable (confidence ≥ 0.7, ≥3 distinctive triggers).

Reasoning from classifier: {reasoning}

## Hook integration

- Hook draft: `cabinet/scripts/hooks/draft/{rule_id}.sh.draft` (warn-mode)
- FP-rate log: `cabinet/logs/hook-fires/{rule_id}.jsonl`
- Disable: `{env_var}=0`
"""

with open(skill_path, "w") as f:
    f.write(skill_body)

# Pending-drafts marker — officer's next turn surfaces drafts to Captain.
with open(pending_file, "a") as f:
    f.write(rule_id + "\n")

# Echo paths for the audit log.
print(hook_path)
print(skill_path)
PYEOF
