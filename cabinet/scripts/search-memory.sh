#!/bin/bash
# search-memory.sh — Query the Cabinet Memory layer
# Usage: search-memory.sh "<query>" [--type TYPE] [--officer OFFICER] [--limit N]

set -uo pipefail

QUERY=""
TYPE=""
OFFICER=""
LIMIT=10

while [ $# -gt 0 ]; do
  case "$1" in
    --type) TYPE="$2"; shift 2 ;;
    --officer) OFFICER="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    *) QUERY="$1"; shift ;;
  esac
done

if [ -z "$QUERY" ]; then
  echo "Usage: search-memory.sh \"<query>\" [--type TYPE] [--officer OFFICER] [--limit N]"
  echo "Types: telegram_dm, telegram_group, officer_trigger, reflection, correction, captain_decision, product_spec, tech_radar, working_note, skill, role_definition, session_memory, golden_eval, experience_record, research_brief, framework_file"
  exit 1
fi

source /opt/founders-cabinet/cabinet/scripts/lib/memory.sh

RESULTS=$(memory_search "$QUERY" "$TYPE" "$OFFICER" "$LIMIT")

if [ -z "$(echo "$RESULTS" | tr -d '[:space:]')" ]; then
  echo "No results found."
  exit 0
fi

echo "=== Cabinet Memory Search: '$QUERY' ==="
[ -n "$TYPE" ] && echo "Type: $TYPE"
[ -n "$OFFICER" ] && echo "Officer: $OFFICER"
echo ""

echo "$RESULTS" | while IFS=$'\t' read -r source_type who when_at similarity preview ref; do
  [ -z "$source_type" ] && continue
  printf "[%s] %s by %s @ %s (sim: %s)\n" "$source_type" "$ref" "$who" "$when_at" "$similarity"
  echo "  $preview"
  echo ""
done
