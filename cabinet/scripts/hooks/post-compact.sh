#!/bin/bash
# post-compact.sh — Fires after context compaction (auto or manual)
# Outputs essential skill refresh instructions as a system message.
# The output is injected directly into the officer's context.

OFFICER="${OFFICER_NAME:-unknown}"

cat <<REFRESH
⚠️ CONTEXT COMPACTED — ESSENTIAL SKILL REFRESH REQUIRED

Your context was just compressed. Behavioral rules loaded earlier in this session may be lost. Re-read your essential skills NOW before continuing any work.

ALL OFFICERS — read these immediately:
1. memory/skills/evolved/telegram-communication.md — reactions (react to EVERY Captain message before replying), threading (always use reply_to), formatting rules, SEND FILES when referencing paths (Captain cannot access the server filesystem — attach files with reply(files=[...]))
2. memory/skills/evolved/individual-reflection.md — 6h cadence + value maximization step
3. shared/interfaces/captain-decisions.md — Captain Decision Trail (check before any design/UI work)
4. Your role definition in .claude/agents/${OFFICER}.md — re-read your full role
5. memory/tier2/${OFFICER}/corrections.md — Captain corrections (mistakes to never repeat)

OFFICER-SPECIFIC — also read:
REFRESH

# Load officer-specific skill refresh from per-officer file (officer-agnostic)
SKILLS_FILE="/opt/founders-cabinet/cabinet/officer-skills/${OFFICER}.txt"
if [ -f "$SKILLS_FILE" ]; then
  cat "$SKILLS_FILE"
else
  echo "- No officer-specific skills file found at ${SKILLS_FILE}."
  echo "- Re-read your role definition at .claude/agents/${OFFICER}.md for your specific responsibilities."
fi

echo ""

# ============================================================
# SESSION STATE RECOVERY — inject pre-compaction operational state
# ============================================================
STATE_FILE="/opt/founders-cabinet/memory/tier2/${OFFICER}/.session-state.json"
if [ -f "$STATE_FILE" ]; then
  CAPTURED=$(jq -r '.captured_at // "unknown"' "$STATE_FILE" 2>/dev/null)
  TOOL_CT=$(jq -r '.tool_calls // 0' "$STATE_FILE" 2>/dev/null)
  TRIGGERS=$(jq -r '.pending_triggers // 0' "$STATE_FILE" 2>/dev/null)

  echo "SESSION STATE (captured at $CAPTURED, before compaction):"
  echo "- Tool calls this session: $TOOL_CT"
  echo "- Pending triggers at compaction: $TRIGGERS"

  # Print schedule timestamps
  SCHED=$(jq -r '.schedules // {} | to_entries[] | "  - \(.key): \(.value)"' "$STATE_FILE" 2>/dev/null)
  if [ -n "$SCHED" ]; then
    echo "- Schedule last-run timestamps:"
    echo "$SCHED"
  fi
  echo ""
  echo "Read your working notes for full context: memory/tier2/${OFFICER}/working-notes.md"
  echo ""
else
  echo "No pre-compaction state file found. Read memory/tier2/${OFFICER}/working-notes.md for context."
  echo ""
fi

echo "Read the files above now before doing anything else. Do not skip this step."
echo ""
echo "THEN:"
echo "1. Check Redis for pending triggers: redis-cli -h redis -p 6379 LRANGE cabinet:triggers:${OFFICER} 0 -1"
echo "2. Re-create your /loop (safety net — will skip if already running):"

# Read the officer's loop prompt from file
LOOP_FILE="/opt/founders-cabinet/cabinet/loop-prompts/${OFFICER}.txt"
if [ -f "$LOOP_FILE" ]; then
  LOOP_PROMPT=$(cat "$LOOP_FILE" | tr '\n' ' ' | head -c 200)
  echo "   /loop 5m ${LOOP_PROMPT}..."
else
  echo "   /loop 5m Check triggers and do proactive work per your role definition."
fi

exit 0
