#!/bin/bash
OFFICER="${1:?Usage: start-officer.sh <cos|cto|cro|cpo>}"
case "$OFFICER" in
  cos) BOT_TOKEN="${TELEGRAM_COS_TOKEN:?not set}" ;;
  cto) BOT_TOKEN="${TELEGRAM_CTO_TOKEN:?not set}" ;;
  cro) BOT_TOKEN="${TELEGRAM_CRO_TOKEN:?not set}" ;;
  cpo) BOT_TOKEN="${TELEGRAM_CPO_TOKEN:?not set}" ;;
  *) echo "Unknown: $OFFICER"; exit 1 ;;
esac

WINDOW="officer-$OFFICER"
STATE_DIR="/home/cabinet/.claude-channels/$OFFICER"
CABINET_ROOT="/opt/founders-cabinet"

mkdir -p "$STATE_DIR/telegram"
echo "TELEGRAM_BOT_TOKEN=$BOT_TOKEN" > "$STATE_DIR/telegram/.env"

# Each officer gets their own working subdirectory so --continue resumes
# the correct session (Claude Code scopes sessions by working directory).
# Symlink key framework files so Claude Code finds them.
OFFICER_DIR="$CABINET_ROOT/officers/$OFFICER"
mkdir -p "$OFFICER_DIR"
ln -sfn "$CABINET_ROOT/CLAUDE.md" "$OFFICER_DIR/CLAUDE.md"
ln -sfn "$CABINET_ROOT/.claude" "$OFFICER_DIR/.claude"
ln -sfn "$CABINET_ROOT/constitution" "$OFFICER_DIR/constitution"
ln -sfn "$CABINET_ROOT/memory" "$OFFICER_DIR/memory"
ln -sfn "$CABINET_ROOT/shared" "$OFFICER_DIR/shared"
ln -sfn "$CABINET_ROOT/config" "$OFFICER_DIR/config"
ln -sfn "$CABINET_ROOT/cabinet" "$OFFICER_DIR/cabinet"

# Kill any existing session for this officer
tmux kill-window -t "cabinet:$WINDOW" 2>/dev/null

# Start Claude Code session — --continue resumes this officer's last session
tmux new-window -t cabinet -n "$WINDOW"
tmux send-keys -t "cabinet:$WINDOW" \
  "export OFFICER_NAME=$OFFICER TELEGRAM_STATE_DIR=$STATE_DIR TELEGRAM_BOT_TOKEN=$BOT_TOKEN TELEGRAM_HQ_CHAT_ID=\$TELEGRAM_HQ_CHAT_ID && cd $OFFICER_DIR && claude --continue --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions --effort max" \
  Enter

# Wait for Claude Code to initialize, then auto-set up the polling loop
# The loop is session-scoped and dies on restart, so we re-create it every time
(
  sleep 15  # Give Claude Code time to load and resume

  # Build the loop prompt based on officer role
  case "$OFFICER" in
    cos)
      LOOP_PROMPT="Check triggers: redis-cli -h redis -p 6379 LRANGE cabinet:triggers:cos 0 -1 — process each, then DEL. Check overdue: briefings 07:00+19:00 CET, reflection 6h, retro+evolution 24h."
      ;;
    cto)
      LOOP_PROMPT="Check triggers: redis-cli -h redis -p 6379 LRANGE cabinet:triggers:cto 0 -1 — process each, then DEL. Check overdue: reflection 6h. Check shared/interfaces/product-specs/ for new specs."
      ;;
    cpo)
      LOOP_PROMPT="Check triggers: redis-cli -h redis -p 6379 LRANGE cabinet:triggers:cpo 0 -1 — process each, then DEL. Check overdue: backlog refinement 12h, reflection 6h."
      ;;
    cro)
      LOOP_PROMPT="Check triggers: redis-cli -h redis -p 6379 LRANGE cabinet:triggers:cro 0 -1 — process each, then DEL. Check overdue: research sweep 4h, reflection 6h."
      ;;
  esac

  tmux send-keys -t "cabinet:$WINDOW" "/loop 5m $LOOP_PROMPT" Enter
) &

echo "Started $OFFICER in cabinet:$WINDOW (loop will auto-setup in ~15s)"
