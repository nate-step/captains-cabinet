#!/bin/bash
# backfill-memory.sh — One-time backfill of existing data into cabinet_memory
# Sources: experience_records, cabinet_research (both from internal PG),
#          captain-decisions.md, framework files (CLAUDE.md, agent defs, guide)

set -uo pipefail
# Auto-export env vars so subshells (pipes) inherit them
set -a
source /opt/founders-cabinet/cabinet/.env 2>/dev/null
set +a
source /opt/founders-cabinet/cabinet/scripts/lib/memory.sh

# Fail fast if required env is missing (prevents silent queue of unembeddable items)
: "${NEON_CONNECTION_STRING:?NEON_CONNECTION_STRING is required}"
: "${VOYAGE_API_KEY:?VOYAGE_API_KEY is required}"
: "${REDIS_HOST:=redis}"
: "${REDIS_PORT:=6379}"

log() { echo "[backfill $(date -u +%H:%M:%S)] $1"; }

# =============================================================
# 1. Experience records — queue for re-embedding (table has content but no embeddings)
# =============================================================
log "Queueing experience_records for embedding..."
EXP_COUNT=0
while IFS=$'\t' read -r rec_id officer summary outcome happened lessons created tags_str; do
  [ -z "$rec_id" ] && continue
  content="[${outcome}] ${summary}

${happened}

Lessons: ${lessons}"
  metadata=$(jq -nc --arg outcome "$outcome" --arg tags "$tags_str" '{outcome: $outcome, tags: $tags}')
  memory_queue_embed "experience_record" "exp-$rec_id" "$officer" "" "$content" "$metadata" "$created"
  EXP_COUNT=$((EXP_COUNT+1))
done < <(psql "$DATABASE_URL" -t -A -F $'\t' -c "
  SELECT id, officer, task_summary, outcome, what_happened, lessons_learned, created_at, tags::text
  FROM experience_records
  ORDER BY created_at DESC
" 2>/dev/null)
log "experience_records: queued $EXP_COUNT for embedding"

# =============================================================
# 2. Research briefs (embeddings already exist)
# =============================================================
log "Backfilling cabinet_research..."
psql "$DATABASE_URL" -t -A -F '|' -c "
  SELECT id, officer, title, content, summary, created_at, tags::text, embedding::text
  FROM cabinet_research
  WHERE embedding IS NOT NULL
  ORDER BY created_at
  LIMIT 100
" 2>/dev/null | while IFS='|' read -r rec_id officer title content summary created tags_str embedding; do
  [ -z "$rec_id" ] && continue
  metadata=$(jq -nc --arg title "$title" --arg tags "$tags_str" '{title: $title, tags: $tags}')

  psql "$NEON_CONNECTION_STRING" -q \
    -v source_type="research_brief" \
    -v source_id="rb-$rec_id" \
    -v officer="$officer" \
    -v content="$content" \
    -v summary="$summary" \
    -v embedding="$embedding" \
    -v metadata="$metadata" \
    -v source_ts="$created" \
    2>/dev/null <<'SQLEOF' > /dev/null
INSERT INTO cabinet_memory (source_type, source_id, officer, content, summary, embedding, metadata, source_created_at)
VALUES (:'source_type', :'source_id', :'officer', :'content', :'summary', :'embedding'::vector, :'metadata'::jsonb, :'source_ts'::timestamptz)
ON CONFLICT (source_type, source_id) WHERE source_id IS NOT NULL AND superseded_by IS NULL
DO NOTHING;
SQLEOF
done
log "cabinet_research: backfilled"

# =============================================================
# 3. Framework files — universal set (CLAUDE.md, agents, constitution, officer CLAUDE.md)
# =============================================================
log "Queueing framework files..."
FW_COUNT=0
queue_file() {
  local f="$1" source_type="$2"
  [ ! -f "$f" ] && return
  local content
  content=$(cat "$f")
  [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ] && return
  local rel_path="${f#/opt/founders-cabinet/}"
  local mtime
  mtime=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  memory_queue_embed "$source_type" "$rel_path" "system" "" "$content" "{}" "$mtime" && FW_COUNT=$((FW_COUNT+1))
}

for f in /opt/founders-cabinet/CLAUDE.md \
         /opt/founders-cabinet/founders-cabinet-guide.md \
         /opt/founders-cabinet/.claude/agents/*.md \
         /opt/founders-cabinet/constitution/*.md \
         /opt/founders-cabinet/officers/*/CLAUDE.md; do
  queue_file "$f" "framework_file"
done
log "framework files queued: $FW_COUNT"

# =============================================================
# 3b. Shared interfaces — tech radar, backlog, working notes
# =============================================================
log "Queueing shared interfaces..."
SI_COUNT=0
for f in /opt/founders-cabinet/shared/backlog.md \
         /opt/founders-cabinet/shared/interfaces/tech-radar.md \
         /opt/founders-cabinet/memory/tier2/*/working-notes.md; do
  if [ -f "$f" ]; then
    content=$(cat "$f")
    [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ] && continue
    rel_path="${f#/opt/founders-cabinet/}"
    mtime=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    # tech-radar → tech_radar; backlog → working_note; working-notes → working_note
    case "$rel_path" in
      *tech-radar.md)  st="tech_radar" ;;
      *backlog.md)     st="working_note" ;;
      *working-notes.md) st="working_note" ;;
      *) st="working_note" ;;
    esac
    memory_queue_embed "$st" "$rel_path" "system" "" "$content" "{}" "$mtime" && SI_COUNT=$((SI_COUNT+1))
  fi
done
log "shared interfaces queued: $SI_COUNT"

# =============================================================
# 3c. Product specs (if directory exists)
# =============================================================
log "Queueing product specs..."
SPEC_COUNT=0
if [ -d /opt/founders-cabinet/shared/interfaces/product-specs ]; then
  for f in /opt/founders-cabinet/shared/interfaces/product-specs/*.md; do
    [ ! -f "$f" ] && continue
    content=$(cat "$f")
    [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ] && continue
    rel_path="${f#/opt/founders-cabinet/}"
    mtime=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    memory_queue_embed "product_spec" "$rel_path" "system" "" "$content" "{}" "$mtime" && SPEC_COUNT=$((SPEC_COUNT+1))
  done
fi
log "product specs queued: $SPEC_COUNT"

# =============================================================
# 4. Captain decisions (parse markdown table)
# =============================================================
log "Queueing captain decisions..."
DEC_FILE="/opt/founders-cabinet/shared/interfaces/captain-decisions.md"
if [ -f "$DEC_FILE" ]; then
  # Parse markdown table rows
  row_num=0
  while IFS='|' read -r _ date decision why affected _; do
    date=$(echo "$date" | xargs)
    decision=$(echo "$decision" | xargs)
    why=$(echo "$why" | xargs)
    affected=$(echo "$affected" | xargs)
    # Skip non-data rows
    [[ ! "$date" =~ ^2026- ]] && continue
    content="Decision: $decision | Why: $why | Affected: $affected"
    row_num=$((row_num+1))
    memory_queue_embed "captain_decision" "cd-${date}-${row_num}" "captain" "captain" "$content" "$(jq -nc --arg date "$date" --arg affected "$affected" '{date: $date, affected: $affected}')" "${date}T00:00:00Z"
  done < "$DEC_FILE"
  log "captain decisions queued"
fi

# =============================================================
# 5. Skills
# =============================================================
log "Queueing skills..."
for f in /opt/founders-cabinet/memory/skills/*.md; do
  [ ! -f "$f" ] && continue
  [[ "$(basename $f)" == TEMPLATE* ]] && continue
  content=$(cat "$f")
  rel_path=${f#/opt/founders-cabinet/}
  mtime=$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  memory_queue_embed "skill" "$rel_path" "system" "" "$content" "{}" "$mtime"
done
log "skills queued"

log "Done queueing. Run: bash cabinet/scripts/memory-worker.sh --once  (repeat until queue is empty)"
