#!/bin/bash
# memory.sh — Shared Cabinet Memory library (universal semantic search)
# Usage: source this file, then call memory_embed / memory_search / memory_queue_embed

if [ -z "${NEON_CONNECTION_STRING:-}" ]; then
  set -a
  source /opt/founders-cabinet/cabinet/.env 2>/dev/null || true
  set +a
fi

MEM_REDIS_HOST="${REDIS_HOST:-redis}"
MEM_REDIS_PORT="${REDIS_PORT:-6379}"
MEM_QUEUE_KEY="cabinet:memory:embed_queue"

# =============================================================
# CORE: generate embedding via Voyage API (returns JSON array)
# =============================================================
memory_get_embedding() {
  local text="$1"
  [ -z "$VOYAGE_API_KEY" ] && return 1
  # voyage-4-large accepts up to 32K tokens (~128K chars). Cut to 32000 chars
  # keeps well under the limit with headroom for over-tokenization.
  text=$(echo "$text" | tr '\n' ' ' | cut -c1-32000)
  curl -s --max-time 30 https://api.voyageai.com/v1/embeddings \
    -H "Authorization: Bearer $VOYAGE_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg text "$text" '{input: [$text], model: "voyage-4-large"}')" \
    | jq -r '.data[0].embedding | @json'
}

# =============================================================
# SYNC INSERT: embed + insert immediately (for backfill)
# Args: source_type, source_id (can be empty), officer, sender, content, metadata_json, source_created_at
# =============================================================
memory_embed() {
  local source_type="$1"
  local source_id="${2:-}"
  local officer="${3:-}"
  local sender="${4:-}"
  local content="$5"
  local metadata="${6:-{\}}"
  local source_ts="${7:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

  # Refuse empty/whitespace-only content — Voyage happily embeds " " to a valid vector,
  # so this check must happen before embedding (not after)
  if [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ]; then
    return 1
  fi

  # Validate metadata is JSON; fall back to {} if not
  if ! printf '%s' "$metadata" | jq -e . >/dev/null 2>&1; then
    metadata='{}'
  fi

  local embedding
  embedding=$(memory_get_embedding "$content")
  [ -z "$embedding" ] || [ "$embedding" = "null" ] && return 1

  psql "$NEON_CONNECTION_STRING" -q \
    -v source_type="$source_type" \
    -v source_id="${source_id:-}" \
    -v officer="${officer:-}" \
    -v sender="${sender:-}" \
    -v content="$content" \
    -v embedding="$embedding" \
    -v metadata="$metadata" \
    -v source_ts="$source_ts" \
    2>/dev/null <<'SQLEOF'
INSERT INTO cabinet_memory (source_type, source_id, officer, sender, content, embedding, metadata, source_created_at)
VALUES (
  NULLIF(:'source_type', ''),
  NULLIF(:'source_id', ''),
  NULLIF(:'officer', ''),
  NULLIF(:'sender', ''),
  :'content',
  :'embedding'::vector,
  :'metadata'::jsonb,
  :'source_ts'::timestamptz
)
ON CONFLICT (source_type, source_id) WHERE source_id IS NOT NULL AND superseded_by IS NULL
DO UPDATE SET
  content = EXCLUDED.content,
  embedding = EXCLUDED.embedding,
  metadata = EXCLUDED.metadata,
  source_created_at = EXCLUDED.source_created_at,
  version = cabinet_memory.version + 1
RETURNING id;
SQLEOF
}

# =============================================================
# ASYNC QUEUE: push to Redis, worker processes
# Args: same as memory_embed. Returns immediately.
# =============================================================
memory_queue_embed() {
  local source_type="$1"
  local source_id="${2:-}"
  local officer="${3:-}"
  local sender="${4:-}"
  local content="$5"
  local metadata="${6:-{\}}"
  local source_ts="${7:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

  # Skip empty/whitespace-only content — prevents worker from embedding " "
  if [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ]; then
    return 1
  fi

  # Validate metadata JSON; fall back to {} if invalid (prevents silent payload drop)
  if ! printf '%s' "$metadata" | jq -e . >/dev/null 2>&1; then
    metadata='{}'
  fi

  # Build payload as compact JSON (one line — required for XADD single-value parsing)
  local payload
  payload=$(jq -nc \
    --arg source_type "$source_type" \
    --arg source_id "$source_id" \
    --arg officer "$officer" \
    --arg sender "$sender" \
    --arg content "$content" \
    --argjson metadata "$metadata" \
    --arg source_ts "$source_ts" \
    '{source_type: $source_type, source_id: $source_id, officer: $officer, sender: $sender, content: $content, metadata: $metadata, source_ts: $source_ts}')

  [ -z "$payload" ] && return 1

  redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XADD "$MEM_QUEUE_KEY" '*' payload "$payload" > /dev/null 2>&1
}

# =============================================================
# SEARCH: semantic query
# Args: query, source_type (optional), officer (optional), limit (default 10)
# =============================================================
memory_search() {
  local query="$1"
  local source_type_filter="${2:-}"
  local officer_filter="${3:-}"
  local limit="${4:-10}"

  local query_embedding
  query_embedding=$(memory_get_embedding "$query")
  [ -z "$query_embedding" ] || [ "$query_embedding" = "null" ] && { echo "Embedding failed"; return 1; }

  # Use tab separator (safer than | — content may contain |)
  # Strip any tabs/newlines from preview so one row = one line, cleanly parseable
  # Filters passed via psql -v (parameterized, injection-safe)
  psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' \
    -v embedding="$query_embedding" \
    -v limit="$limit" \
    -v st_filter="${source_type_filter:-}" \
    -v of_filter="${officer_filter:-}" \
    2>/dev/null <<'SQLEOF'
SELECT
  source_type,
  COALESCE(officer, sender, 'n/a') as who,
  to_char(source_created_at, 'YYYY-MM-DD HH24:MI') as when_at,
  round((1 - (embedding <=> :'embedding'::vector))::numeric, 3) as similarity,
  regexp_replace(LEFT(COALESCE(summary, content), 200), E'[\t\n\r]+', ' ', 'g') as preview,
  COALESCE(source_id, id::text) as ref
FROM cabinet_memory
WHERE superseded_by IS NULL
  AND (:'st_filter' = '' OR source_type = :'st_filter')
  AND (:'of_filter' = '' OR officer = :'of_filter')
ORDER BY embedding <=> :'embedding'::vector
LIMIT :'limit';
SQLEOF
}
