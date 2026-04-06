#!/bin/bash
# supersede-research.sh — Mark a research brief as superseded in pgvector
# Usage: bash supersede-research.sh <old-brief-title-or-id> [new-brief-path]
set -euo pipefail

QUERY="${1:-}"
NEW_BRIEF="${2:-}"

[[ -z "$QUERY" ]] && { echo "Usage: bash supersede-research.sh <title-search-term> [new-brief-path]"; exit 1; }

DB_URL="${NEON_DATABASE_URL:-${DATABASE_URL:-}}"
[[ -z "$DB_URL" ]] && DB_URL="postgresql://cabinet:cabinet@postgres:5432/cabinet"

# Use parameterized query to prevent SQL injection
SEARCH_PATTERN="%${QUERY}%"
RESULT=$(psql "$DB_URL" -t -A \
  -v pattern="$SEARCH_PATTERN" \
  -c "UPDATE cabinet_research
  SET usage_status = 'superseded', updated_at = NOW()
  WHERE LOWER(title) LIKE LOWER(:'pattern')
    AND usage_status != 'superseded'
  RETURNING id, title;")

if [ -z "$RESULT" ]; then
  echo "No matching briefs found for: $QUERY"
else
  echo "Superseded:"
  echo "$RESULT"
fi

# If a new brief path is provided, embed it as the replacement
if [ -n "$NEW_BRIEF" ] && [ -f "$NEW_BRIEF" ]; then
  echo ""
  echo "Embedding replacement brief..."
  bash /opt/founders-cabinet/cabinet/scripts/embed-research.sh "$NEW_BRIEF" --tags "replacement"
fi
