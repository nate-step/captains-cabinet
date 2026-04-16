#!/bin/bash
# install-starter-space.sh — Install a pre-defined Space into The Library
#
# Usage:
#   bash cabinet/scripts/install-starter-space.sh <template_name>
#
# Templates live in cabinet/starter-spaces/<template_name>.json
# Idempotent — installing the same starter twice updates the Space's
# description / schema but preserves any records already in it.

set -euo pipefail

TEMPLATE="${1:-}"
if [ -z "$TEMPLATE" ]; then
  echo "Usage: install-starter-space.sh <template_name>"
  echo ""
  echo "Available starters:"
  ls /opt/founders-cabinet/cabinet/starter-spaces/*.json 2>/dev/null | xargs -I{} basename {} .json | sed 's/^/  - /'
  exit 1
fi

TEMPLATE_FILE="/opt/founders-cabinet/cabinet/starter-spaces/${TEMPLATE}.json"
if [ ! -f "$TEMPLATE_FILE" ]; then
  echo "Starter template not found: $TEMPLATE_FILE"
  exit 1
fi

# Validate JSON
if ! jq -e . "$TEMPLATE_FILE" > /dev/null 2>&1; then
  echo "Starter template is not valid JSON: $TEMPLATE_FILE"
  exit 1
fi

# Source env + library
set -a
source /opt/founders-cabinet/cabinet/.env 2>/dev/null
set +a
source /opt/founders-cabinet/cabinet/scripts/lib/library.sh

# Extract fields from template
NAME=$(jq -r '.name' "$TEMPLATE_FILE")
DESC=$(jq -r '.description // ""' "$TEMPLATE_FILE")
STARTER=$(jq -r '.starter_template // ""' "$TEMPLATE_FILE")
SCHEMA_JSON=$(jq -c '.schema_json // {}' "$TEMPLATE_FILE")
ACCESS_RULES=$(jq -c '.access_rules // {}' "$TEMPLATE_FILE")

# Create or update the Space (UPSERT on name)
SPACE_ID=$(library_create_space "$NAME" "$DESC" "$SCHEMA_JSON" "$STARTER" "system" "$ACCESS_RULES")

if [ -z "$SPACE_ID" ]; then
  echo "Failed to create Space: $NAME"
  exit 1
fi

echo "Space '$NAME' installed (id=$SPACE_ID) from template $TEMPLATE"
