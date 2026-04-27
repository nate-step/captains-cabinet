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
# ACCESS CONTROL
# =============================================================

# Fetch access_rules for a space from the DB.
# Args: space_id
# Returns: the access_rules JSONB as a JSON string, or "{}" on failure.
_library_get_access_rules() {
  local space_id="$1"
  psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v space_id="$space_id" \
    2>/dev/null <<'SQLEOF'
SELECT COALESCE(access_rules::text, '{}') FROM library_spaces WHERE id = :'space_id'::bigint;
SQLEOF
}

# Check whether `officer` is allowed to perform `op_type` (read|write|comment)
# on the given space.
# Returns 0 if allowed, 1 if denied.
# Args: space_id, officer, op_type
library_check_access() {
  local space_id="$1"
  local officer="${2:-${OFFICER_NAME:-}}"
  local op_type="$3"

  # Captain always has full access
  if [ "$officer" = "captain" ]; then
    return 0
  fi

  local rules
  rules=$(_library_get_access_rules "$space_id")
  # Empty rules or missing space — deny (space must exist)
  if [ -z "$rules" ]; then
    echo "library: access denied — space $space_id not found" >&2
    return 1
  fi

  # access_rules={} means "no rules configured" — treat as fully permissive.
  # This preserves backward compatibility for spaces created before enforcement landed.
  # An explicit empty list (e.g. "write": []) means "nobody can write".
  local rule_count
  rule_count=$(printf '%s' "$rules" | jq 'length' 2>/dev/null)
  if [ "${rule_count:-0}" = "0" ]; then
    return 0
  fi

  # Extract the list for this op_type; if key missing, deny
  local allowed
  allowed=$(printf '%s' "$rules" | jq -r --arg op "$op_type" '.[$op] // empty | .[]' 2>/dev/null)

  # If the key is missing entirely, deny
  if [ -z "$allowed" ] && ! printf '%s' "$rules" | jq -e --arg op "$op_type" 'has($op)' >/dev/null 2>&1; then
    echo "library: access denied — op '$op_type' not defined in access_rules for space $space_id" >&2
    return 1
  fi

  # Check for wildcard or exact match
  while IFS= read -r entry; do
    if [ "$entry" = "*" ] || [ "$entry" = "$officer" ]; then
      return 0
    fi
  done <<< "$allowed"

  echo "library: access denied — officer '$officer' not in '$op_type' list for space $space_id" >&2
  return 1
}

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
#
# Positional args:
#   1. space_id                 (required) — target Space id from library_list_spaces
#   2. title                    (required) — human-readable title (not unique)
#   3. content_markdown         (optional) — body text
#   4. schema_data_json         (optional, default "{}") — per-space custom fields
#   5. labels_csv               (optional) — comma-separated labels, no spaces
#   6. _reserved_officer_arg    (optional) — historical: pass ""; officer is read from
#                                            $OFFICER_NAME env so MCP callers set it per-request
#   7. _reserved_v2             (optional) — pass ""; placeholder for a future per-record
#                                            override flag. Present only to preserve
#                                            arg-8 compatibility for migration scripts
#   8. source_created_at        (optional) — ISO 8601 timestamp to override the created_at
#                                            column with the ORIGINAL source date (Linear
#                                            createdAt, Notion created_time). Omit for
#                                            live records; Postgres NOW() default applies.
#
# Callers that only set 1-5 can omit 6-8 entirely. Callers that need arg 8
# (the migration scripts) must pass "" for positions 6 and 7 to keep the
# positional binding correct — documented here because the gap is otherwise
# invisible in the call site and will confuse future readers.
#
# Returns: new record id on stdout.
library_create_record() {
  local space_id="$1"
  local title="$2"
  local content="${3:-}"
  local schema_data="${4:-{\}}"
  local labels_csv="${5:-}"
  # Positions 6 and 7 are intentionally unbound — see header comment.
  local _reserved_officer_arg="${6:-}"  # ignored; officer comes from env
  local _reserved_v2="${7:-}"           # ignored; placeholder for future use
  local officer="${OFFICER_NAME:-system}"
  local source_created_at="${8:-}"

  if [ -z "$space_id" ] || [ -z "$title" ]; then
    return 1
  fi

  # Access control — write op; captain always allowed; skip if officer unknown
  if [ -n "$officer" ] && [ "$officer" != "system" ]; then
    if ! library_check_access "$space_id" "$officer" "write"; then
      return 1
    fi
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

  # Get embedding — if Voyage fails, warn and proceed with NULL (resilient fallback)
  local embedding
  embedding=$(memory_get_embedding "$embed_text")
  if [ -z "$embedding" ] || [ "$embedding" = "null" ]; then
    echo "library: Voyage embedding unavailable — inserting record with embedding=NULL (ILIKE fallback active)" >&2
    embedding=""
  fi

  local record_id
  record_id=$(psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v space_id="$space_id" \
    -v title="$title" \
    -v content="$content" \
    -v schema_data="$schema_data" \
    -v labels="$labels_pg" \
    -v embedding="${embedding}" \
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
  CASE WHEN :'embedding' = '' THEN NULL ELSE :'embedding'::vector END,
  NULLIF(:'officer', ''),
  COALESCE(NULLIF(:'source_created_at', '')::timestamptz, NOW())
)
RETURNING id;
SQLEOF
)

  echo "$record_id"

  # Queue in cabinet_memory for cross-system search (async, non-blocking)
  if [ -n "$record_id" ] && [ "$record_id" -gt 0 ] 2>/dev/null; then
    local space_name
    space_name=$(psql "$NEON_CONNECTION_STRING" -q -t -A \
      -v space_id="$space_id" \
      2>/dev/null <<'SQLEOF'
SELECT name FROM library_spaces WHERE id = :'space_id'::bigint;
SQLEOF
)
    local cm_content="$title"
    [ -n "$content" ] && cm_content="$cm_content"$'\n\n'"$content"
    local cm_meta
    cm_meta=$(jq -nc --arg sid "$space_id" --arg sname "${space_name:-}" --arg rid "$record_id" \
      '{space_id: $sid, space_name: $sname, record_id: $rid}')
    memory_queue_embed "library_record" "lib-${record_id}" "$officer" "" "$cm_content" "$cm_meta" "${source_created_at:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" 2>/dev/null || true
  fi
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

  # Access control — resolve space_id from record, then check write
  local rec_space_id
  rec_space_id=$(psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v rid="$record_id" \
    2>/dev/null <<'SQLEOF'
SELECT space_id FROM library_records WHERE id = :'rid'::bigint AND superseded_by IS NULL;
SQLEOF
)
  if [ -n "$rec_space_id" ] && [ -n "$officer" ] && [ "$officer" != "system" ]; then
    if ! library_check_access "$rec_space_id" "$officer" "write"; then
      return 1
    fi
  fi

  # Embed the new version (do this before opening the transaction so we don't
  # hold a row lock across a network call to Voyage)
  local embed_text="$title"
  [ -n "$content" ] && embed_text="$embed_text"$'\n\n'"$content"

  if [ -z "$(printf '%s' "$embed_text" | tr -d '[:space:]')" ]; then
    return 1
  fi

  # Get embedding — if Voyage fails, warn and proceed with NULL (resilient fallback)
  local embedding
  embedding=$(memory_get_embedding "$embed_text")
  if [ -z "$embedding" ] || [ "$embedding" = "null" ]; then
    echo "library: Voyage embedding unavailable — updating record with embedding=NULL (ILIKE fallback active)" >&2
    embedding=""
  fi

  # Do version lookup + INSERT + UPDATE atomically. FOR UPDATE locks the old row
  # so concurrent updates serialize — the second caller waits for the first,
  # then finds superseded_by IS NOT NULL and aborts. Prevents phantom "v2" rows.
  local new_record_id
  new_record_id=$(psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v old_id="$record_id" \
    -v title="$title" \
    -v content="$content" \
    -v schema_data="$schema_data" \
    -v labels="$labels_pg" \
    -v embedding="${embedding}" \
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
    CASE WHEN :'embedding' = '' THEN NULL ELSE :'embedding'::vector END,
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
)

  echo "$new_record_id"

  # Queue in cabinet_memory for cross-system search (async, non-blocking)
  if [ -n "$new_record_id" ] && [ "$new_record_id" -gt 0 ] 2>/dev/null; then
    local space_name
    space_name=$(psql "$NEON_CONNECTION_STRING" -q -t -A \
      -v space_id="${rec_space_id}" \
      2>/dev/null <<'SQLEOF'
SELECT name FROM library_spaces WHERE id = :'space_id'::bigint;
SQLEOF
)
    local cm_content="$title"
    [ -n "$content" ] && cm_content="$cm_content"$'\n\n'"$content"
    local cm_meta
    cm_meta=$(jq -nc --arg sid "${rec_space_id:-}" --arg sname "${space_name:-}" --arg rid "$new_record_id" \
      '{space_id: $sid, space_name: $sname, record_id: $rid}')
    memory_queue_embed "library_record" "lib-${new_record_id}" "$officer" "" "$cm_content" "$cm_meta" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
  fi
}

# Get a record by id. If version is specified, returns that specific historical
# version (only possible if version is the current active one OR by traversing
# superseded chain). Default: current active record.
# Args: record_id
library_get_record() {
  local record_id="$1"
  local officer="${OFFICER_NAME:-}"

  # Resolve space_id for access check
  if [ -n "$officer" ] && [ "$officer" != "system" ]; then
    local rec_space_id
    rec_space_id=$(psql "$NEON_CONNECTION_STRING" -q -t -A \
      -v rid="$record_id" \
      2>/dev/null <<'SQLEOF'
SELECT space_id FROM library_records WHERE id = :'rid'::bigint LIMIT 1;
SQLEOF
)
    if [ -n "$rec_space_id" ]; then
      if ! library_check_access "$rec_space_id" "$officer" "read"; then
        return 1
      fi
    fi
  fi

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

# Get the records that link IN to a target record via [[wikilink]] syntax.
# Args: target record_id
# Returns tab-separated: source_record_id, source_title, source_space_id, source_space_name, link_text, link_context, link_position
# Up to 50 rows, ordered by source space name → source title → link position.
library_get_backlinks() {
  local record_id="$1"
  local officer="${OFFICER_NAME:-}"

  # Access check on the target record's space — backlinks reveal what links
  # at the target, so the caller needs read access to the target's space.
  if [ -n "$officer" ] && [ "$officer" != "system" ]; then
    local target_space_id
    target_space_id=$(psql "$NEON_CONNECTION_STRING" -q -t -A \
      -v rid="$record_id" \
      2>/dev/null <<'SQLEOF'
SELECT space_id FROM library_records WHERE id = :'rid'::bigint LIMIT 1;
SQLEOF
)
    if [ -n "$target_space_id" ]; then
      if ! library_check_access "$target_space_id" "$officer" "read"; then
        return 1
      fi
    fi
  fi

  psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' \
    -v target_id="$record_id" \
    2>/dev/null <<'SQLEOF'
SELECT lrl.source_record_id::text,
       r.title,
       r.space_id::text,
       s.name,
       lrl.link_text,
       COALESCE(lrl.link_context, ''),
       lrl.link_position
FROM library_record_links lrl
JOIN library_records r ON r.id = lrl.source_record_id AND r.superseded_by IS NULL
JOIN library_spaces s ON s.id = r.space_id
WHERE lrl.target_record_id = :'target_id'::bigint
ORDER BY s.name, r.title, lrl.link_position
LIMIT 50;
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
  local officer="${OFFICER_NAME:-}"

  # Access check — if a specific space is requested, verify read permission
  if [ -n "$space_id_filter" ] && [ -n "$officer" ] && [ "$officer" != "system" ]; then
    if ! library_check_access "$space_id_filter" "$officer" "read"; then
      return 1
    fi
  fi

  local query_embedding
  query_embedding=$(memory_get_embedding "$query")
  # If embedding fails, fall back to ILIKE title search (matches dashboard behavior)
  if [ -z "$query_embedding" ] || [ "$query_embedding" = "null" ]; then
    echo "library: Voyage embedding unavailable — falling back to ILIKE title search" >&2
    psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' \
      -v query="$query" \
      -v space_filter="${space_id_filter:-}" \
      2>/dev/null <<'SQLEOF'
SELECT space_id, id, title,
       0 as similarity,
       regexp_replace(LEFT(content_markdown, 200), E'[\t\n\r]+', ' ', 'g') as preview,
       COALESCE(created_by_officer, ''),
       to_char(created_at, 'YYYY-MM-DD HH24:MI')
FROM library_records
WHERE superseded_by IS NULL
  AND (:'space_filter' = '' OR space_id = NULLIF(:'space_filter', '')::bigint)
  AND title ILIKE '%' || :'query' || '%'
LIMIT 10;
SQLEOF
    return 0
  fi

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
  local officer="${OFFICER_NAME:-}"

  # Access check
  if [ -n "$officer" ] && [ "$officer" != "system" ]; then
    if ! library_check_access "$space_id" "$officer" "read"; then
      return 1
    fi
  fi

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
  local officer="${OFFICER_NAME:-}"

  # Resolve space_id for access check
  if [ -n "$officer" ] && [ "$officer" != "system" ]; then
    local rec_space_id
    rec_space_id=$(psql "$NEON_CONNECTION_STRING" -q -t -A \
      -v rid="$record_id" \
      2>/dev/null <<'SQLEOF'
SELECT space_id FROM library_records WHERE id = :'rid'::bigint AND superseded_by IS NULL;
SQLEOF
)
    if [ -n "$rec_space_id" ]; then
      if ! library_check_access "$rec_space_id" "$officer" "write"; then
        return 1
      fi
    fi
  fi

  psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v record_id="$record_id" \
    2>/dev/null <<'SQLEOF'
UPDATE library_records
SET superseded_by = id
WHERE id = :'record_id'::bigint AND superseded_by IS NULL
RETURNING id;
SQLEOF
}
