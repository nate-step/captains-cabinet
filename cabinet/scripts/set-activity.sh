#!/bin/bash
# set-activity.sh — Officer-side activity writer for Spec 032 Card 1.
#
# Usage:
#   bash cabinet/scripts/set-activity.sh <verb> "<object>" [blocker_type]
#
# Examples:
#   bash cabinet/scripts/set-activity.sh drafting "Spec 032 revision"
#   bash cabinet/scripts/set-activity.sh waiting "Captain approval on SEN-509" captain_approval
#   bash cabinet/scripts/set-activity.sh reviewing "PR #548"
#
# Starter verbs (trust-users principle — whitelist enforced at READ time by
# the dashboard, not here):
#   drafting / reviewing / debugging / deploying / researching / waiting
#   auditing / testing / shipping / planning / investigating / triaging / working
#
# Object rules (CRO v3 amendment):
#   - 40-char max (we trim here; reader also trims defensively)
#   - Human-readable; no file paths, no raw issue IDs without human context
#     ✓ "Spec 032 revision"
#     ✗ "032-cabinet-dashboard-consumer-mode.md"
#     ✓ "SEN-511 echo chamber layer 2"
#     ✗ "SEN-511" (alone)
#
# blocker_type (optional third arg):
#   captain_approval — waiting on Captain decision
#   founder_action   — blocked on founder-action Linear issue
#   (omit if not blocked)
#
# Writes to cabinet:officer:activity:$OFFICER as JSON, 5min TTL. The hook
# re-writes this key with an inferred default on every tool call; explicit
# calls here override the default until the next hook fire.

VERB="${1:?Usage: set-activity.sh <verb> \"<object>\" [blocker_type]}"
OBJECT="${2:-}"
BLOCKER="${3:-}"

OFFICER="${OFFICER_NAME:-unknown}"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"

# Trim object to 40 chars (visual truncation matches dashboard reader).
if [ ${#OBJECT} -gt 40 ]; then
  OBJECT="${OBJECT:0:37}..."
fi

# Escape for JSON: backslash + double-quote + newline. jq would be cleaner
# but we keep the script dep-free for forkers.
ESCAPED_OBJECT=$(printf '%s' "$OBJECT" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r')
ESCAPED_VERB=$(printf '%s' "$VERB" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r')

SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ -n "$BLOCKER" ]; then
  JSON="{\"verb\":\"$ESCAPED_VERB\",\"object\":\"$ESCAPED_OBJECT\",\"since\":\"$SINCE\",\"blocker_type\":\"$BLOCKER\"}"
else
  JSON="{\"verb\":\"$ESCAPED_VERB\",\"object\":\"$ESCAPED_OBJECT\",\"since\":\"$SINCE\"}"
fi

redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:officer:activity:$OFFICER" "$JSON" EX 300 > /dev/null
echo "Activity set: $OFFICER is $VERB $OBJECT${BLOCKER:+ [$BLOCKER]}"
