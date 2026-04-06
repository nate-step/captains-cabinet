#!/bin/bash
# search-research.sh — Semantic search of Cabinet research briefs
# Usage: bash search-research.sh "query text"
set -euo pipefail

QUERY="${1:-}"
[[ -z "$QUERY" ]] && { echo "Usage: bash search-research.sh \"your query\""; exit 1; }
[[ -z "${VOYAGE_API_KEY:-}" ]] && { echo "Error: VOYAGE_API_KEY not set"; exit 1; }

# Embed the query
EMBEDDING=$(curl -s https://api.voyageai.com/v1/embeddings \
  -H "Authorization: Bearer $VOYAGE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg text "$QUERY" --arg model "voyage-4-large" '{input: [$text], model: $model}')" \
  | jq -r '.data[0].embedding | @json')

[[ "$EMBEDDING" == "null" || -z "$EMBEDDING" ]] && { echo "Error: Failed to embed query"; exit 1; }

DB_URL="${NEON_DATABASE_URL:-${DATABASE_URL:-}}"
[[ -z "$DB_URL" ]] && { echo "Error: DATABASE_URL not set"; exit 1; }

# Cosine similarity search — top 5
psql "$DB_URL" -t -A --pset="format=aligned" -c "
  SELECT
    title,
    round((1 - (embedding <=> '${EMBEDDING}'::vector))::numeric, 3) AS similarity,
    to_char(created_at, 'YYYY-MM-DD') AS date,
    COALESCE(decay_rate, 'fast-moving') AS decay,
    COALESCE(usage_status, 'new') AS status,
    LEFT(summary, 120) AS summary
  FROM cabinet_research
  WHERE embedding IS NOT NULL
    AND COALESCE(usage_status, 'new') != 'superseded'
  ORDER BY embedding <=> '${EMBEDDING}'::vector
  LIMIT 5;
"
