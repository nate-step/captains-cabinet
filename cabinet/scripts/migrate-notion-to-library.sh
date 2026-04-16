#!/bin/bash
# migrate-notion-to-library.sh — One-shot Notion → Library Space migration
#
# Usage:
#   bash cabinet/scripts/migrate-notion-to-library.sh <space-slug> [--dry-run]
#
# Supported space slugs:
#   business-brain         → "Business Brain" Space
#   research-briefs        → "Research Archive" Space
#   competitive-intel      → "Research Archive" Space
#   market-trends          → "Research Archive" Space
#   decision-journal       → "Decisions Log" Space
#   decision-queue         → "Decisions Log" Space
#   architecture-decisions → "Architecture Decision Records" Space
#   user-feedback          → "Customer Insights" Space
#   feature-specs          → "Playbooks" Space
#   improvement-proposals  → "Playbooks" Space
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
  echo "Supported slugs:"
  echo "  business-brain         → 'Business Brain' Space"
  echo "  research-briefs        → 'Research Archive' Space"
  echo "  competitive-intel      → 'Research Archive' Space"
  echo "  market-trends          → 'Research Archive' Space"
  echo "  decision-journal       → 'Decisions Log' Space"
  echo "  decision-queue         → 'Decisions Log' Space"
  echo "  architecture-decisions → 'Architecture Decision Records' Space"
  echo "  user-feedback          → 'Customer Insights' Space"
  echo "  feature-specs          → 'Playbooks' Space"
  echo "  improvement-proposals  → 'Playbooks' Space"
  exit 1
fi

# ---------------------------------------------------------------
# Helper: extract a Notion ID from product.yml given a block path
# Usage: extract_notion_id "block_name" "key_name"
# Example: extract_notion_id "research_hub" "research_briefs_db"
# ---------------------------------------------------------------
extract_notion_id() {
  local block="$1" key="$2"
  grep -A30 "  ${block}:" "$CONFIG_FILE" 2>/dev/null \
    | awk -v k="    ${key}:" '$0 ~ k {print $2; exit}' \
    | tr -d '"'
}

# ---------------------------------------------------------------
# Validate slug → Space name + Notion DB id mapping
# ---------------------------------------------------------------
case "$SPACE_SLUG" in
  business-brain)
    SPACE_DISPLAY_NAME="Business Brain"
    NOTION_DB_ID=$(extract_notion_id "business_brain" "business_brain_db")
    [ -z "$NOTION_DB_ID" ] && NOTION_DB_ID=$(extract_notion_id "business_brain" "page_id")
    ;;
  research-briefs)
    SPACE_DISPLAY_NAME="Research Archive"
    NOTION_DB_ID=$(extract_notion_id "research_hub" "research_briefs_db")
    ;;
  competitive-intel)
    SPACE_DISPLAY_NAME="Research Archive"
    NOTION_DB_ID=$(extract_notion_id "research_hub" "competitive_intel_db")
    ;;
  market-trends)
    SPACE_DISPLAY_NAME="Research Archive"
    NOTION_DB_ID=$(extract_notion_id "research_hub" "market_trends_db")
    ;;
  decision-journal)
    SPACE_DISPLAY_NAME="Decisions Log"
    NOTION_DB_ID=$(extract_notion_id "cabinet_ops" "decision_journal_db")
    ;;
  decision-queue)
    SPACE_DISPLAY_NAME="Decisions Log"
    NOTION_DB_ID=$(extract_notion_id "dashboard" "decision_queue_db")
    ;;
  architecture-decisions)
    SPACE_DISPLAY_NAME="Architecture Decision Records"
    NOTION_DB_ID=$(extract_notion_id "engineering_hub" "architecture_decisions_db")
    ;;
  user-feedback)
    SPACE_DISPLAY_NAME="Customer Insights"
    NOTION_DB_ID=$(extract_notion_id "product_hub" "user_feedback_db")
    ;;
  feature-specs)
    SPACE_DISPLAY_NAME="Playbooks"
    NOTION_DB_ID=$(extract_notion_id "product_hub" "feature_specs_db")
    ;;
  improvement-proposals)
    SPACE_DISPLAY_NAME="Playbooks"
    NOTION_DB_ID=$(extract_notion_id "cabinet_ops" "improvement_proposals_db")
    ;;
  *)
    echo "Unsupported space slug: '$SPACE_SLUG'. Run without args for supported list."
    exit 1
    ;;
esac

if [ -z "$NOTION_DB_ID" ]; then
  echo "ERROR: Could not resolve Notion DB/page ID for slug '$SPACE_SLUG' from $CONFIG_FILE"
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
# Helper: render Notion page properties as a markdown table
# Used as body fallback when a DB row has no block children
# ---------------------------------------------------------------
properties_to_markdown() {
  local props_json="$1"
  local md=""
  md="| Property | Value |"$'\n'
  md="${md}|----------|-------|"$'\n'

  while IFS= read -r entry; do
    local key val ptype
    key=$(printf '%s' "$entry" | jq -r '.key' 2>/dev/null)
    ptype=$(printf '%s' "$entry" | jq -r '.value.type' 2>/dev/null)

    case "$ptype" in
      title)
        val=$(printf '%s' "$entry" | jq -r '[.value.title[] | .plain_text] | join("")' 2>/dev/null)
        ;;
      rich_text)
        val=$(printf '%s' "$entry" | jq -r '[.value.rich_text[] | .plain_text] | join("")' 2>/dev/null)
        ;;
      select)
        val=$(printf '%s' "$entry" | jq -r '.value.select.name // ""' 2>/dev/null)
        ;;
      status)
        val=$(printf '%s' "$entry" | jq -r '.value.status.name // ""' 2>/dev/null)
        ;;
      multi_select)
        val=$(printf '%s' "$entry" | jq -r '[.value.multi_select[].name] | join(", ")' 2>/dev/null)
        ;;
      date)
        val=$(printf '%s' "$entry" | jq -r '.value.date.start // ""' 2>/dev/null)
        ;;
      created_time)
        val=$(printf '%s' "$entry" | jq -r '.value.created_time // ""' 2>/dev/null | cut -c1-10)
        ;;
      last_edited_time)
        val=$(printf '%s' "$entry" | jq -r '.value.last_edited_time // ""' 2>/dev/null | cut -c1-10)
        ;;
      url)
        val=$(printf '%s' "$entry" | jq -r '.value.url // ""' 2>/dev/null)
        ;;
      number)
        val=$(printf '%s' "$entry" | jq -r '.value.number // ""' 2>/dev/null)
        ;;
      checkbox)
        val=$(printf '%s' "$entry" | jq -r 'if .value.checkbox then "Yes" else "No" end' 2>/dev/null)
        ;;
      unique_id)
        val=$(printf '%s' "$entry" | jq -r '(.value.unique_id.prefix // "") + "-" + (.value.unique_id.number // 0 | tostring)' 2>/dev/null | sed 's/^-//')
        ;;
      people)
        val=$(printf '%s' "$entry" | jq -r '[.value.people[].name // .value.people[].id] | join(", ")' 2>/dev/null)
        ;;
      *)
        val=""
        ;;
    esac

    [ -z "$val" ] && continue
    # Escape pipe chars in val to not break markdown table
    val="${val//|/\\|}"
    md="${md}| ${key} | ${val} |"$'\n'
  done < <(printf '%s' "$props_json" | jq -c 'to_entries[]' 2>/dev/null)

  printf '%s' "$md"
}

# ---------------------------------------------------------------
# Helper: find Notion page title from properties
# ---------------------------------------------------------------
get_page_title() {
  local props_json="$1"
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
# Helper: extract labels from ALL multi_select properties
# Returns CSV of option names (deduplicated)
# ---------------------------------------------------------------
extract_all_labels() {
  local props_json="$1"
  printf '%s' "$props_json" | jq -r '
    [to_entries[]
    | select(.value.type == "multi_select")
    | .value.multi_select[].name]
    | unique
    | join(",")
  ' 2>/dev/null || echo ""
}

# ---------------------------------------------------------------
# Helper: extract rich_text property value as plain text
# ---------------------------------------------------------------
get_rich_text_prop() {
  local props_json="$1" prop_name="$2"
  printf '%s' "$props_json" | jq -r --arg p "$prop_name" '
    .[$p]
    | select(.type == "rich_text")
    | [.rich_text[] | .plain_text]
    | join("")
  ' 2>/dev/null || echo ""
}

# ---------------------------------------------------------------
# Per-slug schema_data mappers
# Each function takes props_json, page_id, notion_url
# and outputs a valid JSON object for schema_data
# ---------------------------------------------------------------

# Research Archive — research-briefs
# Real props: Topic(select), Impact(select), Tags(multi_select), Created(created_time)
map_schema_research_briefs() {
  local props_json="$1" page_id="$2" notion_url="$3"
  local topic impact created
  topic=$(printf '%s' "$props_json" | jq -r '.Topic.select.name // empty' 2>/dev/null | head -1)
  [ -z "$topic" ] && topic="research-briefs"
  impact=$(printf '%s' "$props_json" | jq -r '.Impact.select.name // empty' 2>/dev/null | head -1)
  created=$(printf '%s' "$props_json" | jq -r '.Created.created_time // empty' 2>/dev/null | head -1 | cut -c1-10)

  jq -n \
    --arg npid "$page_id" \
    --arg nurl "$notion_url" \
    --arg topic "$topic" \
    --arg impact "$impact" \
    --arg created "$created" \
    '{
      notion_page_id: $npid,
      notion_url: $nurl,
      topic: (if $topic == "" then null else $topic end),
      action_classification: (if $impact == "" then null else $impact end),
      captured_at: (if $created == "" then null else $created end)
    }' 2>/dev/null
}

# Research Archive — competitive-intel
# Real props: Category(select), Threat Level(select), URL(url), Last Updated(last_edited_time)
map_schema_competitive_intel() {
  local props_json="$1" page_id="$2" notion_url="$3"
  local category threat url last_updated
  category=$(printf '%s' "$props_json" | jq -r '.Category.select.name // empty' 2>/dev/null | head -1)
  threat=$(printf '%s' "$props_json" | jq -r '."Threat Level".select.name // empty' 2>/dev/null | head -1)
  url=$(printf '%s' "$props_json" | jq -r '.URL.url // empty' 2>/dev/null | head -1)
  last_updated=$(printf '%s' "$props_json" | jq -r '."Last Updated".last_edited_time // empty' 2>/dev/null | head -1 | cut -c1-10)

  jq -n \
    --arg npid "$page_id" \
    --arg nurl "$notion_url" \
    --arg topic "competitive-intel" \
    --arg category "$category" \
    --arg threat "$threat" \
    --arg source_url "$url" \
    --arg last_updated "$last_updated" \
    '{
      notion_page_id: $npid,
      notion_url: $nurl,
      topic: $topic,
      category: (if $category == "" then null else $category end),
      action_classification: (if $threat == "" then null else $threat end),
      source_url: (if $source_url == "" then null else $source_url end),
      last_updated: (if $last_updated == "" then null else $last_updated end)
    }' 2>/dev/null
}

# Research Archive — market-trends
# Real props: Category(select), Relevance(select), First Spotted(date), Last Updated(last_edited_time)
map_schema_market_trends() {
  local props_json="$1" page_id="$2" notion_url="$3"
  local category relevance first_spotted last_updated
  category=$(printf '%s' "$props_json" | jq -r '.Category.select.name // empty' 2>/dev/null | head -1)
  relevance=$(printf '%s' "$props_json" | jq -r '.Relevance.select.name // empty' 2>/dev/null | head -1)
  first_spotted=$(printf '%s' "$props_json" | jq -r '."First Spotted".date.start // empty' 2>/dev/null | head -1)
  last_updated=$(printf '%s' "$props_json" | jq -r '."Last Updated".last_edited_time // empty' 2>/dev/null | head -1 | cut -c1-10)

  jq -n \
    --arg npid "$page_id" \
    --arg nurl "$notion_url" \
    --arg topic "market-trends" \
    --arg category "$category" \
    --arg relevance "$relevance" \
    --arg first_spotted "$first_spotted" \
    --arg last_updated "$last_updated" \
    '{
      notion_page_id: $npid,
      notion_url: $nurl,
      topic: $topic,
      category: (if $category == "" then null else $category end),
      action_classification: (if $relevance == "" then null else $relevance end),
      captured_at: (if $first_spotted == "" then null else $first_spotted end),
      last_updated: (if $last_updated == "" then null else $last_updated end)
    }' 2>/dev/null
}

# Decisions Log — decision-journal
# Real props: Domain(select), Context(rich_text), Outcome(rich_text), Decided(date)
map_schema_decision_journal() {
  local props_json="$1" page_id="$2" notion_url="$3"
  local domain decided context outcome
  domain=$(printf '%s' "$props_json" | jq -r '.Domain.select.name // empty' 2>/dev/null | head -1)
  decided=$(printf '%s' "$props_json" | jq -r '.Decided.date.start // empty' 2>/dev/null | head -1)
  context=$(get_rich_text_prop "$props_json" "Context")
  outcome=$(get_rich_text_prop "$props_json" "Outcome")

  jq -n \
    --arg npid "$page_id" \
    --arg nurl "$notion_url" \
    --arg domain "$domain" \
    --arg decided "$decided" \
    --arg why "$context" \
    --arg outcome "$outcome" \
    '{
      notion_page_id: $npid,
      notion_url: $nurl,
      domain: (if $domain == "" then null else $domain end),
      decision_date: (if $decided == "" then null else $decided end),
      why: (if $why == "" then null else $why end),
      affected: (if $outcome == "" then null else $outcome end)
    }' 2>/dev/null
}

# Decisions Log — decision-queue
# Real props: Status(select), Priority(select), Context(rich_text), Recommendation(rich_text),
#             Requesting Officer(select), Captain Response(rich_text), Created(created_time)
map_schema_decision_queue() {
  local props_json="$1" page_id="$2" notion_url="$3"
  local status priority requesting_officer created context recommendation
  status=$(printf '%s' "$props_json" | jq -r '.Status.select.name // empty' 2>/dev/null | head -1)
  priority=$(printf '%s' "$props_json" | jq -r '.Priority.select.name // empty' 2>/dev/null | head -1)
  requesting_officer=$(printf '%s' "$props_json" | jq -r '."Requesting Officer".select.name // empty' 2>/dev/null | head -1)
  created=$(printf '%s' "$props_json" | jq -r '.Created.created_time // empty' 2>/dev/null | head -1 | cut -c1-10)
  context=$(get_rich_text_prop "$props_json" "Context")
  recommendation=$(get_rich_text_prop "$props_json" "Recommendation")

  jq -n \
    --arg npid "$page_id" \
    --arg nurl "$notion_url" \
    --arg status "$status" \
    --arg priority "$priority" \
    --arg owner "$requesting_officer" \
    --arg decision_date "$created" \
    --arg why "$context" \
    --arg affected "$recommendation" \
    '{
      notion_page_id: $npid,
      notion_url: $nurl,
      status: (if $status == "" then null else $status end),
      domain: (if $priority == "" then null else $priority end),
      owner: (if $owner == "" then null else $owner end),
      decision_date: (if $decision_date == "" then null else $decision_date end),
      why: (if $why == "" then null else $why end),
      affected: (if $affected == "" then null else $affected end)
    }' 2>/dev/null
}

# ADR Space — architecture-decisions
# Real props: Status(select), ADR ID(unique_id), Area(multi_select), Created(created_time)
map_schema_adr() {
  local props_json="$1" page_id="$2" notion_url="$3"
  local status adr_number area created
  status=$(printf '%s' "$props_json" | jq -r '.Status.select.name // empty' 2>/dev/null | head -1)
  adr_number=$(printf '%s' "$props_json" | jq -r '."ADR ID".unique_id | (.prefix // "") + "-" + (.number // 0 | tostring)' 2>/dev/null | sed 's/^-//' | head -1)
  area=$(printf '%s' "$props_json" | jq -r '[.Area.multi_select[].name] | join(", ")' 2>/dev/null | head -1)
  created=$(printf '%s' "$props_json" | jq -r '.Created.created_time // empty' 2>/dev/null | head -1 | cut -c1-10)

  jq -n \
    --arg npid "$page_id" \
    --arg nurl "$notion_url" \
    --arg status "$status" \
    --arg adr_number "$adr_number" \
    --arg deciders "$area" \
    --arg decided_at "$created" \
    '{
      notion_page_id: $npid,
      notion_url: $nurl,
      status: (if $status == "" then null else $status end),
      adr_number: (if $adr_number == "" then null else $adr_number end),
      deciders: (if $deciders == "" then null else $deciders end),
      decided_at: (if $decided_at == "" then null else $decided_at end)
    }' 2>/dev/null
}

# Customer Insights — user-feedback
# Empty DB currently — build for schema completeness using any select/multi_select found
map_schema_user_feedback() {
  local props_json="$1" page_id="$2" notion_url="$3"
  local source theme created
  source=$(printf '%s' "$props_json" | jq -r '(.Source // .source // ."Source Type" // empty) | select(.type == "select") | .select.name // empty' 2>/dev/null | head -1)
  theme=$(printf '%s' "$props_json" | jq -r '(.Theme // .theme // .Tags // .tags // empty) | select(.type == "multi_select") | [.multi_select[].name] | join(", ")' 2>/dev/null | head -1)
  created=$(printf '%s' "$props_json" | jq -r '.Created.created_time // ."Created Time".created_time // empty' 2>/dev/null | head -1 | cut -c1-10)

  jq -n \
    --arg npid "$page_id" \
    --arg nurl "$notion_url" \
    --arg source "$source" \
    --arg theme "$theme" \
    --arg captured_at "$created" \
    '{
      notion_page_id: $npid,
      notion_url: $nurl,
      source: (if $source == "" then null else $source end),
      theme: (if $theme == "" then null else $theme end),
      captured_at: (if $captured_at == "" then null else $captured_at end)
    }' 2>/dev/null
}

# Playbooks — feature-specs
# Real props: Status(select), Priority(select), Created(created_time), Last Updated(last_edited_time)
map_schema_feature_specs() {
  local props_json="$1" page_id="$2" notion_url="$3"
  local status priority created last_updated
  status=$(printf '%s' "$props_json" | jq -r '.Status.select.name // empty' 2>/dev/null | head -1)
  priority=$(printf '%s' "$props_json" | jq -r '.Priority.select.name // empty' 2>/dev/null | head -1)
  created=$(printf '%s' "$props_json" | jq -r '.Created.created_time // empty' 2>/dev/null | head -1 | cut -c1-10)
  last_updated=$(printf '%s' "$props_json" | jq -r '."Last Updated".last_edited_time // empty' 2>/dev/null | head -1 | cut -c1-10)

  jq -n \
    --arg npid "$page_id" \
    --arg nurl "$notion_url" \
    --arg status "$status" \
    --arg priority "$priority" \
    --arg created "$created" \
    --arg last_updated "$last_updated" \
    '{
      notion_page_id: $npid,
      notion_url: $nurl,
      status: (if $status == "" then null else $status end),
      trigger: (if $priority == "" then null else $priority end),
      estimated_duration: null,
      owner_role: null,
      last_updated: (if $last_updated == "" then null else $last_updated end)
    }' 2>/dev/null
}

# Playbooks — improvement-proposals (empty DB, generic fallback)
map_schema_improvement_proposals() {
  local props_json="$1" page_id="$2" notion_url="$3"
  local status priority
  status=$(printf '%s' "$props_json" | jq -r '(.Status // .status // empty) | select(.type == "select" or .type == "status") | (.select.name // .status.name) // empty' 2>/dev/null | head -1)
  priority=$(printf '%s' "$props_json" | jq -r '(.Priority // .priority // empty) | select(.type == "select") | .select.name // empty' 2>/dev/null | head -1)

  jq -n \
    --arg npid "$page_id" \
    --arg nurl "$notion_url" \
    --arg status "$status" \
    --arg priority "$priority" \
    '{
      notion_page_id: $npid,
      notion_url: $nurl,
      status: (if $status == "" then null else $status end),
      trigger: (if $priority == "" then null else $priority end),
      owner_role: null,
      estimated_duration: null
    }' 2>/dev/null
}

# Business Brain — child pages (existing behavior extended for DB rows)
# Real props (for DB rows if any): Category(select), Status(select/status),
#   Effective From(date), Last Reviewed(date)
map_schema_business_brain() {
  local props_json="$1" page_id="$2" notion_url="$3"
  local category status effective_from last_reviewed

  category=$(printf '%s' "$props_json" | jq -r '
    (.Category // .category // .Section // .section // empty)
    | select(.type == "select")
    | .select.name // empty
  ' 2>/dev/null | head -1)

  status=$(printf '%s' "$props_json" | jq -r '
    (.Status // .status // empty)
    | select(.type == "status" or .type == "select")
    | (.status.name // .select.name) // empty
  ' 2>/dev/null | head -1)
  [ -z "$status" ] && status="Active"

  effective_from=$(printf '%s' "$props_json" | jq -r '
    (."Effective From" // ."Effective from" // ."Date" // empty)
    | select(.type == "date")
    | .date.start // empty
  ' 2>/dev/null | head -1)

  last_reviewed=$(printf '%s' "$props_json" | jq -r '
    (."Last Reviewed" // ."Last reviewed" // ."Last Review" // empty)
    | select(.type == "date")
    | .date.start // empty
  ' 2>/dev/null | head -1)

  jq -n \
    --arg npid "$page_id" \
    --arg nurl "$notion_url" \
    --arg cat "$category" \
    --arg status "$status" \
    --arg eff "$effective_from" \
    --arg rev "$last_reviewed" \
    '{
      notion_page_id: $npid,
      notion_url: $nurl,
      category: (if $cat == "" then null else $cat end),
      status: $status,
      effective_from: (if $eff == "" then null else $eff end),
      last_reviewed: (if $rev == "" then null else $rev end)
    }' 2>/dev/null
}

# ---------------------------------------------------------------
# Dispatch: pick the right mapper for this slug
# ---------------------------------------------------------------
build_schema_data() {
  local props_json="$1" page_id="$2" notion_url="$3"
  case "$SPACE_SLUG" in
    research-briefs)       map_schema_research_briefs  "$props_json" "$page_id" "$notion_url" ;;
    competitive-intel)     map_schema_competitive_intel "$props_json" "$page_id" "$notion_url" ;;
    market-trends)         map_schema_market_trends    "$props_json" "$page_id" "$notion_url" ;;
    decision-journal)      map_schema_decision_journal "$props_json" "$page_id" "$notion_url" ;;
    decision-queue)        map_schema_decision_queue   "$props_json" "$page_id" "$notion_url" ;;
    architecture-decisions) map_schema_adr             "$props_json" "$page_id" "$notion_url" ;;
    user-feedback)         map_schema_user_feedback    "$props_json" "$page_id" "$notion_url" ;;
    feature-specs)         map_schema_feature_specs    "$props_json" "$page_id" "$notion_url" ;;
    improvement-proposals) map_schema_improvement_proposals "$props_json" "$page_id" "$notion_url" ;;
    business-brain)        map_schema_business_brain   "$props_json" "$page_id" "$notion_url" ;;
    *)                     echo '{}' ;;
  esac
}

# ---------------------------------------------------------------
# Helper: query existing Library record by notion_page_id
# Returns lines: id / title / md5_of_content / md5_of_schema_data — tab-separated
# ---------------------------------------------------------------
find_library_record() {
  local notion_page_id="$1"
  psql "$NEON_CONNECTION_STRING" -q -t -A -F $'\t' \
    -v space_id="$LIBRARY_SPACE_ID" \
    -v notion_page_id="$notion_page_id" \
    2>/dev/null <<'SQLEOF'
SELECT id, title, md5(content_markdown), md5(schema_data::text)
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
    echo "Ensure 'OpenClaw2' integration has access to the page in Notion."
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

  # --- Top-level created_time from Notion page object ---
  NOTION_CREATED_AT=$(printf '%s' "$page_json" | jq -r '.created_time // ""' 2>/dev/null)

  # --- Title ---
  PROPS=$(printf '%s' "$page_json" | jq -c '.properties // {}' 2>/dev/null)
  TITLE=$(get_page_title "$PROPS")

  # --- Notion URL ---
  PAGE_ID_CLEAN="${PAGE_ID//-/}"
  NOTION_URL="https://www.notion.so/${PAGE_ID_CLEAN}"

  # --- Per-slug schema_data ---
  SCHEMA_DATA=$(build_schema_data "$PROPS" "$PAGE_ID" "$NOTION_URL")
  # Validate — fall back to minimal if mapper produced invalid JSON
  if ! printf '%s' "$SCHEMA_DATA" | jq -e . >/dev/null 2>&1; then
    SCHEMA_DATA=$(jq -n --arg npid "$PAGE_ID" --arg nurl "$NOTION_URL" \
      '{notion_page_id: $npid, notion_url: $nurl}')
  fi

  # --- Generic labels: ALL multi_select properties ---
  LABELS_CSV=$(extract_all_labels "$PROPS")

  # --- Body: fetch blocks ---
  sleep 0.3
  BLOCKS_RESP=$(curl -s \
    "https://api.notion.com/v1/blocks/${PAGE_ID}/children?page_size=100" \
    "${NOTION_HEADERS[@]}" 2>/dev/null)

  BLOCKS_OBJ=$(printf '%s' "$BLOCKS_RESP" | jq -r '.object // "error"' 2>/dev/null)
  if [ "$BLOCKS_OBJ" = "error" ]; then
    echo "  WARN: Could not fetch blocks for page '$TITLE' ($PAGE_ID) — using properties fallback"
    BODY=$(properties_to_markdown "$PROPS")
  else
    BLOCKS_JSON=$(printf '%s' "$BLOCKS_RESP" | jq -c '.results // []' 2>/dev/null)
    BLOCK_COUNT=$(printf '%s' "$BLOCKS_JSON" | jq 'length' 2>/dev/null || echo 0)

    if [ "$BLOCK_COUNT" -eq 0 ]; then
      # DB row with no block children — render properties as markdown table
      BODY=$(properties_to_markdown "$PROPS")
    else
      BODY=$(blocks_to_markdown "$BLOCKS_JSON")
    fi
  fi

  # --- Idempotency check ---
  EXISTING=$(find_library_record "$PAGE_ID")
  EXISTING_ID=$(printf '%s' "$EXISTING" | cut -f1)
  EXISTING_TITLE=$(printf '%s' "$EXISTING" | cut -f2)
  EXISTING_MD5=$(printf '%s' "$EXISTING" | cut -f3)
  EXISTING_SCHEMA_MD5=$(printf '%s' "$EXISTING" | cut -f4)

  # Compute md5 of current body and schema_data for comparison
  BODY_MD5=$(printf '%s' "$BODY" | md5sum | awk '{print $1}')
  SCHEMA_MD5=$(printf '%s' "$SCHEMA_DATA" | md5sum | awk '{print $1}')

  if [ -n "$EXISTING_ID" ]; then
    # Record exists — check if title, body, or schema_data changed
    if [ "$EXISTING_TITLE" = "$TITLE" ] && [ "$EXISTING_MD5" = "$BODY_MD5" ] && [ "$EXISTING_SCHEMA_MD5" = "$SCHEMA_MD5" ]; then
      echo "  SKIP (unchanged): $TITLE"
      COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
    else
      echo "  UPDATE: $TITLE"
      library_update_record "$EXISTING_ID" "$TITLE" "$BODY" "$SCHEMA_DATA" "$LABELS_CSV" > /dev/null
      COUNT_UPDATED=$((COUNT_UPDATED + 1))
    fi
  else
    echo "  CREATE: $TITLE"
    library_create_record "$LIBRARY_SPACE_ID" "$TITLE" "$BODY" "$SCHEMA_DATA" "$LABELS_CSV" "" "" "$NOTION_CREATED_AT" > /dev/null
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
