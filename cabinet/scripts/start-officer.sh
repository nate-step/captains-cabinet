#!/bin/bash
# start-officer.sh — Start an Officer session in tmux
# Fully dynamic — no hardcoded officer list. Any officer with a bot token works.
#
# Usage: start-officer.sh <officer-abbreviation>
# Requires: TELEGRAM_<UPPER>_TOKEN in environment (e.g. TELEGRAM_CTO_TOKEN)

OFFICER="${1:?Usage: start-officer.sh <officer-abbreviation>}"
CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"

# Source base env + active project env (if not already loaded)
if [ -f "$CABINET_ROOT/cabinet/.env" ]; then
  set -a; source "$CABINET_ROOT/cabinet/.env" 2>/dev/null; set +a
fi
ACTIVE_SLUG=$(cat "$CABINET_ROOT/config/active-project.txt" 2>/dev/null | tr -d '[:space:]')
if [ -n "$ACTIVE_SLUG" ] && [ -f "$CABINET_ROOT/cabinet/env/${ACTIVE_SLUG}.env" ]; then
  set -a; source "$CABINET_ROOT/cabinet/env/${ACTIVE_SLUG}.env" 2>/dev/null; set +a
fi

# Dynamic bot token lookup — constructs env var name from officer abbreviation
TOKEN_VAR="TELEGRAM_${OFFICER^^}_TOKEN"
BOT_TOKEN="${!TOKEN_VAR:?$TOKEN_VAR not set in environment}"

WINDOW="officer-$OFFICER"
STATE_DIR="/home/cabinet/.claude-channels/$OFFICER"
CABINET_ROOT="/opt/founders-cabinet"

mkdir -p "$STATE_DIR/telegram"
echo "TELEGRAM_BOT_TOKEN=$BOT_TOKEN" > "$STATE_DIR/telegram/.env"

# Each officer gets their own working subdirectory so --continue resumes
# the correct session (Claude Code scopes sessions by working directory).
OFFICER_DIR="$CABINET_ROOT/officers/$OFFICER"
mkdir -p "$OFFICER_DIR"
ln -sfn "$CABINET_ROOT/CLAUDE.md" "$OFFICER_DIR/CLAUDE.md"
ln -sfn "$CABINET_ROOT/.claude" "$OFFICER_DIR/.claude"
ln -sfn "$CABINET_ROOT/constitution" "$OFFICER_DIR/constitution"
ln -sfn "$CABINET_ROOT/memory" "$OFFICER_DIR/memory"
ln -sfn "$CABINET_ROOT/shared" "$OFFICER_DIR/shared"
ln -sfn "$CABINET_ROOT/config" "$OFFICER_DIR/config"
ln -sfn "$CABINET_ROOT/cabinet" "$OFFICER_DIR/cabinet"

# Check if this officer has a previous session to continue
# Claude Code stores sessions in ~/.claude/projects/<encoded-path>/
ENCODED_PATH=$(echo "$OFFICER_DIR" | sed 's|/|-|g')
HAS_SESSION=false
if [ -d "/home/cabinet/.claude/projects/$ENCODED_PATH" ]; then
  HAS_SESSION=true
fi

# Build the claude command — use --continue only if a prior session exists
if [ "$HAS_SESSION" = true ]; then
  CLAUDE_CMD="claude --continue --channels plugin:telegram@claude-plugins-official --dangerously-load-development-channels server:redis-trigger-channel --dangerously-skip-permissions --effort max"
else
  CLAUDE_CMD="claude --channels plugin:telegram@claude-plugins-official --dangerously-load-development-channels server:redis-trigger-channel --dangerously-skip-permissions --effort max"
fi

# Kill any existing session for this officer
tmux kill-window -t "cabinet:$WINDOW" 2>/dev/null

# Start Claude Code session
tmux new-window -t cabinet -n "$WINDOW"
tmux send-keys -t "cabinet:$WINDOW" \
  "export OFFICER_NAME=$OFFICER TELEGRAM_STATE_DIR=$STATE_DIR TELEGRAM_BOT_TOKEN=$BOT_TOKEN TELEGRAM_HQ_CHAT_ID=$TELEGRAM_HQ_CHAT_ID && cd $OFFICER_DIR && $CLAUDE_CMD" \
  Enter

# Wait for Claude Code to initialize, then send boot prompt + polling loop
(
  sleep 20  # Give Claude Code time to load

  # Send boot prompt — tells the officer to initialize and announce
  tmux send-keys -t "cabinet:$WINDOW" "You are $OFFICER. Read your role definition at .claude/agents/$OFFICER.md and your session start checklist. Read your foundation skills in memory/skills/. Read your tier 2 notes in memory/tier2/$OFFICER/. Then announce yourself on the warroom: bash /opt/founders-cabinet/cabinet/scripts/send-to-group.sh '<b>$OFFICER online.</b> Session started. Checking for pending work.' — then check for pending triggers and overdue work immediately." Enter

  sleep 30  # Give time to boot and announce

  # Read loop prompt from file, fall back to generic default
  LOOP_FILE="$CABINET_ROOT/cabinet/loop-prompts/${OFFICER}.txt"
  if [ -f "$LOOP_FILE" ]; then
    LOOP_PROMPT=$(cat "$LOOP_FILE")
  else
    LOOP_PROMPT="Triggers deliver instantly via Redis Channel — no polling needed. Check if reflection is overdue (every 6h). Process anything that needs attention."
  fi

  tmux send-keys -t "cabinet:$WINDOW" "/loop 2m $LOOP_PROMPT" Enter
) &

echo "Started $OFFICER in cabinet:$WINDOW (has_session=$HAS_SESSION, loop in ~20s)"
