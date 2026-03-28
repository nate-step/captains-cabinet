#!/bin/bash
# record-experience.sh — Write an experience record to Tier 3 + PostgreSQL
# Called by Officers after completing any significant task.
#
# Usage: record-experience.sh <officer> <outcome> <task_summary> <what_happened> [lessons_learned] [tags]
#   outcome: success | failure | partial | escalated
#   tags: comma-separated, e.g. "git,deployment,migration"
#
# Example:
#   record-experience.sh cto success "Fix migration drift" \
#     "Renumbered 3 colliding migration pairs, ran all migrations, verified 11 tables created" \
#     "Always check migration numbering before adding new migrations" \
#     "database,migrations,schema"

OFFICER="${1:?Usage: record-experience.sh <officer> <outcome> <task> <what_happened> [lessons] [tags]}"
OUTCOME="${2:?Outcome required: success|failure|partial|escalated}"
TASK_SUMMARY="${3:?Task summary required}"
WHAT_HAPPENED="${4:?Description of what happened required}"
LESSONS="${5:-}"
TAGS="${6:-}"

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DATE=$(date -u +%Y-%m-%d)
RECORD_ID=$(date +%s)-$$

# Validate outcome
case "$OUTCOME" in
  success|failure|partial|escalated) ;;
  *) echo "Invalid outcome: $OUTCOME (must be success|failure|partial|escalated)"; exit 1 ;;
esac

# ============================================================
# 1. Write markdown file to Tier 3 (filesystem)
# ============================================================
RECORD_DIR="/opt/founders-cabinet/memory/tier3/experience-records"
mkdir -p "$RECORD_DIR"
RECORD_FILE="$RECORD_DIR/${DATE}-${OFFICER}-${RECORD_ID}.md"

cat > "$RECORD_FILE" << EOF
# Experience Record

- **Officer:** $OFFICER
- **Date:** $TIMESTAMP
- **Outcome:** $OUTCOME
- **Tags:** $TAGS

## Task
$TASK_SUMMARY

## What Happened
$WHAT_HAPPENED

## Lessons Learned
${LESSONS:-No specific lessons noted.}
EOF

echo "Written to $RECORD_FILE"

# ============================================================
# 2. Insert into PostgreSQL (if available)
# ============================================================
DATABASE_URL="${DATABASE_URL:-}"
if [ -n "$DATABASE_URL" ]; then
  # Escape single quotes for SQL
  TASK_SQL=$(echo "$TASK_SUMMARY" | sed "s/'/''/g")
  WHAT_SQL=$(echo "$WHAT_HAPPENED" | sed "s/'/''/g")
  LESSONS_SQL=$(echo "$LESSONS" | sed "s/'/''/g")

  # Convert comma-separated tags to PostgreSQL array
  if [ -n "$TAGS" ]; then
    TAGS_SQL="ARRAY[$(echo "$TAGS" | sed "s/[[:space:]]*,[[:space:]]*/\',\'/g" | sed "s/^/'/;s/$/'/")]"
  else
    TAGS_SQL="ARRAY[]::TEXT[]"
  fi

  psql "$DATABASE_URL" -c "
    INSERT INTO experience_records (officer, task_summary, outcome, what_happened, lessons_learned, tags)
    VALUES ('$OFFICER', '$TASK_SQL', '$OUTCOME', '$WHAT_SQL', '$LESSONS_SQL', $TAGS_SQL);
  " > /dev/null 2>&1

  if [ $? -eq 0 ]; then
    echo "Inserted into PostgreSQL experience_records"
  else
    echo "Warning: PostgreSQL insert failed (record saved to file)" >&2
  fi
else
  echo "No DATABASE_URL — saved to file only"
fi
