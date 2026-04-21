#!/bin/bash
# post-tool-use.sh — Runs after every tool invocation
# Logs the action and increments cost counters.
# Claude Code passes JSON on stdin: { tool_name, tool_input, tool_response }

# Read JSON from stdin
HOOK_INPUT=$(cat)
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$HOOK_INPUT" | jq -c '.tool_input // {}' 2>/dev/null)
TOOL_OUTPUT=$(echo "$HOOK_INPUT" | jq -c '.tool_response // {}' 2>/dev/null)

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

LOG_DIR="/opt/founders-cabinet/memory/logs"
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY=$(date -u +%Y-%m-%d)
OFFICER="${OFFICER_NAME:-unknown}"

# ============================================================
# CAPABILITY HELPERS — officer-agnostic hook routing
# ============================================================
# Reads from cabinet/officer-capabilities.conf instead of hardcoding
# officer names. Founders customize that file for their officer set.
CAPABILITIES_FILE="/opt/founders-cabinet/cabinet/officer-capabilities.conf"

has_capability() {
  grep -q "^${OFFICER}:${1}$" "$CAPABILITIES_FILE" 2>/dev/null
}

officers_with() {
  grep ":${1}$" "$CAPABILITIES_FILE" 2>/dev/null | cut -d: -f1
}

# ============================================================
# 0. HEARTBEAT — proves this Officer is alive
# ============================================================
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:heartbeat:$OFFICER" "$TIMESTAMP" EX 900 > /dev/null 2>&1

# ============================================================
# 1. STRUCTURED LOG ENTRY
# ============================================================
LOG_FILE="$LOG_DIR/${TODAY}.jsonl"

# Truncate output for logging (max 500 chars)
TRUNCATED_OUTPUT=$(echo "$TOOL_OUTPUT" | head -c 500)

# Phase 1 CP9: cabinet_id for multi-Cabinet forward compat. Default 'main'
# in Phase 1 (single Cabinet); Phase 2 sets CABINET_ID per instance so logs
# remain queryable across Cabinet boundaries. Validated against a strict
# safelist to prevent JSONL-injection (breaks log parsers, not security):
# silently falls back to 'main' if CABINET_ID contains chars outside
# [a-z0-9_-].
CABINET_ID="${CABINET_ID:-main}"
if ! [[ "$CABINET_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  CABINET_ID="main"
fi

# Write JSON log line
echo "{\"ts\":\"$TIMESTAMP\",\"cabinet_id\":\"$CABINET_ID\",\"officer\":\"$OFFICER\",\"tool\":\"$TOOL_NAME\",\"input\":$(echo "$TOOL_INPUT" | jq -c '.' 2>/dev/null || echo '{}'),\"output_preview\":$(echo "$TRUNCATED_OUTPUT" | jq -Rs '.' 2>/dev/null || echo '\"\"')}" >> "$LOG_FILE"

# NOTE: Accurate per-tool cost tracking is handled by the cost-aware
# Anthropic wrapper which writes microdollar-accurate values to the
# cabinet:cost:tokens:daily:<date> HSET (fields <role>_cost_micro,
# <role>_input, <role>_output, <role>_cache_write, <role>_cache_read).
# The legacy byte-count COST TRACKING block here (cabinet:cost:daily,
# cabinet:cost:officer:*, cabinet:cost:monthly) was removed in FW-016:
# it double-counted alongside the wrapper and under-reported by ~100×
# because byte length ≠ token count for jq-stringified tool I/O.
# Consumers (cost-dashboard.sh, dashboard/redis.ts, test-escalation.sh,
# run-golden-evals.sh EVAL-003) read from the tokens:daily HSET.

# ============================================================
# 3. ACTIVITY STRING — Card 1 YOUR CABINET (Spec 032 PR 3)
# ============================================================
# Write a default {verb, object} inferred from the last tool + file path.
# Officers override with set-activity.sh when they want cleaner copy. TTL is
# 5 min so the key goes stale naturally — Card 1 falls back to "between
# tasks" / "offline" per heartbeat when stale/absent.
#
# We write ONLY if the key is currently absent or stale enough that this
# write is the most recent signal. Explicit officer overrides via
# set-activity.sh always win within their 5-min TTL; the hook's default
# string re-asserts once the officer-set string expires.
#
# Infer rule:
#   Edit/Write/Update on *.ts|*.tsx|*.sh|*.sql|*.py → "editing <basename>"
#   Edit/Write on product-specs/*.md              → "reviewing <spec title>"
#   Bash git push                                 → "deploying <branch>"
#   Bash curl pulls/N/merge                        → "merging PR #N"
#   Bash gh pr create|create pr                    → "opening PR"
#   Task/Agent                                     → "coordinating agents"
#   mcp__plugin_telegram_telegram__reply           → "replying to Captain"
#   WebSearch/WebFetch                             → "researching"
#   Grep/Glob/Read                                 → "investigating <file>"
#   default                                        → "working"
ACTIVITY_VERB="working"
ACTIVITY_OBJECT=""
case "$TOOL_NAME" in
  Edit|Write|NotebookEdit)
    FP=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // empty' 2>/dev/null)
    if [ -n "$FP" ]; then
      BN=$(basename "$FP")
      if echo "$FP" | grep -q 'product-specs/'; then
        ACTIVITY_VERB="reviewing"
        ACTIVITY_OBJECT="spec ${BN%.md}"
      else
        ACTIVITY_VERB="editing"
        ACTIVITY_OBJECT="$BN"
      fi
    fi
    ;;
  Bash)
    CMD_SNIP=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
    if echo "$CMD_SNIP" | grep -qE '(^|[^a-z0-9_-])git push[[:space:]]+(origin[[:space:]]+)?(main|master)([[:space:]]|$)'; then
      ACTIVITY_VERB="deploying"
      ACTIVITY_OBJECT="to main"
    elif echo "$CMD_SNIP" | grep -qE 'pulls/[0-9]+/merge'; then
      PRNUM=$(echo "$CMD_SNIP" | grep -oE 'pulls/[0-9]+' | grep -oE '[0-9]+' | head -1)
      ACTIVITY_VERB="shipping"
      ACTIVITY_OBJECT="PR #${PRNUM:-a change}"
    elif echo "$CMD_SNIP" | grep -qE 'gh pr create|/pulls\"|/pulls '; then
      ACTIVITY_VERB="shipping"
      ACTIVITY_OBJECT="a PR"
    elif echo "$CMD_SNIP" | grep -qE '\bpnpm (install|run|test|build)|\bnpm (install|run|test|build)|\bvitest\b|\btsc\b|\beslint\b'; then
      ACTIVITY_VERB="testing"
      ACTIVITY_OBJECT="the build"
    elif echo "$CMD_SNIP" | grep -qE 'verify-deploy\.sh'; then
      ACTIVITY_VERB="deploying"
      ACTIVITY_OBJECT="a release"
    else
      ACTIVITY_VERB="working"
    fi
    ;;
  Grep|Glob|Read)
    FP=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // .pattern // empty' 2>/dev/null)
    ACTIVITY_VERB="investigating"
    [ -n "$FP" ] && ACTIVITY_OBJECT="$(basename "$FP" 2>/dev/null || echo 'the codebase')"
    ;;
  Task|Agent)
    ACTIVITY_VERB="coordinating"
    ACTIVITY_OBJECT="Crew"
    ;;
  WebSearch|WebFetch|mcp__claude_ai_*)
    ACTIVITY_VERB="researching"
    ACTIVITY_OBJECT=""
    ;;
  mcp__plugin_telegram_telegram__*)
    ACTIVITY_VERB="replying"
    ACTIVITY_OBJECT="Captain"
    ;;
esac

# Trim object to 40 chars (matches dashboard reader + set-activity.sh)
if [ ${#ACTIVITY_OBJECT} -gt 40 ]; then
  ACTIVITY_OBJECT="${ACTIVITY_OBJECT:0:37}..."
fi

# Escape for JSON
ACT_VERB_ESC=$(printf '%s' "$ACTIVITY_VERB" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r')
ACT_OBJ_ESC=$(printf '%s' "$ACTIVITY_OBJECT" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\r')

# Write the default activity. Officer-driven set-activity.sh calls write the
# same key; whichever fires last within the 5-min TTL wins. Net effect:
# officer overrides during their burst, then the hook's default takes over
# 5 min later when they've moved on.
ACT_JSON="{\"verb\":\"$ACT_VERB_ESC\",\"object\":\"$ACT_OBJ_ESC\",\"since\":\"$TIMESTAMP\"}"
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:officer:activity:$OFFICER" "$ACT_JSON" EX 300 > /dev/null 2>&1

# ============================================================
# 4. EXPERIENCE RECORD NUDGE
# ============================================================
# After significant actions, set a Redis flag for the officer's /loop to pick up.

SIGNIFICANT_ACTION=false

case "$TOOL_NAME" in
  Bash)
    if echo "$TOOL_INPUT" | grep -qiE '(git push|gh pr create|gh pr merge)'; then
      SIGNIFICANT_ACTION=true
    fi
    ;;
  Write)
    if echo "$TOOL_INPUT" | grep -qiE '(product-specs/|research-briefs/|deployment-status)'; then
      SIGNIFICANT_ACTION=true
    fi
    ;;
esac

if [ "$SIGNIFICANT_ACTION" = true ]; then
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:nudge:experience-record:$OFFICER" "$TIMESTAMP" EX 3600 > /dev/null 2>&1
fi

# ============================================================
# 4. TRIGGER DELIVERY — deliver pending triggers via Redis Streams
# ============================================================
# Reads NEW messages from the officer's stream. Messages stay "pending"
# until the officer ACKs them — crash recovery built in.
. /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh 2>/dev/null
TRIG_MESSAGES=$(trigger_read "$OFFICER")
TRIG_IDS=$(cat /tmp/.trigger_ids_${OFFICER} 2>/dev/null)
if [ -n "$TRIG_MESSAGES" ]; then
  TRIG_COUNT=$(echo "$TRIG_MESSAGES" | wc -l)
  echo ""
  echo "PENDING TRIGGERS ($TRIG_COUNT):"
  echo "$TRIG_MESSAGES"
  echo ""
  echo "Process these triggers now. Then ACK:"
  echo "  . /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh && trigger_ack $OFFICER \"$TRIG_IDS\""
fi
# ============================================================


# ============================================================
# 5. AUTO-NOTIFY DEPLOYMENT VALIDATORS ON DEPLOY
# ============================================================
if has_capability "deploys_code" && [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
  # Matches: git push where the target refspec is literally "main"/"master"
  # (word-boundary so release-please-like branches — e.g.
  # release-please--branches--main — do NOT match), gh pr merge, and
  # curl-based GitHub API merges (pulls/N/merge). Non-main/master branches
  # never trigger the auto-notify: staged/preview deploys are noise.
  # Skip: if the command is clearly targeting the Cabinet framework repo
  # (cd /opt/founders-cabinet, git -C /opt/founders-cabinet, captains-cabinet
  # URL), this isn't a product deploy — it's a framework push that produces
  # no Vercel deployment. Without this guard, every framework master push
  # triggered a false-positive AUTO-DEPLOY cascade at the validators (COO
  # flagged 2026-04-17 after the initial release-please filter landed).
  if echo "$CMD" | grep -qE '/opt/founders-cabinet|/opt/captains-cabinet|nate-step/captains-cabinet|nate-step/founders-cabinet'; then
    :  # noop — cabinet-framework push, not a product deploy
  elif echo "$CMD" | grep -qE '(^|[^a-z0-9_-])git push[[:space:]]+(origin[[:space:]]+)?(main|master)([[:space:]]|$)|gh pr merge|pulls/[0-9]+/merge|curl.*STEP-Network/Sensed.*pulls/[0-9]+/merge'; then
    for target in $(officers_with "validates_deployments"); do
      trigger_send "$target" "AUTO-DEPLOY DETECTED — push to main. Validate deployment NOW: check all critical flows, take screenshots, update operational-health.md. Respond with validation status."
    done
    for target in $(officers_with "reviews_implementations"); do
      trigger_send "$target" "AUTO-DEPLOY DETECTED — push to main. Review the implementation against spec: screenshot the live result via Chromium, compare against spec design intent, confirm acceptance criteria met or file issues."
    done
  fi
fi

# ============================================================
# 6. DEPLOY VERIFICATION + CREW REVIEW REMINDER
# ============================================================
if has_capability "deploys_code" && [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
  # Skip: if the command is clearly targeting the Cabinet framework repo
  # (cd /opt/founders-cabinet, git -C /opt/founders-cabinet, captains-cabinet
  # URL), this isn't a product deploy — it's a framework push that produces
  # no Vercel deployment. Without this guard, every framework master push
  # triggered a false-positive AUTO-DEPLOY cascade at the validators (COO
  # flagged 2026-04-17 after the initial release-please filter landed).
  if echo "$CMD" | grep -qE '/opt/founders-cabinet|/opt/captains-cabinet|nate-step/captains-cabinet|nate-step/founders-cabinet'; then
    :  # noop — cabinet-framework push, not a product deploy
  elif echo "$CMD" | grep -qE '(^|[^a-z0-9_-])git push[[:space:]]+(origin[[:space:]]+)?(main|master)([[:space:]]|$)|gh pr merge|pulls/[0-9]+/merge|curl.*STEP-Network/Sensed.*pulls/[0-9]+/merge'; then
    echo "REMINDER: Poll Vercel deployment status before announcing. Run deploy-and-verify skill."
    echo "REMINDER: Update shared/interfaces/deployment-status.md with current deploy state."
  fi
fi

# ============================================================
# 6b. CROSS-VALIDATION — notify reviewers when artifacts are created
# ============================================================
if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; then
  FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // empty' 2>/dev/null)
  case "$FILE_PATH" in
    *"product-specs/"*)
      # Spec created/edited — notify reviewers (with dedup to prevent notification loops)
      SPEC_BASE=$(basename "$FILE_PATH")
      for target in $(officers_with "reviews_specs"); do
        [ "$target" = "$OFFICER" ] && continue
        DEDUP_KEY="cabinet:notified:spec:${SPEC_BASE}:${target}"
        ALREADY=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$DEDUP_KEY" 2>/dev/null)
        if [ -z "$ALREADY" ] || [ "$ALREADY" = "(nil)" ]; then
          redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "$DEDUP_KEY" 1 EX 600 > /dev/null 2>&1
          trigger_send "$target" "SPEC UPDATE by $OFFICER: $SPEC_BASE was created/modified. Review against research and product strategy."
        fi
      done
      ;;
    *"research-briefs/"*)
      # Research brief created — notify reviewers (with dedup)
      BRIEF_BASE=$(basename "$FILE_PATH")
      for target in $(officers_with "reviews_research"); do
        [ "$target" = "$OFFICER" ] && continue
        DEDUP_KEY="cabinet:notified:brief:${BRIEF_BASE}:${target}"
        ALREADY=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$DEDUP_KEY" 2>/dev/null)
        if [ -z "$ALREADY" ] || [ "$ALREADY" = "(nil)" ]; then
          redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "$DEDUP_KEY" 1 EX 600 > /dev/null 2>&1
          trigger_send "$target" "RESEARCH BRIEF by $OFFICER: $BRIEF_BASE published. Review for actionable items and spec implications."
        fi
      done
      ;;
  esac
fi

# ============================================================
# 7. EXPERIENCE RECORD NUDGE (count-based)
# ============================================================
CALL_COUNT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INCR "cabinet:toolcalls:$OFFICER" 2>/dev/null)
[[ "$CALL_COUNT" =~ ^[0-9]+$ ]] || CALL_COUNT=1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:toolcalls:$OFFICER" 86400 > /dev/null 2>&1

if [ "$((CALL_COUNT % 50))" -eq "0" ] 2>/dev/null; then
  LAST_RECORD=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:last-experience:$OFFICER" 2>/dev/null)
  if [ -z "$LAST_RECORD" ] || [ "$LAST_RECORD" = "(nil)" ]; then
    echo "You have made 50 tool calls without an experience record. Write a catch-up record if you have completed meaningful work."
  fi
fi

# ============================================================
# 8. CAPTAIN DECISION LOGGING ENFORCEMENT
# ============================================================
# After an officer with logs_captain_decisions capability replies to
# the Captain's Telegram chat, remind to log decisions.
CAPTAIN_CHAT_ID="${CAPTAIN_TELEGRAM_CHAT_ID:-$(grep '^captain_telegram_chat_id:' /opt/founders-cabinet/instance/config/platform.yml 2>/dev/null | awk '{print $2}' | tr -d '\"')}"
CAPTAIN_NAME=$(grep '^captain_name:' /opt/founders-cabinet/instance/config/platform.yml 2>/dev/null | awk '{print $2}' || echo "Captain")

if has_capability "logs_captain_decisions" && [ "$TOOL_NAME" = "mcp__plugin_telegram_telegram__reply" ]; then
  REPLY_CHAT=$(echo "$TOOL_INPUT" | jq -r '.chat_id // empty' 2>/dev/null)
  if [ -n "$CAPTAIN_CHAT_ID" ] && [ "$REPLY_CHAT" = "$CAPTAIN_CHAT_ID" ]; then
    echo "⚠️ CAPTAIN DECISION CHECK: Did $CAPTAIN_NAME make a decision in this exchange (kill a feature, change direction, approve/reject)? If YES: (1) Add 'captain-decision' label to the Linear issue, (2) Comment with decision + WHY, (3) Update shared/interfaces/captain-decisions.md. If no decision was made, carry on."
  fi
fi

# ============================================================
# 9. IDLE DETECTION — warn officers who have work waiting
# ============================================================
# Check if this officer has been idle (>30min since last tool call)
# and has pending work. If so, inject a strong warning.
LAST_CALL=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:last-toolcall:$OFFICER" 2>/dev/null)
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:last-toolcall:$OFFICER" "$TIMESTAMP" EX 86400 > /dev/null 2>&1

if [ -n "$LAST_CALL" ] && [ "$LAST_CALL" != "(nil)" ]; then
  LAST_EPOCH=$(date -d "$LAST_CALL" +%s 2>/dev/null || echo "0")
  NOW_EPOCH=$(date -u +%s)
  IDLE_SECONDS=$((NOW_EPOCH - LAST_EPOCH))

  if [ "$IDLE_SECONDS" -gt 1800 ] 2>/dev/null; then
    echo ""
    echo "⚠️ You were idle for $((IDLE_SECONDS / 60)) minutes. Check for pending work NOW:"
    echo "  - Check shared/interfaces/product-specs/ for ready specs"
    echo "  - Check Linear backlog for bugs and issues"
    echo "  - Check shared/backlog.md for priorities"
    echo "  - If truly nothing to do, run proactive work from your role definition"
    echo "  - Officers must NEVER idle when work is available"
    echo ""
  fi
fi

# ============================================================
# 10. PROACTIVE WORK INJECTION — prevent polling-only idling
# ============================================================
# If officer is only doing heartbeat polling (low tool count relative to time),
# inject proactive work instructions. Checks every 50 tool calls.
if [ "$((CALL_COUNT % 50))" -eq "0" ] 2>/dev/null; then
  LAST_EXPERIENCE=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:last-experience:$OFFICER" 2>/dev/null)
  if [ -n "$LAST_EXPERIENCE" ] && [ "$LAST_EXPERIENCE" != "(nil)" ]; then
    EXP_EPOCH=$(date -d "$LAST_EXPERIENCE" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date -u +%s)
    SINCE_LAST_RECORD=$((NOW_EPOCH - EXP_EPOCH))
    # If no experience record in 2+ hours, officer is likely just polling
    if [ "$SINCE_LAST_RECORD" -gt 7200 ] 2>/dev/null; then
      echo ""
      echo "⚠️ PROACTIVE WORK CHECK: Your last experience record was $((SINCE_LAST_RECORD / 3600))h ago. You may be polling without doing real work."
      echo "  Re-read your role definition (.claude/agents/${OFFICER}.md) and execute your proactive responsibilities NOW."
      echo "  If you have completed work, write an experience record immediately."
      echo ""
    fi
  fi
fi

# ============================================================
# 11. INFRASTRUCTURE REVIEW GATE — remind to review before committing critical files
# ============================================================
if [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
  if echo "$CMD" | grep -qE 'git add'; then
    # Check if critical infrastructure files are being staged
    STAGED=$(cd /opt/founders-cabinet && git diff --cached --name-only 2>/dev/null)
    if echo "$STAGED" | grep -qE '(hooks/|CLAUDE\.md|\.claude/agents/|scripts/lib/|officer-capabilities|officer-skills/|constitution/)'; then
      echo ""
      echo "⚠️ INFRASTRUCTURE REVIEW GATE: You are staging critical files:"
      echo "$STAGED" | grep -E '(hooks/|CLAUDE\.md|\.claude/agents/|scripts/lib/|officer-capabilities|officer-skills/|constitution/)' | sed 's/^/  - /'
      echo ""
      echo "MANDATORY: Spawn a review subagent (Sonnet) BEFORE committing."
      echo "  1. bash -n on all .sh files"
      echo "  2. Agent review for bugs, edge cases, security"
      echo "  3. Fix any findings"
      echo "  4. THEN commit"
      echo "Skip review ONLY for: config files, working notes, experience records, backlog updates."
      echo ""
    fi
  fi
fi

# Section 12 removed — session snapshots now triggered by context window
# percentage (50/75/90%) in stop-hook.sh instead of blind tool-call count.

# Always exit 0 — post-hooks should never block
exit 0
