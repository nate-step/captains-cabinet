#!/bin/bash
# import-linear-to-library.sh — One-shot Linear → Library import for team SEN
# Sprint B CP3: idempotent migration of Linear issues into the Library Issues Space.
#
# Usage:
#   bash import-linear-to-library.sh           # live run (create/update)
#   bash import-linear-to-library.sh --dry-run # paginate + count only, no writes
#   bash import-linear-to-library.sh --limit N # import at most N issues (for testing)
#
# State types fetched: all (backlog, unstarted, started, completed, cancelled)
# Pagination: cursor-based, 100 issues per page

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Load env ────────────────────────────────────────────────────────────────
set -a
source "${SCRIPT_DIR}/../.env" 2>/dev/null || true
set +a

source "${SCRIPT_DIR}/lib/library.sh" 2>/dev/null

# ── Config ──────────────────────────────────────────────────────────────────
DRY_RUN=false
ISSUE_LIMIT=0       # 0 = no limit
TEAM_ID="1f9f4fae-4283-407d-bde1-c5fd56483b76"
LINEAR_URL="https://api.linear.app/graphql"
PAGE_SIZE=100

# Parse args
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --limit) shift ;; # handled below
    --limit=*) ISSUE_LIMIT="${arg#*=}" ;;
  esac
done
# handle "--limit N" form
for i in "$@"; do
  if [ "$i" = "--limit" ]; then
    shift; ISSUE_LIMIT="${1:-0}"; break
  fi
done

# ── Preflight ────────────────────────────────────────────────────────────────
if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "ERROR: LINEAR_API_KEY not set. Check cabinet/.env" >&2
  exit 1
fi

# Validate key with a cheap query
_auth_check=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$LINEAR_URL" \
  -H "Authorization: $LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ viewer { id } }"}')
if [ "$_auth_check" = "401" ]; then
  echo "ERROR: LINEAR_API_KEY is invalid or expired (HTTP 401)" >&2
  exit 1
fi

SPACE_ID=$(library_space_id "Issues")
if [ -z "$SPACE_ID" ]; then
  echo "ERROR: Issues Space not found in Library. Run install-starter-space.sh first." >&2
  exit 1
fi
echo "Issues Space id: $SPACE_ID"
$DRY_RUN && echo "DRY RUN — no writes will occur"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Map Linear priority int → Library select string
map_priority() {
  local p="$1"
  case "$p" in
    1) echo "P0 — critical, drop everything" ;;
    2) echo "P1 — high, do this sprint" ;;
    3) echo "P2 — medium, do this month" ;;
    4) echo "P3 — low, backlog" ;;
    *) echo "P2 — medium, do this month" ;; # 0 = no priority → default
  esac
}

# Map Linear state name → Library state select
map_state() {
  local s="$1"
  case "$s" in
    "Backlog"|"Todo"|"In Progress"|"In Review"|"Done"|"Canceled") echo "$s" ;;
    "Cancelled") echo "Canceled" ;; # Linear uses British spelling in some states
    *) echo "Backlog" ;;
  esac
}

# Map assignee name → officer abbreviation or "captain"
map_assignee() {
  local name="$1"
  if [ -z "$name" ]; then echo ""; return; fi
  local lower
  lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
  # Known captain names — extend as needed
  if echo "$lower" | grep -qiE "^(nate|nathaniel|refslund)"; then
    echo "captain"
    return
  fi
  # Officer abbreviation heuristics from first name
  case "$lower" in
    cos*) echo "cos" ;;
    cto*) echo "cto" ;;
    cpo*) echo "cpo" ;;
    cro*) echo "cro" ;;
    coo*) echo "coo" ;;
    *) echo "$(echo "$name" | awk '{print tolower($1)}' | cut -c1-8)" ;;
  esac
}

# Fetch one page of issues. Returns raw JSON.
fetch_issues_page() {
  local cursor="${1:-}"
  local after_clause=""
  if [ -n "$cursor" ]; then
    after_clause=", after: \"$cursor\""
  fi

  # Fetch all state types; Linear's default already includes everything
  local query
  query=$(cat <<GRAPHQL
{
  team(id: "$TEAM_ID") {
    issues(
      first: $PAGE_SIZE
      $after_clause
      orderBy: updatedAt
    ) {
      nodes {
        identifier
        createdAt
        title
        description
        priority
        state { name type }
        assignee { name }
        dueDate
        labels { nodes { name } }
        comments(orderBy: createdAt) {
          nodes { body createdAt user { name } }
        }
      }
      pageInfo { hasNextPage endCursor }
    }
  }
}
GRAPHQL
)

  curl -s --max-time 30 -X POST "$LINEAR_URL" \
    -H "Authorization: $LINEAR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg q "$query" '{query: $q}')"
}

# Look up existing active record by linear_id in the Issues Space.
# Returns record id or empty string.
find_existing_record() {
  local linear_id="$1"
  psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v space_id="$SPACE_ID" \
    -v linear_id="$linear_id" \
    2>/dev/null <<'SQL'
SELECT id
FROM library_records
WHERE space_id = :'space_id'::bigint
  AND superseded_by IS NULL
  AND schema_data->>'linear_id' = :'linear_id'
LIMIT 1;
SQL
}

# Compute a lightweight content hash for change detection (no Voyage call needed)
content_hash() {
  printf '%s' "$1" | md5sum | awk '{print $1}'
}

# Get the stored content hash from the record's schema_data (we piggyback on schema_data)
get_stored_hash() {
  local record_id="$1"
  psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v record_id="$record_id" \
    2>/dev/null <<'SQL'
SELECT schema_data->>'_content_hash'
FROM library_records
WHERE id = :'record_id'::bigint;
SQL
}

# ── Counters ─────────────────────────────────────────────────────────────────
count_new=0
count_updated=0
count_skipped=0
count_error=0
processed=0

# ── Main loop ─────────────────────────────────────────────────────────────────
cursor=""
has_next=true

echo ""
echo "Fetching Linear issues for team SEN..."

while $has_next; do
  page_json=$(fetch_issues_page "$cursor")

  # Check for API errors
  if echo "$page_json" | jq -e '.errors' >/dev/null 2>&1; then
    echo "ERROR: Linear API returned errors:" >&2
    echo "$page_json" | jq '.errors' >&2
    exit 1
  fi

  issues=$(echo "$page_json" | jq -c '.data.team.issues.nodes[]')
  has_next=$(echo "$page_json" | jq -r '.data.team.issues.pageInfo.hasNextPage')
  cursor=$(echo "$page_json" | jq -r '.data.team.issues.pageInfo.endCursor')

  while IFS= read -r issue; do
    [ -z "$issue" ] && continue

    # Respect --limit
    if [ "$ISSUE_LIMIT" -gt 0 ] && [ "$processed" -ge "$ISSUE_LIMIT" ]; then
      has_next=false
      break
    fi

    identifier=$(echo "$issue" | jq -r '.identifier')
    linear_created_at=$(echo "$issue" | jq -r '.createdAt // ""')
    title=$(echo "$issue" | jq -r '.title')
    description=$(echo "$issue" | jq -r '.description // ""')
    priority=$(echo "$issue" | jq -r '.priority')
    state_name=$(echo "$issue" | jq -r '.state.name')
    assignee_name=$(echo "$issue" | jq -r '.assignee.name // ""')
    due_date=$(echo "$issue" | jq -r '.dueDate // ""')

    # Labels array
    labels_json=$(echo "$issue" | jq -r '[.labels.nodes[].name] | @json')
    labels_csv=$(echo "$issue" | jq -r '[.labels.nodes[].name] | join(",")' | sed 's/ /_/g')

    # captain_decision / founder_action flags
    has_captain_decision=$(echo "$issue" | jq -r '[.labels.nodes[].name] | any(. == "captain-decision") | tostring')
    has_founder_action=$(echo "$issue" | jq -r '[.labels.nodes[].name] | any(. == "founder-action") | tostring')

    # Build content_markdown
    record_title="${identifier}: ${title}"
    content_md="${description}"

    # Append comments section if any
    comments_json=$(echo "$issue" | jq -c '.comments.nodes')
    comments_count=$(echo "$comments_json" | jq 'length')
    if [ "$comments_count" -gt 0 ]; then
      content_md="${content_md}"$'\n\n'"## Comments"$'\n'
      while IFS= read -r comment; do
        author=$(echo "$comment" | jq -r '.user.name // "Unknown"')
        ts=$(echo "$comment" | jq -r '.createdAt | split("T")[0]')
        body=$(echo "$comment" | jq -r '.body')
        content_md="${content_md}"$'\n'"**${author}** (${ts}):"$'\n'"${body}"$'\n'
      done < <(echo "$comments_json" | jq -c '.[]')
    fi

    # Map fields
    mapped_priority=$(map_priority "$priority")
    mapped_state=$(map_state "$state_name")
    mapped_assignee=$(map_assignee "$assignee_name")

    # Build schema_data JSON — include _content_hash for change detection
    content_fingerprint=$(content_hash "${record_title}${content_md}${mapped_priority}${mapped_state}${mapped_assignee}${due_date}${labels_csv}${has_captain_decision}${has_founder_action}")

    schema_data=$(jq -n \
      --arg priority "$mapped_priority" \
      --arg state "$mapped_state" \
      --arg assignee "$mapped_assignee" \
      --arg due_date "$due_date" \
      --arg linear_id "$identifier" \
      --argjson captain_decision "$has_captain_decision" \
      --argjson founder_action "$has_founder_action" \
      --arg content_hash "$content_fingerprint" \
      '{
        priority: $priority,
        state: $state,
        assignee: (if $assignee == "" then null else $assignee end),
        due_date: (if $due_date == "" then null else $due_date end),
        linear_id: $linear_id,
        captain_decision: $captain_decision,
        founder_action: $founder_action,
        _content_hash: $content_hash
      }')

    if $DRY_RUN; then
      echo "  [DRY-RUN] Would process: $record_title (state=$mapped_state priority=$mapped_priority)"
      ((processed++)) || true
      ((count_new++)) || true
      continue
    fi

    # ── Idempotency check ──────────────────────────────────────────────────
    existing_id=$(find_existing_record "$identifier")

    if [ -n "$existing_id" ]; then
      stored_hash=$(get_stored_hash "$existing_id")
      if [ "$stored_hash" = "$content_fingerprint" ]; then
        # No change — skip entirely
        echo "  [SKIP]   $identifier (unchanged)"
        ((count_skipped++)) || true
      else
        # Changed — update
        echo "  [UPDATE] $identifier: $title"
        new_id=$(library_update_record \
          "$existing_id" \
          "$record_title" \
          "$content_md" \
          "$schema_data" \
          "$labels_csv") || { echo "    ERROR updating $identifier" >&2; ((count_error++)) || true; ((processed++)) || true; continue; }
        echo "    → new record id: $new_id"
        ((count_updated++)) || true
      fi
    else
      # New record
      echo "  [CREATE] $identifier: $title"
      new_id=$(library_create_record \
        "$SPACE_ID" \
        "$record_title" \
        "$content_md" \
        "$schema_data" \
        "$labels_csv" \
        "" \
        "" \
        "$linear_created_at") || { echo "    ERROR creating $identifier" >&2; ((count_error++)) || true; ((processed++)) || true; continue; }
      echo "    → record id: $new_id"
      ((count_new++)) || true
    fi

    ((processed++)) || true

    # Rate-limit courtesy: 100ms between records
    sleep 0.1

  done < <(echo "$issues")

  # Rate-limit between pages
  $has_next && sleep 0.2

done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
if $DRY_RUN; then
  echo "DRY RUN complete — would import $count_new issues (no writes made)"
else
  echo "Import complete:"
  echo "  Created : $count_new"
  echo "  Updated : $count_updated"
  echo "  Skipped : $count_skipped (unchanged)"
  echo "  Errors  : $count_error"
  echo "  Total   : $processed"
fi
echo "═══════════════════════════════════════════════"

exit 0
