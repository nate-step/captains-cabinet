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
5. instance/memory/tier2/${OFFICER}/corrections.md — Captain corrections (mistakes to never repeat)

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
STATE_FILE="/opt/founders-cabinet/instance/memory/tier2/${OFFICER}/.session-state.json"
if [ -f "$STATE_FILE" ] && PARSED=$(jq '.' "$STATE_FILE" 2>/dev/null); then
  CAPTURED=$(echo "$PARSED" | jq -r '.captured_at // "unknown"')
  TOOL_CT=$(echo "$PARSED" | jq -r '.tool_calls // 0')
  TRIGGERS=$(echo "$PARSED" | jq -r '.pending_triggers // 0')

  # Check staleness — warn if state file is older than 2 hours
  CAPTURE_EPOCH=$(date -d "$CAPTURED" +%s 2>/dev/null || echo "0")
  NOW_EPOCH=$(date -u +%s)
  CAPTURE_AGE=$(( NOW_EPOCH - CAPTURE_EPOCH ))

  echo "SESSION STATE (captured at $CAPTURED, before compaction):"
  if [ "$CAPTURE_AGE" -gt 7200 ] 2>/dev/null; then
    echo "⚠️ WARNING: State is $((CAPTURE_AGE / 3600))h old — may not reflect current session."
  fi
  echo "- Tool calls this session: $TOOL_CT"
  echo "- Pending triggers at compaction: $TRIGGERS"

  # Print schedule timestamps
  SCHED=$(echo "$PARSED" | jq -r '.schedules // {} | to_entries[] | "  - \(.key): \(.value)"')
  if [ -n "$SCHED" ]; then
    echo "- Schedule last-run timestamps:"
    echo "$SCHED"
  fi
  echo ""
  echo "Read your working notes for full context: instance/memory/tier2/${OFFICER}/working-notes.md"
  echo ""
elif [ -f "$STATE_FILE" ]; then
  echo "⚠️ Pre-compaction state file exists but is corrupt. Read instance/memory/tier2/${OFFICER}/working-notes.md for context."
  echo ""
else
  echo "No pre-compaction state file found. Read instance/memory/tier2/${OFFICER}/working-notes.md for context."
  echo ""
fi

echo "Read the files above now before doing anything else. Do not skip this step."
echo ""
echo "MANDATORY REFLECTION (compaction = significant work happened):"
echo "Write a 3-level reflection to instance/memory/tier2/${OFFICER}/reflections/\$(date -u +%Y-%m-%d-%H%M).md:"
echo "  L1 WORK: What did I accomplish in this session? What worked, what failed?"
echo "  L2 WORKFLOW: What about my process could be better?"
echo "  L3 META: What pattern would improve the cabinet's improvement process itself?"
echo "Read memory/skills/holistic-thinking.md for the lens."
echo "Surface L2/L3 ideas to CoS via notify-officer.sh."
echo "After: redis-cli -h redis -p 6379 INCR cabinet:reflections:count"
echo ""
echo "THEN:"
echo "1. Check for pending triggers (hook auto-delivers, but manual: source /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh && trigger_read ${OFFICER})"
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
