#!/bin/bash
# migrate-notion-to-library.sh — One-shot Notion → Library Space migration
#
# Usage:
#   bash cabinet/scripts/migrate-notion-to-library.sh <space-slug> [--dry-run]
#
# Supported space slugs (MVP):
#   business-brain   — migrates notion.business_brain_db → "Business Brain" Space
#
# Idempotent: re-running updates changed records, skips unchanged, never duplicates.
# Read-only on Notion side. Does not write back to Notion.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CABINET_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$CABINET_DIR/cabinet/.env"
CONFIG_FILE="$CABINET_DIR/config/product.yml"
LIB_FILE="$SCRIPT_DIR/lib/library.sh"

# ---------------------------------------------------------------
# Args
# ---------------------------------------------------------------
SPACE_SLUG="${1:-}"
DRY_RUN=false
for arg in "$@"; do
  [ "$arg" = "--dry-run" ] && DRY_RUN=true
done

if [ -z "$SPACE_SLUG" ]; then
  echo "Usage: migrate-notion-to-library.sh <space-slug> [--dry-run]"
  echo "Supported slugs: business-brain"
  exit 1
fi

# ---------------------------------------------------------------
# Validate slug → Space name + Notion DB id mapping
# ---------------------------------------------------------------
case "$SPACE_SLUG" in
  business-brain)
    SPACE_DISPLAY_NAME="Business Brain"
    # Extract from config/product.yml.
    # First try a dedicated business_brain_db key; fall back to business_brain.page_id
    # (which is a Notion page whose children we'll migrate as sub-pages).
    # Use 4-space indent to stay within the business_brain: block.
    # Use awk to avoid grep-no-match exit code under set -o pipefail.
    NOTION_DB_ID=$(
      grep -A20 '  business_brain:' "$CONFIG_FILE" 2>/dev/null \
      | awk '/    business_brain_db:/ {print $2; exit}' \
      | tr -d '"'
    )
    if [ -z "$NOTION_DB_ID" ]; then
      # Fall back to page_id (a Notion page; we'll migrate its child sub-pages)
      NOTION_DB_ID=$(
        grep -A20 '  business_brain:' "$CONFIG_FILE" 2>/dev/null \
        | awk '/    page_id:/ {print $2; exit}' \
        | tr -d '"'
      )
    fi
    ;;
  *)
    echo "Unsupported space slug: '$SPACE_SLUG'. Supported: business-brain"
    exit 1
    ;;
esac

if [ -z "$NOTION_DB_ID" ]; then
  echo "ERROR: Could not resolve Notion DB/page ID for slug '$SPACE_SLUG' from $CONFIG_FILE"
  echo "Expected key: notion.business_brain_db (or notion.business_brain.page_id)"
  exit 1
fi

echo "Space slug:    $SPACE_SLUG"
echo "Space name:    $SPACE_DISPLAY_NAME"
echo "Notion DB ID:  $NOTION_DB_ID"
echo "Dry run:       $DRY_RUN"
echo ""

# ---------------------------------------------------------------
# Load env + library
# ---------------------------------------------------------------
set -a
source "$ENV_FILE" 2>/dev/null || true
set +a
source "$LIB_FILE"

if [ -z "${NOTION_API_KEY:-}" ]; then
  echo "ERROR: NOTION_API_KEY not set in $ENV_FILE"
  echo "Ensure integration 'OpenClaw2' has been granted access to the Notion page in Notion UI."
  exit 1
fi

NOTION_VERSION="2022-06-28"
NOTION_HEADERS=(
  -H "Authorization: Bearer $NOTION_API_KEY"
  -H "Notion-Version: $NOTION_VERSION"
  -H "Content-Type: application/json"
)

# ---------------------------------------------------------------
# Resolve Library Space ID
# ---------------------------------------------------------------
LIBRARY_SPACE_ID=$(library_space_id "$SPACE_DISPLAY_NAME")
if [ -z "$LIBRARY_SPACE_ID" ]; then
  echo "ERROR: Library Space '$SPACE_DISPLAY_NAME' not found."
  echo "Run: bash cabinet/scripts/install-starter-space.sh business-brain"
  exit 1
fi
echo "Library Space ID: $LIBRARY_SPACE_ID"
echo ""

# ---------------------------------------------------------------
# Helper: extract plain text from Notion rich_text array
# ---------------------------------------------------------------
extract_plain_text() {
  local json="$1"
  printf '%s' "$json" | jq -r '[.[] | .plain_text] | join("")' 2>/dev/null || echo ""
}

# ---------------------------------------------------------------
# Helper: flatten Notion blocks → markdown
# ---------------------------------------------------------------
blocks_to_markdown() {
  local blocks_json="$1"
  local md=""
  local unsupported_count=0

  while IFS= read -r block; do
    local btype
    btype=$(printf '%s' "$block" | jq -r '.type' 2>/dev/null)

    case "$btype" in
      paragraph)
        local text
        text=$(printf '%s' "$block" | jq -r '.paragraph.rich_text' | jq -r '[.[] | .plain_text] | join("")' 2>/dev/null)
        [ -n "$text" ] && md="${md}${text}"$'\n\n' || md="${md}"$'\n'
        ;;
      heading_1)
        local text
        text=$(printf '%s' "$block" | jq -r '.heading_1.rich_text' | jq -r '[.[] | .plain_text] | join("")' 2>/dev/null)
        md="${md}# ${text}"$'\n\n'
        ;;
      heading_2)
        local text
        text=$(printf '%s' "$block" | jq -r '.heading_2.rich_text' | jq -r '[.[] | .plain_text] | join("")' 2>/dev/null)
        md="${md}## ${text}"$'\n\n'
        ;;
      heading_3)
        local text
        text=$(printf '%s' "$block" | jq -r '.heading_3.rich_text' | jq -r '[.[] | .plain_text] | join("")' 2>/dev/null)
        md="${md}### ${text}"$'\n\n'
        ;;
      bulleted_list_item)
        local text
        text=$(printf '%s' "$block" | jq -r '.bulleted_list_item.rich_text' | jq -r '[.[] | .plain_text] | join("")' 2>/dev/null)
        md="${md}- ${text}"$'\n'
        ;;
      numbered_list_item)
        local text
        text=$(printf '%s' "$block" | jq -r '.numbered_list_item.rich_text' | jq -r '[.[] | .plain_text] | join("")' 2>/dev/null)
        md="${md}1. ${text}"$'\n'
        ;;
      to_do)
        local text checked
        text=$(printf '%s' "$block" | jq -r '.to_do.rich_text' | jq -r '[.[] | .plain_text] | join("")' 2>/dev/null)
        checked=$(printf '%s' "$block" | jq -r '.to_do.checked' 2>/dev/null)
        local box="[ ]"
        [ "$checked" = "true" ] && box="[x]"
        md="${md}- ${box} ${text}"$'\n'
        ;;
      code)
        local text lang
        text=$(printf '%s' "$block" | jq -r '.code.rich_text' | jq -r '[.[] | .plain_text] | join("")' 2>/dev/null)
        lang=$(printf '%s' "$block" | jq -r '.code.language // ""' 2>/dev/null)
        md="${md}\`\`\`${lang}"$'\n'"${text}"$'\n'"\`\`\`"$'\n\n'
        ;;
      quote)
        local text
        text=$(printf '%s' "$block" | jq -r '.quote.rich_text' | jq -r '[.[] | .plain_text] | join("")' 2>/dev/null)
        md="${md}> ${text}"$'\n\n'
        ;;
      divider)
        md="${md}---"$'\n\n'
        ;;
      *)
        md="${md}<!-- skipped: ${btype} -->"$'\n'
        unsupported_count=$((unsupported_count + 1))
        ;;
    esac
  done < <(printf '%s' "$blocks_json" | jq -c '.[]' 2>/dev/null)

  # Return unsupported count via file (subshell-safe)
  printf '%d' "$unsupported_count" >> /tmp/mntl_unsupported_$$

  printf '%s' "$md"
}

# ---------------------------------------------------------------
# Helper: find Notion page title from properties
# ---------------------------------------------------------------
get_page_title() {
  local props_json="$1"
  # Find the property of type "title" (could be named anything)
  local title
  title=$(printf '%s' "$props_json" | jq -r '
    to_entries[]
    | select(.value.type == "title")
    | .value.title
    | [.[] | .plain_text]
    | join("")
  ' 2>/dev/null | head -1)
  printf '%s' "${title:-Untitled}"
}

# ---------------------------------------------------------------
# Helper: query existing Library record by notion_page_id
# Returns lines: id / title / md5_of_content — tab-separated
# ---------------------------------------------------------------
find_library_record() {
  local notion_page_id="$1"
  psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' \
    -v space_id="$LIBRARY_SPACE_ID" \
    -v notion_page_id="$notion_page_id" \
    2>/dev/null <<'SQLEOF'
SELECT id, title, md5(content_markdown)
FROM library_records
WHERE space_id = :'space_id'::bigint
  AND superseded_by IS NULL
  AND schema_data->>'notion_page_id' = :'notion_page_id'
LIMIT 1;
SQLEOF
}

# ---------------------------------------------------------------
# Paginate Notion DB (try database query first, then page children)
# ---------------------------------------------------------------
echo "Fetching pages from Notion (ID: $NOTION_DB_ID)..."

# Try database query first
FIRST_RESPONSE=$(curl -s -X POST \
  "https://api.notion.com/v1/databases/${NOTION_DB_ID}/query" \
  "${NOTION_HEADERS[@]}" \
  -d '{"page_size": 100}' 2>/dev/null)

# Check if it's a valid database response or an error
RESPONSE_TYPE=$(printf '%s' "$FIRST_RESPONSE" | jq -r '.object // "error"' 2>/dev/null)

USE_CHILDREN_MODE=false
if [ "$RESPONSE_TYPE" = "error" ] || [ "$RESPONSE_TYPE" = "page" ]; then
  # It's not a database — treat as a page, query its child pages
  echo "Note: Notion ID appears to be a page (not a database). Querying child blocks/pages..."
  USE_CHILDREN_MODE=true
elif [ "$RESPONSE_TYPE" != "list" ]; then
  echo "ERROR: Unexpected Notion API response (object=$RESPONSE_TYPE):"
  printf '%s' "$FIRST_RESPONSE" | jq '.' 2>/dev/null || printf '%s\n' "$FIRST_RESPONSE"
  echo ""
  echo "If you see a 404 or 'object_not_found', ensure integration 'OpenClaw2' has been"
  echo "granted access to this page in the Notion UI (Share → Invite → OpenClaw2)."
  exit 1
fi

# Collect all Notion page objects
declare -a ALL_PAGES=()

if [ "$USE_CHILDREN_MODE" = true ]; then
  # In children mode, fetch child blocks and treat child_page blocks as pages
  CHILDREN_RESP=$(curl -s \
    "https://api.notion.com/v1/blocks/${NOTION_DB_ID}/children?page_size=100" \
    "${NOTION_HEADERS[@]}" 2>/dev/null)

  CHILDREN_TYPE=$(printf '%s' "$CHILDREN_RESP" | jq -r '.object // "error"' 2>/dev/null)
  if [ "$CHILDREN_TYPE" = "error" ] || [ "$CHILDREN_TYPE" != "list" ]; then
    echo "ERROR: Could not fetch children of page $NOTION_DB_ID"
    printf '%s' "$CHILDREN_RESP" | jq '.' 2>/dev/null || printf '%s\n' "$CHILDREN_RESP"
    echo "Ensure 'OpenClaw2' integration has access to the Business Brain page in Notion."
    exit 1
  fi

  # Extract child_page blocks — their IDs are the sub-page IDs
  while IFS= read -r child_id; do
    [ -z "$child_id" ] && continue
    # Fetch each sub-page to get its properties
    PAGE_RESP=$(curl -s \
      "https://api.notion.com/v1/pages/${child_id}" \
      "${NOTION_HEADERS[@]}" 2>/dev/null)
    ALL_PAGES+=("$PAGE_RESP")
    sleep 0.3
  done < <(printf '%s' "$CHILDREN_RESP" | jq -r '.results[] | select(.type == "child_page") | .id' 2>/dev/null)

else
  # Database mode: paginate through all records
  CURSOR=""
  HAS_MORE=true
  CURRENT_RESPONSE="$FIRST_RESPONSE"

  while [ "$HAS_MORE" = true ]; do
    # Collect pages from this batch
    while IFS= read -r page; do
      [ -n "$page" ] && ALL_PAGES+=("$page")
    done < <(printf '%s' "$CURRENT_RESPONSE" | jq -c '.results[]' 2>/dev/null)

    HAS_MORE=$(printf '%s' "$CURRENT_RESPONSE" | jq -r '.has_more' 2>/dev/null)
    CURSOR=$(printf '%s' "$CURRENT_RESPONSE" | jq -r '.next_cursor // ""' 2>/dev/null)

    if [ "$HAS_MORE" = "true" ] && [ -n "$CURSOR" ]; then
      CURRENT_RESPONSE=$(curl -s -X POST \
        "https://api.notion.com/v1/databases/${NOTION_DB_ID}/query" \
        "${NOTION_HEADERS[@]}" \
        -d "{\"page_size\": 100, \"start_cursor\": \"$CURSOR\"}" 2>/dev/null)
    else
      HAS_MORE=false
    fi
  done
fi

TOTAL_PAGES=${#ALL_PAGES[@]}
echo "Found $TOTAL_PAGES pages in Notion."
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would migrate $TOTAL_PAGES pages to '$SPACE_DISPLAY_NAME' Space (id=$LIBRARY_SPACE_ID)."
  echo "[DRY RUN] No records written."
  exit 0
fi

# ---------------------------------------------------------------
# Process each page
# ---------------------------------------------------------------
COUNT_NEW=0
COUNT_UPDATED=0
COUNT_SKIPPED=0
COUNT_UNSUPPORTED=0

# Init unsupported counter file
echo -n "" > /tmp/mntl_unsupported_$$

for page_json in "${ALL_PAGES[@]}"; do
  PAGE_ID=$(printf '%s' "$page_json" | jq -r '.id' 2>/dev/null)
  if [ -z "$PAGE_ID" ]; then
    continue
  fi

  # --- Title ---
  PROPS=$(printf '%s' "$page_json" | jq -c '.properties // {}' 2>/dev/null)
  TITLE=$(get_page_title "$PROPS")

  # --- schema_data fields ---
  # notion_page_id (strip dashes for URL, keep with dashes as id)
  PAGE_ID_CLEAN="${PAGE_ID//-/}"
  NOTION_URL="https://www.notion.so/${PAGE_ID_CLEAN}"

  # category: look for "Category" or "Section" select property
  CATEGORY=$(printf '%s' "$PROPS" | jq -r '
    (.Category // .category // .Section // .section // empty)
    | select(.type == "select")
    | .select.name // empty
  ' 2>/dev/null | head -1)
  [ -z "$CATEGORY" ] && CATEGORY="null"

  # status: look for "Status" property
  STATUS=$(printf '%s' "$PROPS" | jq -r '
    (.Status // .status // empty)
    | select(.type == "status" or .type == "select")
    | (.status.name // .select.name) // empty
  ' 2>/dev/null | head -1)
  [ -z "$STATUS" ] && STATUS="Active"

  # effective_from: look for date properties named "Date", "Created", "Effective From"
  EFFECTIVE_FROM=$(printf '%s' "$PROPS" | jq -r '
    (."Effective From" // ."Effective from" // ."Date" // empty)
    | select(.type == "date")
    | .date.start // empty
  ' 2>/dev/null | head -1)
  [ -z "$EFFECTIVE_FROM" ] && EFFECTIVE_FROM="null"

  # last_reviewed: look for "Last Reviewed" or "Last Edited"
  LAST_REVIEWED=$(printf '%s' "$PROPS" | jq -r '
    (."Last Reviewed" // ."Last reviewed" // ."Last Review" // empty)
    | select(.type == "date")
    | .date.start // empty
  ' 2>/dev/null | head -1)
  [ -z "$LAST_REVIEWED" ] && LAST_REVIEWED="null"

  # labels: look for "Tags" multi-select
  LABELS_CSV=$(printf '%s' "$PROPS" | jq -r '
    (.Tags // .tags // empty)
    | select(.type == "multi_select")
    | [.multi_select[].name]
    | join(",")
  ' 2>/dev/null | head -1)

  # Build schema_data JSON
  SCHEMA_DATA=$(jq -n \
    --arg npid "$PAGE_ID" \
    --arg nurl "$NOTION_URL" \
    --arg cat "$CATEGORY" \
    --arg status "$STATUS" \
    --arg eff "$EFFECTIVE_FROM" \
    --arg rev "$LAST_REVIEWED" \
    '{
      notion_page_id: $npid,
      notion_url: $nurl,
      category: (if $cat == "null" then null else $cat end),
      status: $status,
      effective_from: (if $eff == "null" then null else $eff end),
      last_reviewed: (if $rev == "null" then null else $rev end)
    }' 2>/dev/null)

  # --- Body: fetch blocks ---
  sleep 0.3
  BLOCKS_RESP=$(curl -s \
    "https://api.notion.com/v1/blocks/${PAGE_ID}/children?page_size=100" \
    "${NOTION_HEADERS[@]}" 2>/dev/null)

  BLOCKS_OBJ=$(printf '%s' "$BLOCKS_RESP" | jq -r '.object // "error"' 2>/dev/null)
  if [ "$BLOCKS_OBJ" = "error" ]; then
    echo "  WARN: Could not fetch blocks for page '$TITLE' ($PAGE_ID) — skipping body"
    BODY=""
  else
    BLOCKS_JSON=$(printf '%s' "$BLOCKS_RESP" | jq -c '.results // []' 2>/dev/null)
    BODY=$(blocks_to_markdown "$BLOCKS_JSON")
  fi

  # --- Idempotency check ---
  EXISTING=$(find_library_record "$PAGE_ID")
  EXISTING_ID=$(printf '%s' "$EXISTING" | cut -f1)
  EXISTING_TITLE=$(printf '%s' "$EXISTING" | cut -f2)
  EXISTING_MD5=$(printf '%s' "$EXISTING" | cut -f3)

  # Compute md5 of current body for comparison
  BODY_MD5=$(printf '%s' "$BODY" | md5sum | awk '{print $1}')

  if [ -n "$EXISTING_ID" ]; then
    # Record exists — check if title or body changed (compare by md5 to avoid whitespace issues)
    if [ "$EXISTING_TITLE" = "$TITLE" ] && [ "$EXISTING_MD5" = "$BODY_MD5" ]; then
      echo "  SKIP (unchanged): $TITLE"
      COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
    else
      echo "  UPDATE: $TITLE"
      library_update_record "$EXISTING_ID" "$TITLE" "$BODY" "$SCHEMA_DATA" "$LABELS_CSV" > /dev/null
      COUNT_UPDATED=$((COUNT_UPDATED + 1))
    fi
  else
    echo "  CREATE: $TITLE"
    library_create_record "$LIBRARY_SPACE_ID" "$TITLE" "$BODY" "$SCHEMA_DATA" "$LABELS_CSV" > /dev/null
    COUNT_NEW=$((COUNT_NEW + 1))
  fi
done

# Tally unsupported blocks
if [ -f /tmp/mntl_unsupported_$$ ]; then
  COUNT_UNSUPPORTED=$(paste -sd+ /tmp/mntl_unsupported_$$ | bc 2>/dev/null || echo 0)
  rm -f /tmp/mntl_unsupported_$$
fi

echo ""
echo "Migration complete."
echo "  Created:  $COUNT_NEW"
echo "  Updated:  $COUNT_UPDATED"
echo "  Skipped:  $COUNT_SKIPPED (unchanged)"
echo "  Total:    $TOTAL_PAGES"
echo "  Unsupported block placeholders: ${COUNT_UNSUPPORTED:-0}"
