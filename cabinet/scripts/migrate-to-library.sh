#!/bin/bash
# migrate-to-library.sh — Bulk markdown → Library importer (FW-024 Phase 1)
#
# Walks known shared/ + instance/memory/tier2/ markdown paths and creates
# Library records in auto-derived Spaces.  Idempotent: keyed on source_path
# stored in schema_data.  Does NOT touch hooks or write-paths (Phase 2).
#
# Usage:
#   bash cabinet/scripts/migrate-to-library.sh [--dry-run] [--apply]
#                                               [--space <slug>] [--force]
#
# Flags:
#   --dry-run (default) — print what would be imported; no writes
#   --apply             — actually create Library records
#   --space <slug>      — restrict to one space slug (e.g. product-specs)
#   --force             — re-import even if source_path already exists
#
# Space slug ↔ path convention:
#   product-specs       ← shared/interfaces/product-specs/*.md
#   shared-interfaces   ← shared/interfaces/*.md  (flat files only)
#   backlog             ← shared/backlog.md
#   framework-backlog   ← shared/cabinet-framework-backlog.md
#   tier2-<officer>     ← instance/memory/tier2/<officer>/*.md
#   (all others printed as [SKIP])
#
# Migration ledger: shared/migration-ledger.md  (append-only; every run)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ── Load env + library helpers ───────────────────────────────────────────────
set -a
source "${SCRIPT_DIR}/../.env" 2>/dev/null || true
set +a

source "${SCRIPT_DIR}/lib/library.sh" 2>/dev/null

# ── Argument parsing ─────────────────────────────────────────────────────────
DRY_RUN=true
SPACE_FILTER=""
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=true  ; shift ;;
    --apply)    DRY_RUN=false ; shift ;;
    --force)    FORCE=true    ; shift ;;
    --space)
      SPACE_FILTER="${2:-}"
      shift 2
      ;;
    --space=*)
      SPACE_FILTER="${1#*=}"
      shift
      ;;
    *)
      echo "Unknown flag: $1" >&2
      echo "Usage: migrate-to-library.sh [--dry-run|--apply] [--space <slug>] [--force]" >&2
      exit 1
      ;;
  esac
done

# ── Ledger ────────────────────────────────────────────────────────────────────
LEDGER="${REPO_ROOT}/shared/migration-ledger.md"

# Bootstrap ledger header if it doesn't exist yet
if [ ! -f "$LEDGER" ]; then
  {
    echo "# Migration Ledger"
    echo ""
    echo "Append-only audit trail for \`migrate-to-library.sh\` runs (FW-024)."
    echo ""
    echo "| timestamp | source_path | space | record_id | status |"
    echo "|-----------|-------------|-------|-----------|--------|"
  } > "$LEDGER"
fi

# Append one row to the ledger (even in dry-run mode, for audit)
ledger_append() {
  local ts="$1" src="$2" space="$3" rid="$4" status="$5"
  printf "| %s | %s | %s | %s | %s |\n" \
    "$ts" "$src" "$space" "$rid" "$status" >> "$LEDGER"
}

# ── Preflight ────────────────────────────────────────────────────────────────
if [ -z "${NEON_CONNECTION_STRING:-}" ]; then
  echo "ERROR: NEON_CONNECTION_STRING not set. Check cabinet/.env" >&2
  exit 1
fi

echo "migrate-to-library.sh — FW-024 Phase 1"
echo "Mode   : $( $DRY_RUN && echo "DRY RUN (no writes)" || echo "APPLY" )"
echo "Space  : ${SPACE_FILTER:-all}"
echo "Force  : $FORCE"
echo "Ledger : $LEDGER"
echo "────────────────────────────────────────────────────────────────"

# ── Frontmatter parser ───────────────────────────────────────────────────────
# Reads a markdown file; sets title, tags_csv, status_val, date_val
# Extracts YAML frontmatter if present (between leading --- lines).
# Falls back to first H1 heading for title; empty tags.
parse_markdown_meta() {
  local file="$1"
  title=""
  tags_csv=""
  status_val=""
  date_val=""

  # Check for YAML frontmatter (file must start with ---)
  local first_line
  first_line=$(head -1 "$file" 2>/dev/null)
  if [ "$first_line" = "---" ]; then
    # Extract the frontmatter block (lines between first and second ---)
    local fm
    fm=$(awk 'NR>1 { if (/^---$/) exit; print }' "$file" 2>/dev/null)

    # Parse individual fields with awk (handles "key: value" and "key: 'value'" forms)
    title=$(echo "$fm" | awk -F': ' '/^title:/ { sub(/^title:[[:space:]]*/, ""); gsub(/^["\047]|["\047]$/, ""); print; exit }')
    status_val=$(echo "$fm" | awk -F': ' '/^status:/ { sub(/^status:[[:space:]]*/, ""); gsub(/^["\047]|["\047]$/, ""); print; exit }')
    date_val=$(echo "$fm" | awk -F': ' '/^date:/ { sub(/^date:[[:space:]]*/, ""); gsub(/^["\047]|["\047]$/, ""); print; exit }')

    # Tags: support both "tags: [a, b]" and multi-line "- item" forms
    # Inline array form: tags: [a, b, c]
    local raw_tags
    raw_tags=$(echo "$fm" | awk '/^tags:/ { sub(/^tags:[[:space:]]*/, ""); print; exit }')
    if echo "$raw_tags" | grep -q '^\['; then
      # Strip brackets + spaces → CSV
      tags_csv=$(echo "$raw_tags" | tr -d '[]' | tr ',' '\n' | awk '{$1=$1};1' | tr '\n' ',' | sed 's/,$//')
    else
      # Multi-line block form: lines after "tags:" that start with "- "
      tags_csv=$(echo "$fm" | awk '/^tags:/{found=1;next} found && /^- /{sub(/^- /,""); print} found && !/^- /{exit}' \
        | tr '\n' ',' | sed 's/,$//')
    fi
  fi

  # Fallback: derive title from first H1 if frontmatter didn't provide one
  if [ -z "$title" ]; then
    title=$(grep -m1 '^# ' "$file" 2>/dev/null | sed 's/^# //')
  fi

  # Final fallback: basename without extension
  if [ -z "$title" ]; then
    title=$(basename "$file" .md)
  fi
}

# ── Space resolver ────────────────────────────────────────────────────────────
# Given a file's relative-to-REPO_ROOT path, returns the space slug.
# Returns empty string for no-match (caller prints [SKIP]).
derive_space_slug() {
  local rel="$1"   # e.g. shared/interfaces/product-specs/001-foo.md

  case "$rel" in
    shared/interfaces/product-specs/*.md)
      echo "product-specs" ;;
    shared/interfaces/*.md)
      # Flat files directly under shared/interfaces/ (captain-decisions, tech-radar, etc.)
      # Exclude sub-directories already matched above
      echo "shared-interfaces" ;;
    shared/backlog.md)
      echo "backlog" ;;
    shared/cabinet-framework-backlog.md)
      echo "framework-backlog" ;;
    instance/memory/tier2/*/*)
      # e.g. instance/memory/tier2/cos/working-notes.md → tier2-cos
      local officer
      officer=$(echo "$rel" | awk -F'/' '{print $4}')
      echo "tier2-${officer}" ;;
    *)
      echo "" ;;
  esac
}

# ── Library Space ensurer ─────────────────────────────────────────────────────
# Creates a Library Space by slug-derived name if it doesn't exist.
# Returns space_id on stdout.
ensure_space() {
  local slug="$1"
  # Convert slug to a display name (e.g. product-specs → Product Specs)
  local display_name
  display_name=$(echo "$slug" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2)); print}')

  # library_space_id returns id or empty
  local sid
  sid=$(library_space_id "$display_name")
  if [ -n "$sid" ]; then
    echo "$sid"
    return
  fi

  # Space doesn't exist — create it
  sid=$(library_create_space \
    "$display_name" \
    "Auto-created by migrate-to-library.sh (FW-024) for path convention: $slug" \
    '{}' \
    'blank' \
    'system' \
    '{}')
  echo "$sid"
}

# ── Idempotency check ─────────────────────────────────────────────────────────
# Returns record id if a non-superseded record with matching source_path exists.
find_by_source_path() {
  local source_path="$1"
  psql "$NEON_CONNECTION_STRING" -q -t -A \
    -v source_path="$source_path" \
    2>/dev/null <<'SQL'
SELECT id
FROM library_records
WHERE superseded_by IS NULL
  AND schema_data->>'source_path' = :'source_path'
LIMIT 1;
SQL
}

# ── File collector ────────────────────────────────────────────────────────────
# Build array of relative paths to process
collect_files() {
  local files=()

  # shared/interfaces/product-specs/*.md
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "${REPO_ROOT}/shared/interfaces/product-specs" -maxdepth 1 -name '*.md' | \
           sed "s|${REPO_ROOT}/||" | sort)

  # shared/interfaces/*.md (flat only — not subdirs)
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "${REPO_ROOT}/shared/interfaces" -maxdepth 1 -name '*.md' | \
           sed "s|${REPO_ROOT}/||" | sort)

  # shared/backlog.md + shared/cabinet-framework-backlog.md
  for flat in shared/backlog.md shared/cabinet-framework-backlog.md; do
    [ -f "${REPO_ROOT}/${flat}" ] && files+=("$flat")
  done

  # instance/memory/tier2/<officer>/*.md (direct children only)
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "${REPO_ROOT}/instance/memory/tier2" -maxdepth 2 -name '*.md' | \
           sed "s|${REPO_ROOT}/||" | sort)

  printf '%s\n' "${files[@]}"
}

# ── Counters ──────────────────────────────────────────────────────────────────
count_import=0
count_skip=0
count_no_mapping=0
count_error=0
count_space_filtered=0

# ── Main loop ─────────────────────────────────────────────────────────────────
echo ""
while IFS= read -r rel_path; do
  [ -z "$rel_path" ] && continue

  abs_path="${REPO_ROOT}/${rel_path}"
  [ -f "$abs_path" ] || continue

  # Derive space slug
  slug=$(derive_space_slug "$rel_path")

  if [ -z "$slug" ]; then
    echo "[SKIP]        $rel_path — no space mapping, add one in script to include"
    (( count_no_mapping++ )) || true
    continue
  fi

  # Apply --space filter
  if [ -n "$SPACE_FILTER" ] && [ "$slug" != "$SPACE_FILTER" ]; then
    (( count_space_filtered++ )) || true
    continue
  fi

  # Parse metadata
  parse_markdown_meta "$abs_path"
  local_title="$title"
  local_tags="$tags_csv"
  local_status="$status_val"
  local_date="$date_val"

  if $DRY_RUN; then
    printf "[WOULD IMPORT] %s → space=%s title=%s\n" "$rel_path" "$slug" "$local_title"
    (( count_import++ )) || true
    continue
  fi

  # ── Live write path ───────────────────────────────────────────────────────
  ts_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Check idempotency
  existing_id=$(find_by_source_path "$rel_path")
  if [ -n "$existing_id" ] && ! $FORCE; then
    echo "[SKIP]        $rel_path — already imported (record $existing_id)"
    ledger_append "$ts_now" "$rel_path" "$slug" "$existing_id" "skipped"
    (( count_skip++ )) || true
    continue
  fi

  # Ensure space exists (create if needed)
  space_id=$(ensure_space "$slug") || {
    echo "[ERROR]       $rel_path — could not ensure space $slug" >&2
    ledger_append "$ts_now" "$rel_path" "$slug" "" "error:space_creation_failed"
    (( count_error++ )) || true
    continue
  }

  if [ -z "$space_id" ]; then
    echo "[ERROR]       $rel_path — space_id empty for slug $slug" >&2
    ledger_append "$ts_now" "$rel_path" "$slug" "" "error:empty_space_id"
    (( count_error++ )) || true
    continue
  fi

  # Read file content
  content=$(cat "$abs_path" 2>/dev/null || true)

  # Build schema_data JSON preserving source metadata
  schema_data=$(jq -n \
    --arg source_path "$rel_path" \
    --arg status "$local_status" \
    --arg date_val "$local_date" \
    '{
      source_path: $source_path,
      status: (if $status == "" then null else $status end),
      source_date: (if $date_val == "" then null else $date_val end)
    }')

  # Determine created_at override from frontmatter date
  source_created_at=""
  if [ -n "$local_date" ]; then
    # Validate it looks like an ISO date before passing
    if echo "$local_date" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
      source_created_at="${local_date}T00:00:00Z"
    fi
  fi

  # Create (or re-create with --force) the record
  # If forcing and record exists, soft-delete old then create fresh
  if [ -n "$existing_id" ] && $FORCE; then
    echo "[FORCE]       $rel_path — superseding record $existing_id"
    library_delete_record "$existing_id" 2>/dev/null || true
  fi

  new_id=$(library_create_record \
    "$space_id" \
    "$local_title" \
    "$content" \
    "$schema_data" \
    "$local_tags" \
    "" \
    "" \
    "$source_created_at") || {
      echo "[ERROR]       $rel_path — library_create_record failed" >&2
      ledger_append "$ts_now" "$rel_path" "$slug" "" "error:create_failed"
      (( count_error++ )) || true
      continue
    }

  if [ -z "$new_id" ]; then
    echo "[ERROR]       $rel_path — got empty record_id from library_create_record" >&2
    ledger_append "$ts_now" "$rel_path" "$slug" "" "error:empty_record_id"
    (( count_error++ )) || true
    continue
  fi

  echo "[IMPORTED]    $rel_path → space=$slug record_id=$new_id title=\"$local_title\""
  ledger_append "$ts_now" "$rel_path" "$slug" "$new_id" "imported"
  (( count_import++ )) || true

  # Courtesy rate-limit: 100ms between writes (Voyage embedding calls)
  sleep 0.1

done < <(collect_files)

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
if $DRY_RUN; then
  echo "DRY RUN complete — would import $count_import file(s)"
  [ "$count_no_mapping" -gt 0 ] && echo "  Skipped (no mapping) : $count_no_mapping"
  [ "$count_space_filtered" -gt 0 ] && echo "  Filtered by --space  : $count_space_filtered"
  echo "Run with --apply to write to Library."
else
  echo "Import complete:"
  echo "  Imported : $count_import"
  echo "  Skipped  : $count_skip (already present; use --force to re-import)"
  echo "  Errors   : $count_error"
  [ "$count_no_mapping" -gt 0 ] && echo "  No mapping: $count_no_mapping (use [SKIP] lines above to add path rules)"
fi
echo "════════════════════════════════════════════════════════════════"

exit 0
