#!/bin/bash
# backfill-library-created-at.sh — One-shot fix for library_records.created_at
#
# Corrects all records whose created_at is the import date (2026-04-16) by
# fetching the original creation date from Linear (for Issues Space records)
# and Notion (for all other records that have a notion_page_id).
#
# Safety:
# - Direct SQL UPDATE — does NOT call library_update_record (which would version-bump).
# - Idempotent: if source date matches existing, skips UPDATE (no-op via WHERE clause).
# - If source API returns null/empty for a record, leaves that record's created_at alone.
# - On per-record API failure: logs the failure and continues.
#
# Usage:
#   bash cabinet/scripts/backfill-library-created-at.sh
#
# Rate limits:
#   Linear:  batches 100 issues per GraphQL request (well under 1500 req/hr)
#   Notion:  300ms sleep per API call (≤3 req/sec)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a
source "${SCRIPT_DIR}/../.env" 2>/dev/null || true
set +a

LINEAR_URL="https://api.linear.app/graphql"
NOTION_VERSION="2022-06-28"
START_TIME=$(date +%s)

fail_linear=0
fail_notion=0
updated_linear=0
updated_notion=0
skipped=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1"; }

# ── Preflight ────────────────────────────────────────────────────────────────
for var in NEON_CONNECTION_STRING LINEAR_API_KEY NOTION_API_KEY; do
  if [ -z "${!var:-}" ]; then
    echo "ERROR: $var not set. Check cabinet/.env" >&2
    exit 1
  fi
done

# ── Fetch Issues Space id ─────────────────────────────────────────────────────
ISSUES_SPACE_ID=$(psql "$NEON_CONNECTION_STRING" -q -t -A 2>/dev/null <<'SQL'
SELECT id FROM library_spaces WHERE name = 'Issues' LIMIT 1;
SQL
)
if [ -z "$ISSUES_SPACE_ID" ]; then
  echo "ERROR: 'Issues' Space not found in library_spaces." >&2
  exit 1
fi
log "Issues Space id: $ISSUES_SPACE_ID"

# ═══════════════════════════════════════════════════════════════════════
# PART 1 — Linear (Issues Space)
# ═══════════════════════════════════════════════════════════════════════
log "Fetching Linear records from library..."

# Get all active records in the Issues Space that have a linear_id
LINEAR_RECORDS=$(psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' 2>/dev/null <<SQL
SELECT id, schema_data->>'linear_id'
FROM library_records
WHERE space_id = ${ISSUES_SPACE_ID}::bigint
  AND superseded_by IS NULL
  AND schema_data->>'linear_id' IS NOT NULL
  AND schema_data->>'linear_id' != '';
SQL
)

if [ -z "$LINEAR_RECORDS" ]; then
  log "No Linear records found — skipping Linear phase."
else
  # Build lookup map: identifier → library record id
  declare -A linear_id_to_record_id=()
  TOTAL_LINEAR=0

  while IFS=$'\t' read -r rec_id lin_id; do
    [ -z "$rec_id" ] && continue
    linear_id_to_record_id["$lin_id"]="$rec_id"
    TOTAL_LINEAR=$((TOTAL_LINEAR + 1))
  done <<< "$LINEAR_RECORDS"

  log "Found $TOTAL_LINEAR Linear issues to backfill."

  # Paginate through ALL issues in the team (same query shape as import script)
  # Each page returns 100 issues with createdAt — we match by identifier
  TEAM_ID="1f9f4fae-4283-407d-bde1-c5fd56483b76"
  PAGE_SIZE=100
  cursor=""
  has_next=true
  page_num=0

  while [ "$has_next" = "true" ]; do
    page_num=$((page_num + 1))
    after_clause=""
    [ -n "$cursor" ] && after_clause=", after: \"$cursor\""

    query=$(cat <<GRAPHQL
{
  team(id: "$TEAM_ID") {
    issues(first: $PAGE_SIZE $after_clause orderBy: updatedAt) {
      nodes { identifier createdAt }
      pageInfo { hasNextPage endCursor }
    }
  }
}
GRAPHQL
)

    resp=$(curl -s --max-time 30 -X POST "$LINEAR_URL" \
      -H "Authorization: $LINEAR_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg q "$query" '{query: $q}')" 2>/dev/null)

    if printf '%s' "$resp" | jq -e '.errors' >/dev/null 2>&1; then
      log "ERROR: Linear API error on page $page_num — aborting Linear phase"
      printf '%s' "$resp" | jq '.errors' >&2
      fail_linear=$((fail_linear + TOTAL_LINEAR - updated_linear - skipped))
      break
    fi

    has_next=$(printf '%s' "$resp" | jq -r '.data.team.issues.pageInfo.hasNextPage // "false"')
    cursor=$(printf '%s' "$resp" | jq -r '.data.team.issues.pageInfo.endCursor // ""')

    while IFS=$'\t' read -r lin_id created_at; do
      [ -z "$lin_id" ] || [ -z "$created_at" ] || [ "$created_at" = "null" ] && continue
      rec_id="${linear_id_to_record_id[$lin_id]:-}"
      [ -z "$rec_id" ] && continue  # issue exists in Linear but not in our library — skip

      updated=$(psql "$NEON_CONNECTION_STRING" -q -t -A \
        -v rec_id="$rec_id" \
        -v created_at="$created_at" \
        2>/dev/null <<'SQL'
UPDATE library_records
SET created_at = :'created_at'::timestamptz
WHERE id = :'rec_id'::bigint
  AND created_at::date != :'created_at'::timestamptz::date
RETURNING id;
SQL
)
      if [ -n "$updated" ]; then
        updated_linear=$((updated_linear + 1))
        printf '\r  Linear: %d/%d updated, %d skipped...' "$updated_linear" "$TOTAL_LINEAR" "$skipped"
      else
        skipped=$((skipped + 1))
        printf '\r  Linear: %d/%d updated, %d skipped...' "$updated_linear" "$TOTAL_LINEAR" "$skipped"
      fi
    done < <(printf '%s' "$resp" | jq -r '.data.team.issues.nodes[] | [.identifier, .createdAt] | @tsv' 2>/dev/null)

    # Courtesy pause between pages
    [ "$has_next" = "true" ] && sleep 0.2
  done
  printf '\n'
  log "Linear phase done. Updated: $updated_linear  Skipped (already correct): $skipped  Failures: $fail_linear"
fi

# ═══════════════════════════════════════════════════════════════════════
# PART 2 — Notion (all other Spaces with notion_page_id)
# ═══════════════════════════════════════════════════════════════════════
log "Fetching Notion records from library..."

NOTION_RECORDS=$(psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' 2>/dev/null <<SQL
SELECT id, schema_data->>'notion_page_id'
FROM library_records
WHERE superseded_by IS NULL
  AND schema_data->>'notion_page_id' IS NOT NULL
  AND schema_data->>'notion_page_id' != ''
  AND (space_id != ${ISSUES_SPACE_ID}::bigint OR schema_data->>'linear_id' IS NULL);
SQL
)

if [ -z "$NOTION_RECORDS" ]; then
  log "No Notion records found — skipping Notion phase."
else
  TOTAL_NOTION=0
  while IFS=$'\t' read -r _ _; do
    TOTAL_NOTION=$((TOTAL_NOTION + 1))
  done <<< "$NOTION_RECORDS"
  log "Found $TOTAL_NOTION Notion pages to backfill."

  notion_done=0
  while IFS=$'\t' read -r rec_id notion_page_id; do
    [ -z "$rec_id" ] || [ -z "$notion_page_id" ] && continue

    notion_done=$((notion_done + 1))
    printf '\r  Notion: %d/%d...' "$notion_done" "$TOTAL_NOTION"

    # Fetch page metadata from Notion (created_time is top-level, cheap call)
    page_resp=$(curl -s --max-time 15 \
      "https://api.notion.com/v1/pages/${notion_page_id}" \
      -H "Authorization: Bearer $NOTION_API_KEY" \
      -H "Notion-Version: $NOTION_VERSION" \
      -H "Content-Type: application/json" 2>/dev/null)

    created_at=$(printf '%s' "$page_resp" | jq -r '.created_time // ""' 2>/dev/null)

    if [ -z "$created_at" ] || [ "$created_at" = "null" ]; then
      log "  WARN: No created_time for page $notion_page_id (rec $rec_id) — skipping"
      fail_notion=$((fail_notion + 1))
      sleep 0.3
      continue
    fi

    updated=$(psql "$NEON_CONNECTION_STRING" -q -t -A \
      -v rec_id="$rec_id" \
      -v created_at="$created_at" \
      2>/dev/null <<'SQL'
UPDATE library_records
SET created_at = :'created_at'::timestamptz
WHERE id = :'rec_id'::bigint
  AND created_at::date != :'created_at'::timestamptz::date
RETURNING id;
SQL
)
    if [ -n "$updated" ]; then
      updated_notion=$((updated_notion + 1))
    else
      skipped=$((skipped + 1))
    fi

    # Notion rate limit: 3 req/sec → 300ms sleep
    sleep 0.3

  done <<< "$NOTION_RECORDS"
  printf '\n'
  log "Notion phase done. Updated: $updated_notion  Skipped (already correct): $skipped  Failures: $fail_notion"
fi

# ── Final report ──────────────────────────────────────────────────────────────
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "═══════════════════════════════════════════════════════"
echo "Backfill complete in ${ELAPSED}s"
echo "  Linear updated : $updated_linear"
echo "  Notion updated : $updated_notion"
echo "  Already correct: $skipped"
echo "  Linear failures: $fail_linear"
echo "  Notion failures: $fail_notion"
echo "  Total updated  : $((updated_linear + updated_notion))"
echo "═══════════════════════════════════════════════════════"

# ── Verification query ────────────────────────────────────────────────────────
echo ""
echo "Min/Max created_at per Space:"
psql "$NEON_CONNECTION_STRING" -q 2>/dev/null <<'SQL'
SELECT
  s.name AS space,
  COUNT(r.id) AS records,
  MIN(r.created_at)::date AS earliest,
  MAX(r.created_at)::date AS latest
FROM library_records r
JOIN library_spaces s ON s.id = r.space_id
WHERE r.superseded_by IS NULL
GROUP BY s.name
ORDER BY s.name;
SQL

exit 0
