#!/bin/bash
# switch-project.sh — Switch the active project for all officers
# Stops officers, assembles new config, restarts officers.
#
# Usage: switch-project.sh <project-slug>
# Example: switch-project.sh newco
#
# Can be called by:
#   - CoS via Telegram (bash /opt/founders-cabinet/cabinet/scripts/switch-project.sh newco)
#   - Dashboard (via docker exec)
#   - Direct CLI (ssh into server)

set -euo pipefail

SLUG="${1:?Usage: switch-project.sh <project-slug>}"
CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
PROJECTS_DIR="$CABINET_ROOT/config/projects"
PROJECT_FILE="$PROJECTS_DIR/${SLUG}.yml"
ENV_DIR="$CABINET_ROOT/cabinet/env"
PROJECT_ENV="$ENV_DIR/${SLUG}.env"
BASE_ENV="$CABINET_ROOT/cabinet/.env"
ACTIVE_FILE="$CABINET_ROOT/config/active-project.txt"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"

log() { echo "[switch-project] $1"; }

# --- Validate ---
if [ ! -f "$PROJECT_FILE" ]; then
  echo "Error: Project config not found: $PROJECT_FILE" >&2
  echo "Available projects:" >&2
  ls "$PROJECTS_DIR"/*.yml 2>/dev/null | xargs -I{} basename {} .yml | grep -v _template >&2
  exit 1
fi

# Get current project for announcement
CURRENT=""
if command -v redis-cli &>/dev/null; then
  CURRENT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:active-project" 2>/dev/null)
fi
[ -z "$CURRENT" ] || [ "$CURRENT" = "(nil)" ] && CURRENT=$(cat "$ACTIVE_FILE" 2>/dev/null | tr -d '[:space:]')

if [ "$CURRENT" = "$SLUG" ]; then
  log "Already on project: $SLUG"
  exit 0
fi

PRODUCT_NAME=$(grep '  name:' "$PROJECT_FILE" | head -1 | sed 's/.*name:[[:space:]]*//' | tr -d '"')
log "Switching from '$CURRENT' to '$SLUG' ($PRODUCT_NAME)"

# --- Step 1: Stop all running officers ---
log "Stopping all officers..."
WINDOWS=$(tmux list-windows -t cabinet -F '#{window_name}' 2>/dev/null | grep '^officer-' || true)
for w in $WINDOWS; do
  tmux kill-window -t "cabinet:$w" 2>/dev/null || true
done
log "All officers stopped"

# --- Step 2: Update Redis active project ---
if command -v redis-cli &>/dev/null; then
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "cabinet:active-project" "$SLUG" > /dev/null 2>&1
  log "Redis: cabinet:active-project = $SLUG"
fi
echo "$SLUG" > "$ACTIVE_FILE"

# --- Step 3: Assemble new config ---
bash "$CABINET_ROOT/cabinet/scripts/assemble-config.sh"

# --- Step 4: Source project env (if exists) ---
if [ -f "$PROJECT_ENV" ]; then
  log "Loading project env: $PROJECT_ENV"
  set -a
  source "$PROJECT_ENV"
  set +a
fi

# --- Step 5: Restart all expected-active officers ---
log "Restarting officers..."
if command -v redis-cli &>/dev/null; then
  EXPECTED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" KEYS "cabinet:officer:expected:*" 2>/dev/null | sed 's/cabinet:officer:expected://')
  for officer in $EXPECTED; do
    STATE=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:officer:expected:$officer" 2>/dev/null)
    if [ "$STATE" = "active" ]; then
      log "Starting $officer..."
      # Source both env files before starting
      (
        set -a
        source "$BASE_ENV" 2>/dev/null || true
        [ -f "$PROJECT_ENV" ] && source "$PROJECT_ENV"
        set +a
        bash "$CABINET_ROOT/cabinet/scripts/start-officer.sh" "$officer"
      )
      sleep 60  # Stagger restarts to avoid API rate limits
    fi
  done
fi

# --- Step 6: Announce ---
if [ -n "${TELEGRAM_HQ_CHAT_ID:-}" ]; then
  bash "$CABINET_ROOT/cabinet/scripts/send-to-group.sh" \
    "<b>Project switched to: ${PRODUCT_NAME}</b>
Officers are rebooting on the new project context." 2>/dev/null || true
fi

log ""
log "=========================================="
log " Switched to: ${SLUG} (${PRODUCT_NAME})"
log "=========================================="
log ""
log "Officers are booting with new context."
log "Config assembled: config/product.yml"
[ -f "$PROJECT_ENV" ] && log "Project env loaded: cabinet/env/${SLUG}.env"
log ""
