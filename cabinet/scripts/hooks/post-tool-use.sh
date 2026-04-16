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

# Write JSON log line
echo "{\"ts\":\"$TIMESTAMP\",\"officer\":\"$OFFICER\",\"tool\":\"$TOOL_NAME\",\"input\":$(echo "$TOOL_INPUT" | jq -c '.' 2>/dev/null || echo '{}'),\"output_preview\":$(echo "$TRUNCATED_OUTPUT" | jq -Rs '.' 2>/dev/null || echo '\"\"')}" >> "$LOG_FILE"

# ============================================================
# 2. COST TRACKING (rough estimate)
# ============================================================
INPUT_TOKENS=$(echo "$TOOL_INPUT" | wc -c)
OUTPUT_TOKENS=$(echo "$TOOL_OUTPUT" | wc -c)

# Rough cost estimate in cents (very approximate)
# Opus: ~$15/MTok input, ~$75/MTok output → ~0.0015¢/char in, ~0.0075¢/char out
# Using ~4 chars per token as rough estimate
COST_CENTS=$(( (INPUT_TOKENS * 15 / 4000000 + OUTPUT_TOKENS * 75 / 4000000) ))
COST_CENTS=$((COST_CENTS > 0 ? COST_CENTS : 1))  # minimum 1 cent per action

# Increment daily cost counter (expires after 48h)
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INCRBY "cabinet:cost:daily:$TODAY" "$COST_CENTS" > /dev/null 2>&1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:cost:daily:$TODAY" 172800 > /dev/null 2>&1

# Increment per-officer daily counter
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INCRBY "cabinet:cost:officer:$OFFICER:$TODAY" "$COST_CENTS" > /dev/null 2>&1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:cost:officer:$OFFICER:$TODAY" 172800 > /dev/null 2>&1

# Increment monthly counter
MONTH=$(date -u +%Y-%m)
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INCRBY "cabinet:cost:monthly:$MONTH" "$COST_CENTS" > /dev/null 2>&1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:cost:monthly:$MONTH" 2764800 > /dev/null 2>&1

# ============================================================
# 3. EXPERIENCE RECORD NUDGE
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
  if echo "$CMD" | grep -qE 'git push.*main|git push.*origin main|gh pr merge'; then
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
  if echo "$CMD" | grep -qE 'git push.*main|gh pr merge'; then
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
