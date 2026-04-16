#!/bin/bash
# library.sh — The Library: user-defined Spaces with structured records
# Usage: source this file, then call library_* functions.
# Complements memory.sh (search layer) — Library is the edit layer.

if [ -z "${NEON_CONNECTION_STRING:-}" ]; then
  set -a
  source /opt/founders-cabinet/cabinet/.env 2>/dev/null || true
  set +a
fi

# Reuse memory.sh's embedding function — same Voyage model, same semantics
if ! declare -f memory_get_embedding > /dev/null; then
  source /opt/founders-cabinet/cabinet/scripts/lib/memory.sh 2>/dev/null
fi

# =============================================================
# SPACE CRUD
# =============================================================

# Create a Space (or update if name already exists — Spaces are configuration,
# not content; name collision means the user is refining the schema).
# Args: name, description, schema_json, starter_template, owner, access_rules_json
library_create_space() {
  local name="$1"
  local description="${2:-}"
  local schema_json="${3:-{\}}"
  local starter_template="${4:-blank}"
  local owner="${5:-${OFFICER_NAME:-system}}"
  local access_rules="${6:-{\}}"

  if [ -z "$name" ]; then
    return 1
  fi

  # Validate JSON inputs; fall back to {} on invalid
  if ! printf '%s' "$schema_json" | jq -e . >/dev/null 2>&1; then
    schema_json='{}'
  fi
  if ! printf '%s' "$access_rules" | jq -e . >/dev/null 2>&1; then
    access_rules='{}'
  fi

  psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v name="$name" \
    -v description="$description" \
    -v schema_json="$schema_json" \
    -v starter_template="$starter_template" \
    -v owner="$owner" \
    -v access_rules="$access_rules" \
    2>/dev/null <<'SQLEOF'
INSERT INTO library_spaces (name, description, schema_json, starter_template, owner, access_rules)
VALUES (
  :'name',
  NULLIF(:'description', ''),
  :'schema_json'::jsonb,
  NULLIF(:'starter_template', ''),
  NULLIF(:'owner', ''),
  :'access_rules'::jsonb
)
ON CONFLICT (name) DO UPDATE SET
  description = EXCLUDED.description,
  schema_json = EXCLUDED.schema_json,
  access_rules = EXCLUDED.access_rules
RETURNING id;
SQLEOF
}

# List all Spaces (id, name, description, starter_template, owner)
library_list_spaces() {
  psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' 2>/dev/null <<'SQLEOF'
SELECT id, name, COALESCE(description, ''), COALESCE(starter_template, ''), COALESCE(owner, ''), to_char(created_at, 'YYYY-MM-DD HH24:MI')
FROM library_spaces
ORDER BY created_at DESC;
SQLEOF
}

# Resolve a Space name to its id (or empty string if not found)
library_space_id() {
  local name="$1"
  psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v name="$name" \
    2>/dev/null <<'SQLEOF'
SELECT id FROM library_spaces WHERE name = :'name';
SQLEOF
}

# =============================================================
# RECORD CRUD
# =============================================================

# Create a record in a Space.
# Args: space_id, title, content_markdown, schema_data_json, labels_comma_separated,
#       [officer], [source_created_at]
# source_created_at (arg 8, positional — args 6+7 are officer placeholder and reserved):
#   Pass an ISO 8601 timestamp (e.g. "2025-01-15T10:30:00.000Z") to override the
#   created_at column with the original source date (Linear createdAt, Notion created_time).
#   If omitted or empty, Postgres DEFAULT (NOW()) is used.
# Returns: new record id
library_create_record() {
  local space_id="$1"
  local title="$2"
  local content="${3:-}"
  local schema_data="${4:-{\}}"
  local labels_csv="${5:-}"
  local officer="${OFFICER_NAME:-system}"
  local source_created_at="${8:-}"  # arg 8; args 6+7 reserved for future use

  if [ -z "$space_id" ] || [ -z "$title" ]; then
    return 1
  fi

  # Validate schema_data JSON
  if ! printf '%s' "$schema_data" | jq -e . >/dev/null 2>&1; then
    schema_data='{}'
  fi

  # Convert CSV labels to Postgres array literal {a,b,c}
  local labels_pg="{}"
  if [ -n "$labels_csv" ]; then
    labels_pg="{$labels_csv}"
  fi

  # Compute embedding from title + content + schema_data summary
  local embed_text="$title"
  [ -n "$content" ] && embed_text="$embed_text"$'\n\n'"$content"
  local schema_preview
  schema_preview=$(printf '%s' "$schema_data" | jq -r '[to_entries[] | "\(.key): \(.value | tostring)"] | join(", ")' 2>/dev/null)
  [ -n "$schema_preview" ] && [ "$schema_preview" != "" ] && embed_text="$embed_text"$'\n\n'"$schema_preview"

  # Refuse whitespace-only content (matches memory.sh pattern)
  if [ -z "$(printf '%s' "$embed_text" | tr -d '[:space:]')" ]; then
    return 1
  fi

  local embedding
  embedding=$(memory_get_embedding "$embed_text")
  if [ -z "$embedding" ] || [ "$embedding" = "null" ]; then
    return 1
  fi

  psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v space_id="$space_id" \
    -v title="$title" \
    -v content="$content" \
    -v schema_data="$schema_data" \
    -v labels="$labels_pg" \
    -v embedding="$embedding" \
    -v officer="$officer" \
    -v source_created_at="$source_created_at" \
    2>/dev/null <<'SQLEOF'
INSERT INTO library_records (space_id, title, content_markdown, schema_data, labels, embedding, created_by_officer, created_at)
VALUES (
  :'space_id'::bigint,
  :'title',
  :'content',
  :'schema_data'::jsonb,
  :'labels'::text[],
  :'embedding'::vector,
  NULLIF(:'officer', ''),
  COALESCE(NULLIF(:'source_created_at', '')::timestamptz, NOW())
)
RETURNING id;
SQLEOF
}

# Update a record — preserves history via superseded_by + version++.
# The old row stays in place but gets its superseded_by pointer set;
# a new row is inserted with the new content and version+1.
# Args: record_id, title, content_markdown, schema_data_json, labels_csv
# Returns: new record id
library_update_record() {
  local record_id="$1"
  local title="$2"
  local content="${3:-}"
  local schema_data="${4:-{\}}"
  local labels_csv="${5:-}"
  local officer="${OFFICER_NAME:-system}"

  if [ -z "$record_id" ] || [ -z "$title" ]; then
    return 1
  fi

  if ! printf '%s' "$schema_data" | jq -e . >/dev/null 2>&1; then
    schema_data='{}'
  fi

  local labels_pg="{}"
  if [ -n "$labels_csv" ]; then
    labels_pg="{$labels_csv}"
  fi

  # Embed the new version (do this before opening the transaction so we don't
  # hold a row lock across a network call to Voyage)
  local embed_text="$title"
  [ -n "$content" ] && embed_text="$embed_text"$'\n\n'"$content"

  if [ -z "$(printf '%s' "$embed_text" | tr -d '[:space:]')" ]; then
    return 1
  fi

  local embedding
  embedding=$(memory_get_embedding "$embed_text")
  if [ -z "$embedding" ] || [ "$embedding" = "null" ]; then
    return 1
  fi

  # Do version lookup + INSERT + UPDATE atomically. FOR UPDATE locks the old row
  # so concurrent updates serialize — the second caller waits for the first,
  # then finds superseded_by IS NOT NULL and aborts. Prevents phantom "v2" rows.
  psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v old_id="$record_id" \
    -v title="$title" \
    -v content="$content" \
    -v schema_data="$schema_data" \
    -v labels="$labels_pg" \
    -v embedding="$embedding" \
    -v officer="$officer" \
    2>/dev/null <<'SQLEOF'
BEGIN;
WITH locked AS (
  SELECT id, space_id, version
  FROM library_records
  WHERE id = :'old_id'::bigint AND superseded_by IS NULL
  FOR UPDATE
),
inserted AS (
  INSERT INTO library_records (space_id, title, content_markdown, schema_data, labels, embedding, created_by_officer, version)
  SELECT
    locked.space_id,
    :'title',
    :'content',
    :'schema_data'::jsonb,
    :'labels'::text[],
    :'embedding'::vector,
    NULLIF(:'officer', ''),
    locked.version + 1
  FROM locked
  RETURNING id
),
updated AS (
  UPDATE library_records
  SET superseded_by = (SELECT id FROM inserted)
  WHERE id = (SELECT id FROM locked)
  RETURNING id
)
SELECT id FROM inserted;
COMMIT;
SQLEOF
}

# Get a record by id. If version is specified, returns that specific historical
# version (only possible if version is the current active one OR by traversing
# superseded chain). Default: current active record.
# Args: record_id
library_get_record() {
  local record_id="$1"
  psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' \
    -v record_id="$record_id" \
    2>/dev/null <<'SQLEOF'
SELECT id, space_id, title, content_markdown, schema_data::text, array_to_string(labels, ','),
       version, COALESCE(superseded_by::text, ''), COALESCE(created_by_officer, ''),
       to_char(created_at, 'YYYY-MM-DD HH24:MI'), to_char(updated_at, 'YYYY-MM-DD HH24:MI')
FROM library_records
WHERE id = :'record_id'::bigint;
SQLEOF
}

# Walk version history of a record — return all versions including superseded
# Args: any record id in the chain
library_record_history() {
  local record_id="$1"
  psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' \
    -v record_id="$record_id" \
    2>/dev/null <<'SQLEOF'
-- Two-step walk: find HEAD (walk forward through superseded_by pointers),
-- then walk backward from HEAD through the chain of older versions.
-- Each row is visited once per walk so recursion terminates cleanly.
WITH RECURSIVE
  forward AS (
    SELECT id, superseded_by
    FROM library_records
    WHERE id = :'record_id'::bigint
    UNION ALL
    SELECT r.id, r.superseded_by
    FROM library_records r
    JOIN forward f ON f.superseded_by = r.id
    WHERE r.superseded_by IS NULL OR r.id != r.superseded_by  -- stop at soft-deletes (self-pointers)
  ),
  head AS (
    -- Only the terminal row in the forward walk qualifies — exactly one match expected
    SELECT id FROM forward WHERE superseded_by IS NULL OR superseded_by = id
  ),
  chain AS (
    SELECT id, version, title, superseded_by, created_at
    FROM library_records
    WHERE id = (SELECT id FROM head)
    UNION ALL
    SELECT r.id, r.version, r.title, r.superseded_by, r.created_at
    FROM library_records r
    JOIN chain c ON r.superseded_by = c.id AND r.id != c.id
  )
SELECT id, version, title,
       COALESCE(CASE WHEN superseded_by = id THEN 'DELETED' ELSE superseded_by::text END, 'HEAD'),
       to_char(created_at, 'YYYY-MM-DD HH24:MI')
FROM chain
ORDER BY version DESC;
SQLEOF
}

# Search records by semantic similarity.
# Args: query, space_id (optional, empty for cross-Space), labels_csv (optional), limit (default 10)
# Returns tab-separated: space_id, record_id, title, similarity, preview, officer, created_at
library_search() {
  local query="$1"
  local space_id_filter="${2:-}"
  local labels_filter="${3:-}"
  local limit="${4:-10}"

  local query_embedding
  query_embedding=$(memory_get_embedding "$query")
  [ -z "$query_embedding" ] || [ "$query_embedding" = "null" ] && { return 1; }

  local labels_pg="{}"
  [ -n "$labels_filter" ] && labels_pg="{$labels_filter}"

  psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' \
    -v embedding="$query_embedding" \
    -v limit="$limit" \
    -v space_filter="${space_id_filter:-}" \
    -v labels_filter="$labels_pg" \
    2>/dev/null <<'SQLEOF'
SELECT space_id, id, title,
       round((1 - (embedding <=> :'embedding'::vector))::numeric, 3) as similarity,
       regexp_replace(LEFT(content_markdown, 200), E'[\t\n\r]+', ' ', 'g') as preview,
       COALESCE(created_by_officer, ''),
       to_char(created_at, 'YYYY-MM-DD HH24:MI')
FROM library_records
WHERE superseded_by IS NULL
  AND (:'space_filter' = '' OR space_id = NULLIF(:'space_filter', '')::bigint)
  AND (:'labels_filter' = '{}' OR labels && :'labels_filter'::text[])
ORDER BY embedding <=> :'embedding'::vector
LIMIT :'limit';
SQLEOF
}

# List records in a Space (active only), ordered by created_at DESC.
# Args: space_id, limit (default 50)
library_list_records() {
  local space_id="$1"
  local limit="${2:-50}"

  psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' \
    -v space_id="$space_id" \
    -v limit="$limit" \
    2>/dev/null <<'SQLEOF'
SELECT id, title, array_to_string(labels, ','),
       regexp_replace(LEFT(content_markdown, 100), E'[\t\n\r]+', ' ', 'g') as preview,
       version, COALESCE(created_by_officer, ''),
       to_char(created_at, 'YYYY-MM-DD HH24:MI')
FROM library_records
WHERE space_id = :'space_id'::bigint AND superseded_by IS NULL
ORDER BY created_at DESC
LIMIT :'limit';
SQLEOF
}

# Soft-delete a record by marking it superseded_by itself.
# Trick: use a sentinel that lets us distinguish deleted from live without extra schema.
# Convention: if superseded_by = id (self-reference), record is deleted.
# Args: record_id
library_delete_record() {
  local record_id="$1"
  psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v record_id="$record_id" \
    2>/dev/null <<'SQLEOF'
UPDATE library_records
SET superseded_by = id
WHERE id = :'record_id'::bigint AND superseded_by IS NULL
RETURNING id;
SQLEOF
}
