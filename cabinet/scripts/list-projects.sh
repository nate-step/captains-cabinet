#!/bin/bash
# list-projects.sh — List all available projects
# Shows slug, product name, and active status.

CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
PROJECTS_DIR="$CABINET_ROOT/config/projects"
ACTIVE_FILE="$CABINET_ROOT/instance/config/active-project.txt"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"

# Get active project
ACTIVE=""
if command -v redis-cli &>/dev/null; then
  ACTIVE=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:active-project" 2>/dev/null)
fi
[ -z "$ACTIVE" ] || [ "$ACTIVE" = "(nil)" ] && ACTIVE=$(cat "$ACTIVE_FILE" 2>/dev/null | tr -d '[:space:]')

echo "Available projects:"
echo ""
for f in "$PROJECTS_DIR"/*.yml; do
  [ ! -f "$f" ] && continue
  SLUG=$(basename "$f" .yml)
  [ "$SLUG" = "_template" ] && continue
  NAME=$(grep '  name:' "$f" | head -1 | sed 's/.*name:[[:space:]]*//' | tr -d '"')
  if [ "$SLUG" = "$ACTIVE" ]; then
    echo "  * $SLUG — $NAME (ACTIVE)"
  else
    echo "    $SLUG — $NAME"
  fi
done
echo ""
