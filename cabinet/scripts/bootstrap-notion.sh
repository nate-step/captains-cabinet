#!/bin/bash
# bootstrap-notion.sh — Creates the canonical Cabinet HQ Notion structure
# and writes all page/database IDs to instance/config/product.yml
#
# Prerequisites:
#   - NOTION_API_KEY set in environment (internal integration token)
#   - Integration has access to your Notion workspace
#   - jq installed
#
# Usage: ./bootstrap-notion.sh [product-name]
# Example: ./bootstrap-notion.sh "Sensed"

set -e

PRODUCT_NAME="${1:-MyProduct}"
NOTION_API_KEY="${NOTION_API_KEY:?Set NOTION_API_KEY before running this script}"
API_BASE="https://api.notion.com/v1"
NOTION_VERSION="2022-06-28"
CONFIG_FILE="instance/config/product.yml"

# Common headers
AUTH_HEADER="Authorization: Bearer $NOTION_API_KEY"
VERSION_HEADER="Notion-Version: $NOTION_VERSION"
CONTENT_TYPE="Content-Type: application/json"

echo "============================================"
echo " Founder's Cabinet — Notion Bootstrap"
echo " Product: $PRODUCT_NAME"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"
echo ""

# ============================================================
# Helper: Create a page and return its ID
# ============================================================
create_page() {
  local parent_id="$1"
  local title="$2"
  local icon="$3"
  local content="$4"

  local body
  if [ -n "$parent_id" ]; then
    body=$(jq -n \
      --arg title "$title" \
      --arg icon "$icon" \
      --arg parent "$parent_id" \
      '{
        parent: { page_id: $parent },
        icon: { type: "emoji", emoji: $icon },
        properties: { title: { title: [{ text: { content: $title } }] } },
        children: []
      }')
  else
    body=$(jq -n \
      --arg title "$title" \
      --arg icon "$icon" \
      '{
        parent: { type: "workspace", workspace: true },
        icon: { type: "emoji", emoji: $icon },
        properties: { title: { title: [{ text: { content: $title } }] } },
        children: []
      }')
  fi

  local response
  response=$(curl -s -X POST "$API_BASE/pages" \
    -H "$AUTH_HEADER" -H "$VERSION_HEADER" -H "$CONTENT_TYPE" \
    -d "$body")

  echo "$response" | jq -r '.id'
}

# ============================================================
# Helper: Create a database and return its ID
# ============================================================
create_database() {
  local parent_id="$1"
  local title="$2"
  local properties_json="$3"

  local body
  body=$(jq -n \
    --arg title "$title" \
    --arg parent "$parent_id" \
    --argjson props "$properties_json" \
    '{
      parent: { page_id: $parent },
      title: [{ text: { content: $title } }],
      properties: $props
    }')

  local response
  response=$(curl -s -X POST "$API_BASE/databases" \
    -H "$AUTH_HEADER" -H "$VERSION_HEADER" -H "$CONTENT_TYPE" \
    -d "$body")

  echo "$response" | jq -r '.id'
}

# ============================================================
# Create the structure
# ============================================================

echo "Creating Cabinet HQ..."
CABINET_HQ=$(create_page "" "Cabinet HQ" "🏛️" "")
echo "  Cabinet HQ: $CABINET_HQ"

echo "Creating sections..."
DASHBOARD=$(create_page "$CABINET_HQ" "Captain's Dashboard" "📋" "")
echo "  Dashboard: $DASHBOARD"

BUSINESS_BRAIN=$(create_page "$CABINET_HQ" "Business Brain" "🧠" "")
echo "  Business Brain: $BUSINESS_BRAIN"

RESEARCH_HUB=$(create_page "$CABINET_HQ" "Research Hub" "🔬" "")
echo "  Research Hub: $RESEARCH_HUB"

PRODUCT_HUB=$(create_page "$CABINET_HQ" "Product Hub" "📦" "")
echo "  Product Hub: $PRODUCT_HUB"

ENGINEERING_HUB=$(create_page "$CABINET_HQ" "Engineering Hub" "🔧" "")
echo "  Engineering Hub: $ENGINEERING_HUB"

CABINET_OPS=$(create_page "$CABINET_HQ" "Cabinet Operations" "📓" "")
echo "  Cabinet Operations: $CABINET_OPS"

REFERENCE=$(create_page "$CABINET_HQ" "Reference" "📚" "")
echo "  Reference: $REFERENCE"

ARCHIVE=$(create_page "$CABINET_HQ" "Archive" "🗄️" "")
echo "  Archive: $ARCHIVE"

# Starter pages under Business Brain
echo "Creating Business Brain pages..."
VISION=$(create_page "$BUSINESS_BRAIN" "Vision & North Star" "⭐" "")
echo "  Vision: $VISION"

# ============================================================
# Create databases
# ============================================================
echo ""
echo "Creating databases..."

# Simple title-only properties for all DBs (Notion API requires at least a title)
TITLE_PROP='{"Name": {"title": {}}}'

# Decision Queue
DECISION_QUEUE_DB=$(create_database "$DASHBOARD" "Decision Queue" \
  '{"Decision":{"title":{}},"Status":{"select":{"options":[{"name":"Pending","color":"yellow"},{"name":"Decided","color":"green"},{"name":"Deferred","color":"gray"}]}},"Priority":{"select":{"options":[{"name":"Urgent","color":"red"},{"name":"Normal","color":"default"},{"name":"Low","color":"gray"}]}}}')
echo "  Decision Queue: $DECISION_QUEUE_DB"

# Daily Briefings
BRIEFINGS_DB=$(create_database "$DASHBOARD" "Daily Briefings" \
  '{"Briefing":{"title":{}},"Type":{"select":{"options":[{"name":"Morning","color":"yellow"},{"name":"Evening","color":"blue"}]}},"Date":{"date":{}}}')
echo "  Daily Briefings: $BRIEFINGS_DB"

# Weekly Reports
REPORTS_DB=$(create_database "$DASHBOARD" "Weekly Reports" \
  '{"Report":{"title":{}},"Week":{"date":{}}}')
echo "  Weekly Reports: $REPORTS_DB"

# Research Briefs
RESEARCH_BRIEFS_DB=$(create_database "$RESEARCH_HUB" "Research Briefs" \
  '{"Brief":{"title":{}},"Topic":{"select":{"options":[{"name":"Market","color":"blue"},{"name":"Competitive","color":"red"},{"name":"User Research","color":"green"},{"name":"Trends","color":"purple"}]}},"Impact":{"select":{"options":[{"name":"High","color":"red"},{"name":"Medium","color":"yellow"},{"name":"Low","color":"gray"}]}}}')
echo "  Research Briefs: $RESEARCH_BRIEFS_DB"

# Competitive Intelligence
COMPETITIVE_DB=$(create_database "$RESEARCH_HUB" "Competitive Intelligence" \
  '{"Competitor":{"title":{}},"Category":{"select":{"options":[{"name":"Direct","color":"red"},{"name":"Adjacent","color":"orange"},{"name":"Emerging","color":"yellow"}]}},"Threat Level":{"select":{"options":[{"name":"High","color":"red"},{"name":"Medium","color":"yellow"},{"name":"Low","color":"green"}]}}}')
echo "  Competitive Intel: $COMPETITIVE_DB"

# Market Trends
TRENDS_DB=$(create_database "$RESEARCH_HUB" "Market Trends" \
  '{"Trend":{"title":{}},"Category":{"select":{"options":[{"name":"Technology","color":"blue"},{"name":"Market","color":"green"},{"name":"Regulatory","color":"red"},{"name":"Cultural","color":"purple"}]}},"Relevance":{"select":{"options":[{"name":"High","color":"red"},{"name":"Medium","color":"yellow"},{"name":"Watch","color":"gray"}]}}}')
echo "  Market Trends: $TRENDS_DB"

# Product Roadmap
ROADMAP_DB=$(create_database "$PRODUCT_HUB" "Product Roadmap" \
  '{"Milestone":{"title":{}},"Status":{"select":{"options":[{"name":"Planned","color":"gray"},{"name":"In Progress","color":"blue"},{"name":"Shipped","color":"green"},{"name":"Cut","color":"red"}]}},"Target":{"date":{}}}')
echo "  Product Roadmap: $ROADMAP_DB"

# Feature Specs
SPECS_DB=$(create_database "$PRODUCT_HUB" "Feature Specs" \
  '{"Spec":{"title":{}},"Status":{"select":{"options":[{"name":"Draft","color":"gray"},{"name":"Ready","color":"blue"},{"name":"In Build","color":"yellow"},{"name":"Shipped","color":"green"},{"name":"Rejected","color":"red"}]}},"Priority":{"select":{"options":[{"name":"P0 - Now","color":"red"},{"name":"P1 - Next","color":"orange"},{"name":"P2 - Later","color":"gray"}]}}}')
echo "  Feature Specs: $SPECS_DB"

# User Feedback
FEEDBACK_DB=$(create_database "$PRODUCT_HUB" "User Feedback" \
  '{"Feedback":{"title":{}},"Source":{"select":{"options":[{"name":"Direct","color":"blue"},{"name":"App Review","color":"green"},{"name":"Social","color":"purple"},{"name":"Support","color":"orange"}]}},"Sentiment":{"select":{"options":[{"name":"Positive","color":"green"},{"name":"Neutral","color":"gray"},{"name":"Negative","color":"red"}]}}}')
echo "  User Feedback: $FEEDBACK_DB"

# Architecture Decisions
ADR_DB=$(create_database "$ENGINEERING_HUB" "Architecture Decisions" \
  '{"Decision":{"title":{}},"Status":{"select":{"options":[{"name":"Proposed","color":"yellow"},{"name":"Accepted","color":"green"},{"name":"Superseded","color":"gray"},{"name":"Rejected","color":"red"}]}}}')
echo "  Architecture Decisions: $ADR_DB"

# Tech Debt Register
DEBT_DB=$(create_database "$ENGINEERING_HUB" "Tech Debt Register" \
  '{"Debt":{"title":{}},"Severity":{"select":{"options":[{"name":"Critical","color":"red"},{"name":"High","color":"orange"},{"name":"Medium","color":"yellow"},{"name":"Low","color":"gray"}]}},"Status":{"select":{"options":[{"name":"Identified","color":"gray"},{"name":"Planned","color":"blue"},{"name":"Resolved","color":"green"}]}}}')
echo "  Tech Debt: $DEBT_DB"

# Decision Journal
JOURNAL_DB=$(create_database "$CABINET_OPS" "Decision Journal" \
  '{"Decision":{"title":{}},"Domain":{"select":{"options":[{"name":"Product","color":"orange"},{"name":"Engineering","color":"purple"},{"name":"Research","color":"green"},{"name":"Organization","color":"blue"},{"name":"Business","color":"red"}]}},"Decided":{"date":{}}}')
echo "  Decision Journal: $JOURNAL_DB"

# Improvement Proposals
PROPOSALS_DB=$(create_database "$CABINET_OPS" "Improvement Proposals" \
  '{"Proposal":{"title":{}},"Type":{"select":{"options":[{"name":"Constitution Amendment","color":"red"},{"name":"New Skill","color":"blue"},{"name":"Role Change","color":"purple"},{"name":"Process Change","color":"green"}]}},"Status":{"select":{"options":[{"name":"Proposed","color":"yellow"},{"name":"Validating","color":"blue"},{"name":"Approved","color":"green"},{"name":"Rejected","color":"red"},{"name":"Reverted","color":"gray"}]}}}')
echo "  Improvement Proposals: $PROPOSALS_DB"

# ============================================================
# Write instance/config/product.yml
# ============================================================
echo ""
echo "Writing $CONFIG_FILE..."

mkdir -p "$(dirname "$CONFIG_FILE")"

cat > "$CONFIG_FILE" << YAML
# =============================================================
# Founder's Cabinet — Product Configuration
# =============================================================
# Auto-generated by bootstrap-notion.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Product: $PRODUCT_NAME
# =============================================================

product:
  name: "$PRODUCT_NAME"
  description: ""  # TODO: fill in your product description
  repo: ""  # TODO: e.g. https://github.com/your-org/your-product
  repo_branch: main
  mount_path: /workspace/product

# =============================================================
# Notion — Business Brain
# =============================================================
notion:
  cabinet_hq_id: $CABINET_HQ

  dashboard:
    page_id: $DASHBOARD
    decision_queue_db: $DECISION_QUEUE_DB
    daily_briefings_db: $BRIEFINGS_DB
    weekly_reports_db: $REPORTS_DB

  business_brain:
    page_id: $BUSINESS_BRAIN
    vision_id: $VISION

  research_hub:
    page_id: $RESEARCH_HUB
    research_briefs_db: $RESEARCH_BRIEFS_DB
    competitive_intel_db: $COMPETITIVE_DB
    market_trends_db: $TRENDS_DB

  product_hub:
    page_id: $PRODUCT_HUB
    product_roadmap_db: $ROADMAP_DB
    feature_specs_db: $SPECS_DB
    user_feedback_db: $FEEDBACK_DB

  engineering_hub:
    page_id: $ENGINEERING_HUB
    architecture_decisions_db: $ADR_DB
    tech_debt_db: $DEBT_DB

  cabinet_ops:
    page_id: $CABINET_OPS
    decision_journal_db: $JOURNAL_DB
    improvement_proposals_db: $PROPOSALS_DB

  reference:
    page_id: $REFERENCE

  archive:
    page_id: $ARCHIVE

# =============================================================
# Linear — Execution Backlog
# =============================================================
linear:
  team_key: ""  # TODO: your Linear team key
  workspace_url: ""  # TODO: e.g. https://linear.app/your-team

# =============================================================
# Neon — Product Database
# =============================================================
neon:
  project: ""  # TODO: your Neon project name

# =============================================================
# Telegram — Captain Communication
# =============================================================
telegram:
  officers:
    cos: ""  # TODO: your_cos_bot username
    cto: ""  # TODO: your_cto_bot username
    cro: ""  # TODO: your_cro_bot username
    cpo: ""  # TODO: your_cprod_bot username

# =============================================================
# Research APIs
# =============================================================
research:
  apis:
    - perplexity
    - brave
    - exa

# =============================================================
# Embeddings
# =============================================================
embeddings:
  provider: voyage
  models:
    storage: voyage-4-large
    query: voyage-4-lite
  dimensions: 1024
YAML

echo ""
echo "============================================"
echo " Bootstrap complete!"
echo ""
echo " Notion structure created under: Cabinet HQ"
echo " Config written to: $CONFIG_FILE"
echo ""
echo " Next steps:"
echo "   1. Open Notion and verify the structure"
echo "   2. Fill in the TODO fields in $CONFIG_FILE"
echo "   3. Add your strategy docs to Business Brain"
echo "   4. Continue with PHASE0_GUIDE.md"
echo "============================================"
