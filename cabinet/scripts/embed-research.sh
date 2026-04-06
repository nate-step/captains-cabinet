#!/bin/bash
set -euo pipefail
FILE_PATH="${1:-}"
TAGS=""
DECAY="fast-moving"
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tags) TAGS="$2"; shift 2 ;;
    --decay) DECAY="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done
[[ -z "$FILE_PATH" || ! -f "$FILE_PATH" ]] && { echo "Usage: bash embed-research.sh <file-path> [--tags \"tag1,tag2\"] [--decay evergreen|fast-moving|time-sensitive]"; exit 1; }
CONTENT=$(cat "$FILE_PATH")
FILENAME=$(basename "$FILE_PATH" .md)
TITLE=$(echo "$CONTENT" | grep -m1 '^# ' | sed 's/^# //' || echo "$FILENAME")
SUMMARY=$(echo "$CONTENT" | sed -n '/^# /,/^$/p' | tail -n +2 | head -5 | tr '\n' ' ')
[[ -z "$SUMMARY" ]] && SUMMARY=$(echo "$CONTENT" | head -3 | tr '\n' ' ')
TOPIC=$(echo "$FILENAME" | sed 's/-/ /g;s/[0-9]*//g;s/^[[:space:]]*//')
[[ -z "$TOPIC" ]] && TOPIC="general"
[[ -z "${VOYAGE_API_KEY:-}" ]] && { echo "Error: VOYAGE_API_KEY not set"; exit 1; }
EMBED_TEXT=$(echo "$CONTENT" | head -200 | tr '\n' ' ' | cut -c1-8000)
EMBEDDING=$(curl -s https://api.voyageai.com/v1/embeddings -H "Authorization: Bearer $VOYAGE_API_KEY" -H "Content-Type: application/json" -d "$(jq -n --arg text "$EMBED_TEXT" --arg model "voyage-4-large" '{input: [$text], model: $model}')" | jq -r '.data[0].embedding | @json')
[[ "$EMBEDDING" == "null" || -z "$EMBEDDING" ]] && { echo "Error: Failed to get embedding"; exit 1; }
PG_TAGS="{}"
[[ -n "$TAGS" ]] && PG_TAGS="{$(echo "$TAGS" | sed 's/,/","/g;s/^/"/;s/$/"/')}"
DB_URL="${NEON_DATABASE_URL:-${DATABASE_URL:-}}"
[[ -z "$DB_URL" ]] && { echo "Error: DATABASE_URL not set"; exit 1; }
ESCAPED_CONTENT=$(echo "$CONTENT" | sed "s/'/''/g")
ESCAPED_TITLE=$(echo "$TITLE" | sed "s/'/''/g")
ESCAPED_SUMMARY=$(echo "$SUMMARY" | sed "s/'/''/g")
ESCAPED_TOPIC=$(echo "$TOPIC" | sed "s/'/''/g")
RESULT=$(psql "$DB_URL" -t -A -c "INSERT INTO cabinet_research (title, topic, content, summary, embedding, tags, officer, decay_rate) VALUES ('${ESCAPED_TITLE}', '${ESCAPED_TOPIC}', '${ESCAPED_CONTENT}', '${ESCAPED_SUMMARY}', '${EMBEDDING}'::vector, '${PG_TAGS}'::text[], '${OFFICER_NAME:-cro}', '${DECAY}') RETURNING id;")
echo "Embedded: $TITLE (id: $RESULT)"
