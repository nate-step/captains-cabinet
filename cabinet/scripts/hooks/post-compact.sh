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

case "$OFFICER" in
  cos)
    echo "- You are CoS. Check scheduled work: briefings (07:00 + 19:00 CET), reflection (every 6h), retro (every 24h at 03:00 UTC)."
    echo "- Use 'Nate' not 'Captain' in all communications."
    ;;
  cto)
    echo "- memory/skills/engineering-development-loop.md — your dev workflow"
    echo "- Captain Decision Logging is MANDATORY: after every Telegram reply to Nate, check if a decision was made. Label in Linear + comment with WHY."
    echo "- Visual verification: screenshot and compare UI against design reference before marking done."
    echo "- AGENT TEAMS (not sub-agents): Use TeamCreate for all code changes. Worker + reviewer teammates iterate independently. You only handle: plan → create team → review → push/merge/deploy."
    echo "- NEVER edit product code directly or via Bash workarounds. The hook will block you."
    ;;
  cpo)
    echo "- memory/skills/spec-quality-gate.md — spec quality requirements"
    echo "- Pipeline Ownership: CTO must NEVER be idle. Feed them work continuously."
    echo "- Visual verification: screenshot live result when reviewing CTO implementations."
    echo "- 8 proactive responsibilities — run them continuously, don't wait to be asked."
    ;;
  cro)
    echo "- memory/skills/research-quality-gate.md — research brief quality"
    echo "- You have 10 research streams with a cadence table in your role definition."
    echo "- Claude Code daily research is mandatory once per day."
    echo "- Use search-research.sh to check prior research before each sweep."
    ;;
  coo)
    echo "- memory/skills/proactive-quality-audit.md — quality audit protocol"
    echo "- Visual verification: Playwright/Chromium is your primary tool. Screenshot every flow."
    echo "- Pre-launch quality gate document — maintain the go/no-go checklist."
    ;;
esac

echo ""
echo "Read these files now before doing anything else. Do not skip this step."
echo ""
echo "THEN: Check Redis for pending triggers (redis-cli -h redis -p 6379 LRANGE cabinet:triggers:${OFFICER} 0 -1) and verify your /loop is still running. If not, re-create it per your session start checklist."

exit 0
