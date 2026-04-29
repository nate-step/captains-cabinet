#!/bin/bash
# start-officer.sh — Start an Officer session in tmux
# Fully dynamic — no hardcoded officer list. Any officer with a bot token works.
#
# Usage:
#   Legacy (single-project):  start-officer.sh <officer>
#   Pool (FW-073, multi-project): start-officer.sh <officer> --project <slug>
#
# Pool mode (--project given) scopes the tmux window AND working dir per
# (officer, project) so claude --continue resumes per-project sessions, and
# exports CABINET_ACTIVE_PROJECT into the subshell so cost-counter hooks
# (FW-072) write per-project HSET fields. Legacy mode is unchanged.
#
# Requires: TELEGRAM_<UPPER>_TOKEN in environment (e.g. TELEGRAM_CTO_TOKEN)

OFFICER="${1:?Usage: start-officer.sh <officer> [--project <slug>]}"
shift

PROJECT=""
POOL_MODE=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      PROJECT="${2:?--project requires a slug argument}"
      # slug allowlist: lowercase alnum + hyphens, must NOT lead with hyphen
      # (so it cannot be confused with a flag in any downstream invocation).
      # Pool windows + workdirs + Redis stream suffix use this verbatim, so
      # rejecting shell-special chars closes a path-injection vector.
      if ! [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        echo "start-officer.sh: --project slug must match [a-z0-9][a-z0-9-]* (got '$PROJECT')" >&2
        exit 1
      fi
      if [ "${#PROJECT}" -gt 32 ]; then
        echo "start-officer.sh: --project slug must be ≤32 chars (got ${#PROJECT})" >&2
        exit 1
      fi
      POOL_MODE=true
      shift 2
      ;;
    *)
      echo "start-officer.sh: unknown argument '$1'" >&2
      echo "Usage: start-officer.sh <officer> [--project <slug>]" >&2
      exit 1
      ;;
  esac
done

CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"

# Source base env + active project env (if not already loaded)
if [ -f "$CABINET_ROOT/cabinet/.env" ]; then
  set -a; source "$CABINET_ROOT/cabinet/.env" 2>/dev/null; set +a
fi

# Assemble runtime Cabinet state (framework + preset + instance) before
# launching the officer's Claude Code session. Idempotent — safe to run on
# every officer start. See cabinet/scripts/load-preset.sh.
bash "$CABINET_ROOT/cabinet/scripts/load-preset.sh" 2>&1 | tail -3 >&2

# Resolve project slug:
#   Pool mode: --project explicit (per-window scoping)
#   Legacy mode: fall back to instance/config/active-project.txt (single-project)
if [ "$POOL_MODE" = true ]; then
  ACTIVE_SLUG="$PROJECT"
  if [ ! -f "$CABINET_ROOT/cabinet/env/${ACTIVE_SLUG}.env" ]; then
    echo "start-officer.sh: pool mode requires cabinet/env/${ACTIVE_SLUG}.env" >&2
    echo "  (provision via cabinet/scripts/create-project.sh ${ACTIVE_SLUG})" >&2
    exit 1
  fi
else
  ACTIVE_SLUG=$(cat "$CABINET_ROOT/instance/config/active-project.txt" 2>/dev/null | tr -d '[:space:]')
fi
if [ -n "$ACTIVE_SLUG" ] && [ -f "$CABINET_ROOT/cabinet/env/${ACTIVE_SLUG}.env" ]; then
  set -a; source "$CABINET_ROOT/cabinet/env/${ACTIVE_SLUG}.env" 2>/dev/null; set +a
fi

# ---------------------------------------------------------------
# Bot mode resolution (FW-084 / Spec 034 v3 AC #62)
# ---------------------------------------------------------------
# Read bot_mode + ceo_officer from the active project YAML (if present).
# Fallback: multi_officer (legacy behavior, preserves all pre-FW-084 cabinets).
#
# YAML keys read:
#   telegram.bot_mode    — single_ceo | multi_officer
#   telegram.ceo_officer — officer slug that acts as CEO (default: cos)
#
# In single_ceo mode:
#   - CEO officer  → receives TELEGRAM_BOT_TOKEN from TELEGRAM_<SLUG>_CEO_TOKEN
#     and gets Telegram channel plugin (polls Telegram, receives Captain DMs).
#   - Non-CEO officers → no TELEGRAM_BOT_TOKEN injected, no --channels plugin:telegram
#     (they are Telegram-dark; Captain-attention goes via the queue instead).
#
# In multi_officer mode (legacy): all officers get their own bot token (existing behavior).
#
# Adversary note (FW-084): non-CEO officers in single_ceo mode must NOT have
# TELEGRAM_BOT_TOKEN set — this prevents the channels plugin from initializing
# and closes the "non-CEO bypasses queue" attack surface. The token env var is
# the initialization gate; without it the plugin cannot start.

BOT_MODE="multi_officer"  # safe default — preserves all existing behavior
CEO_OFFICER="cos"         # canonical default per AC #75

if [ -n "$ACTIVE_SLUG" ] && [ -f "$CABINET_ROOT/instance/config/projects/${ACTIVE_SLUG}.yml" ]; then
  _PROJECT_YML="$CABINET_ROOT/instance/config/projects/${ACTIVE_SLUG}.yml"
  _read_yml_field() {
    local file="$1" key="$2"
    grep -E "^[[:space:]]*${key}:[[:space:]]" "$file" 2>/dev/null \
      | head -1 | sed "s/^[[:space:]]*${key}:[[:space:]]*//" | tr -d '"' | tr -d "'" | tr -d '[:space:]'
  }
  _bot_mode_raw=$(_read_yml_field "$_PROJECT_YML" "bot_mode")
  _ceo_officer_raw=$(_read_yml_field "$_PROJECT_YML" "ceo_officer")
  # Validate: only accept known mode values (reject injection attempts)
  if [ "$_bot_mode_raw" = "single_ceo" ] || [ "$_bot_mode_raw" = "multi_officer" ]; then
    BOT_MODE="$_bot_mode_raw"
  fi
  # Validate: ceo_officer must match slug allowlist (mirrors FW-073 regex)
  if [[ "$_ceo_officer_raw" =~ ^[a-z0-9][a-z0-9-]*$ ]] && [ "${#_ceo_officer_raw}" -le 32 ]; then
    CEO_OFFICER="$_ceo_officer_raw"
  fi
fi

# Dynamic bot token lookup — constructs env var name from officer abbreviation.
# Behavior differs by bot_mode (FW-084):
#
#   multi_officer: TELEGRAM_<UPPER_OFFICER>_TOKEN (existing behavior — unchanged)
#   single_ceo + OFFICER == CEO_OFFICER: TELEGRAM_<UPPER_SLUG>_CEO_TOKEN
#   single_ceo + OFFICER != CEO_OFFICER: no token; this officer is Telegram-dark

BOT_TOKEN=""
IS_CEO_OFFICER=false

if [ "$BOT_MODE" = "single_ceo" ]; then
  if [ "$OFFICER" = "$CEO_OFFICER" ]; then
    IS_CEO_OFFICER=true
    # CEO token var: TELEGRAM_<UPPER_SLUG>_CEO_TOKEN (one bot per project)
    # If no project slug, fall back to TELEGRAM_CEO_TOKEN
    if [ -n "$ACTIVE_SLUG" ]; then
      _SLUG_UPPER="$(echo "${ACTIVE_SLUG^^}" | tr "-" "_")"
      CEO_TOKEN_VAR="TELEGRAM_${_SLUG_UPPER}_CEO_TOKEN"
    else
      CEO_TOKEN_VAR="TELEGRAM_CEO_TOKEN"
    fi
    BOT_TOKEN="${!CEO_TOKEN_VAR:-}"
    if [ -z "$BOT_TOKEN" ]; then
      # Friendly error: tell operator exactly which env var to set
      echo "start-officer.sh: single_ceo mode — $CEO_TOKEN_VAR not set in environment" >&2
      echo "  Set this to the CEO bot token (one BotFather bot per project)." >&2
      echo "  For project '$ACTIVE_SLUG', add $CEO_TOKEN_VAR to cabinet/env/${ACTIVE_SLUG}.env" >&2
      exit 1
    fi
  else
    # Non-CEO officer in single_ceo mode: Telegram-dark. No bot token needed.
    IS_CEO_OFFICER=false
    BOT_TOKEN=""
  fi
else
  # multi_officer mode (legacy): each officer has their own token
  TOKEN_VAR="TELEGRAM_$(echo "${OFFICER^^}" | tr "-" "_")_TOKEN"
  BOT_TOKEN="${!TOKEN_VAR:?$TOKEN_VAR not set in environment}"
fi

# Pool mode scopes tmux window AND working dir per (officer, project).
# Legacy mode keeps the single-officer layout intact (back-compat).
if [ "$POOL_MODE" = true ]; then
  WINDOW="officer-$OFFICER-$ACTIVE_SLUG"
  OFFICER_DIR="$CABINET_ROOT/officers/$OFFICER/$ACTIVE_SLUG"
else
  WINDOW="officer-$OFFICER"
  OFFICER_DIR="$CABINET_ROOT/officers/$OFFICER"
fi
STATE_DIR="/home/cabinet/.claude-channels/$OFFICER"

# Write the Telegram state .env only when this officer has a bot token.
# In single_ceo mode, non-CEO officers are Telegram-dark: no token written,
# so the channels plugin cannot initialize even if somehow invoked.
mkdir -p "$STATE_DIR/telegram"
if [ -n "$BOT_TOKEN" ]; then
  echo "TELEGRAM_BOT_TOKEN=$BOT_TOKEN" > "$STATE_DIR/telegram/.env"
else
  # Explicitly clear any stale token from a previous multi_officer run.
  # Without this, a restarted non-CEO officer could inherit the old token
  # and gain Telegram access it should not have (adversary surface FW-084).
  echo "" > "$STATE_DIR/telegram/.env"
fi

# Each officer gets their own working subdirectory so --continue resumes
# the correct session (Claude Code scopes sessions by working directory).
# In pool mode, each (officer, project) is its own working dir → distinct
# session per project, switchable via tmux select-window.
mkdir -p "$OFFICER_DIR"
ln -sfn "$CABINET_ROOT/CLAUDE.md" "$OFFICER_DIR/CLAUDE.md"
ln -sfn "$CABINET_ROOT/.claude" "$OFFICER_DIR/.claude"
ln -sfn "$CABINET_ROOT/constitution" "$OFFICER_DIR/constitution"
ln -sfn "$CABINET_ROOT/memory" "$OFFICER_DIR/memory"
ln -sfn "$CABINET_ROOT/shared" "$OFFICER_DIR/shared"
ln -sfn "$CABINET_ROOT/cabinet" "$OFFICER_DIR/cabinet"
ln -sfn "$CABINET_ROOT/framework" "$OFFICER_DIR/framework"
ln -sfn "$CABINET_ROOT/presets" "$OFFICER_DIR/presets"
ln -sfn "$CABINET_ROOT/instance" "$OFFICER_DIR/instance"

# Check if this officer has a previous session to continue
# Claude Code stores sessions in ~/.claude/projects/<encoded-path>/
ENCODED_PATH=$(echo "$OFFICER_DIR" | sed 's|/|-|g')
HAS_SESSION=false
if [ -d "/home/cabinet/.claude/projects/$ENCODED_PATH" ]; then
  HAS_SESSION=true
fi

# Build the claude command — use --continue only if a prior session exists
# Model pinned to claude-opus-4-7 (Captain approved fleet-wide Apr 16) —
# 1M context is standard in 4.7 (no tier suffix). Override via CABINET_MODEL env.
#
# FW-084 bot mode gating:
#   - multi_officer OR (single_ceo AND IS_CEO_OFFICER): include --channels plugin:telegram
#   - single_ceo AND non-CEO: omit telegram plugin entirely (officer is Telegram-dark)
MODEL="${CABINET_MODEL:-claude-opus-4-7}"
_BASE_FLAGS="--model $MODEL --dangerously-load-development-channels server:redis-trigger-channel --dangerously-skip-permissions --effort max"
if [ "$BOT_MODE" = "single_ceo" ] && [ "$IS_CEO_OFFICER" = false ]; then
  # Non-CEO in single_ceo mode: no Telegram plugin. Officer operates headless —
  # Captain-attention reaches Captain via the queue (cabinet:captain-attention:<project>).
  _CHANNEL_FLAGS=""
else
  # CEO officer OR multi_officer mode: include Telegram plugin as before.
  _CHANNEL_FLAGS="--channels plugin:telegram@claude-plugins-official"
fi
if [ "$HAS_SESSION" = true ]; then
  CLAUDE_CMD="claude --continue $_BASE_FLAGS $_CHANNEL_FLAGS"
else
  CLAUDE_CMD="claude $_BASE_FLAGS $_CHANNEL_FLAGS"
fi

# Per-window env injection. CABINET_ACTIVE_PROJECT is set ONLY in pool mode
# so legacy single-project deployments preserve the FW-072 cost-counter
# legacy field shape (`<officer>_<dim>`); pool mode opts into the per-project
# shape (`<officer>_<project>_<dim>`). Defensive unset before the conditional
# guards against env-file pollution: if a future cabinet/env/<slug>.env ever
# exports CABINET_ACTIVE_PROJECT, `set -a; source` would propagate it into
# this shell — the unset ensures only the pool-mode branch can write it
# into the tmux subshell.
unset CABINET_ACTIVE_PROJECT
# FW-084: in single_ceo mode, non-CEO officers do NOT get TELEGRAM_BOT_TOKEN or
# TELEGRAM_HQ_CHAT_ID — they are Telegram-dark. CEO officer gets both as before.
# multi_officer mode (legacy): all officers get full Telegram env (unchanged).
if [ "$BOT_MODE" = "single_ceo" ] && [ "$IS_CEO_OFFICER" = false ]; then
  # Non-CEO: no Telegram env vars. Captain-attention flows via queue.
  EXPORT_VARS="OFFICER_NAME=$OFFICER TELEGRAM_STATE_DIR=$STATE_DIR CABINET_BOT_MODE=$BOT_MODE CABINET_CEO_OFFICER=$CEO_OFFICER"
else
  # CEO or multi_officer: full Telegram env
  EXPORT_VARS="OFFICER_NAME=$OFFICER TELEGRAM_STATE_DIR=$STATE_DIR TELEGRAM_BOT_TOKEN=$BOT_TOKEN TELEGRAM_HQ_CHAT_ID=$TELEGRAM_HQ_CHAT_ID CABINET_BOT_MODE=$BOT_MODE CABINET_CEO_OFFICER=$CEO_OFFICER"
fi
if [ "$POOL_MODE" = true ]; then
  EXPORT_VARS="$EXPORT_VARS CABINET_ACTIVE_PROJECT=$ACTIVE_SLUG"
fi

# Test hook: CABINET_TEST_DRY_RUN=1 dumps resolved arg-derived contracts and
# exits before any side-effectful tmux/claude calls. Used by the FW-073
# test harness to pin arg parsing + back-compat without spawning real sessions.
# FW-084: also exposes BOT_MODE, CEO_OFFICER, IS_CEO_OFFICER for test assertions.
if [ "${CABINET_TEST_DRY_RUN:-}" = "1" ]; then
  printf 'POOL_MODE=%s\nWINDOW=%s\nOFFICER_DIR=%s\nACTIVE_SLUG=%s\nEXPORT_VARS=%s\nBOT_MODE=%s\nCEO_OFFICER=%s\nIS_CEO_OFFICER=%s\n' \
    "$POOL_MODE" "$WINDOW" "$OFFICER_DIR" "$ACTIVE_SLUG" "$EXPORT_VARS" \
    "$BOT_MODE" "$CEO_OFFICER" "$IS_CEO_OFFICER"
  exit 0
fi

# Kill any existing session for this (officer, project) tuple
tmux kill-window -t "cabinet:$WINDOW" 2>/dev/null

# Start Claude Code session
tmux new-window -t cabinet -n "$WINDOW"
tmux send-keys -t "cabinet:$WINDOW" \
  "export $EXPORT_VARS && cd $OFFICER_DIR && $CLAUDE_CMD" \
  Enter

# Wait for Claude Code to initialize, auto-confirm any startup prompts,
# then send the boot prompt.
(
  # Smart prompt detection: capture the tmux pane and respond to whichever
  # startup gates Claude Code shows us. Replaces fragile fixed sleeps —
  # poll the pane for known prompts and Enter through them, then break out
  # once we see the stable input prompt.
  #
  # Known prompts we auto-confirm (default = Enter):
  #   1. "--dangerously-load-development-channels" warning
  #      ("I am using this for local development" / "Exit")
  #   2. Resume conversation prompt when --continue is used
  #      ("Continue as-is" / "Summarize and continue") — defaults to as-is
  #   3. Folder/hook trust dialogs — should be pre-suppressed by
  #      prepare-claude-state.sh on container start, but handled defensively
  #      in case the .claude.json template missed this officer's path
  PANE="cabinet:$WINDOW"
  PROMPT_REGEX="(I am using this for local development|Continue (as-is|conversation)|Summari[sz]e|Trust the (files|hooks)|Do you trust|Choose your theme|Welcome to Claude)"
  DEADLINE=$(($(date +%s) + 45))   # 45s budget for all startup prompts

  while [ $(date +%s) -lt $DEADLINE ]; do
    sleep 2
    pane_output=$(tmux capture-pane -t "$PANE" -p 2>/dev/null | tail -30)
    if echo "$pane_output" | grep -qE "$PROMPT_REGEX"; then
      tmux send-keys -t "$PANE" Enter
      sleep 1   # let the UI redraw before checking again
    elif echo "$pane_output" | grep -qE "(Try.*for new ideas|tab.*complete|Bypassing Permissions|^\s*>\s*$)"; then
      # Stable prompt indicators — Claude Code is ready for user input
      break
    fi
  done

  # Brief settle window before sending the boot prompt
  sleep 2

  # Send boot prompt — tells the officer to initialize and announce
  tmux send-keys -t "$PANE" "You are $OFFICER. Read your role definition at .claude/agents/$OFFICER.md and your session start checklist. Read your foundation skills in memory/skills/. Read your tier 2 notes in instance/memory/tier2/$OFFICER/. Then announce yourself on the warroom: bash /opt/founders-cabinet/cabinet/scripts/send-to-group.sh '<b>$OFFICER online.</b> Session started. Checking for pending work.' — then check for pending triggers and overdue work immediately." Enter

  # No permanent /loop needed — Redis Trigger Channel delivers all triggers
  # and scheduled work instantly. /loop is available for ad-hoc use only.
) &

if [ "$POOL_MODE" = true ]; then
  echo "Started $OFFICER (project=$ACTIVE_SLUG) in cabinet:$WINDOW (has_session=$HAS_SESSION, loop in ~20s)"
else
  echo "Started $OFFICER in cabinet:$WINDOW (has_session=$HAS_SESSION, loop in ~20s)"
fi
