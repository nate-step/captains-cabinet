#!/bin/bash
# post-file-write-memory.sh — Queue Cabinet shared artifacts for re-embedding on Write/Edit
# Only re-embeds when the file is in a watched path. No-op otherwise.
# Runs in background — never blocks the tool call.

HOOK_INPUT=$(cat)
OFFICER="${OFFICER_NAME:-unknown}"

# Extract file path (Write uses .file_path, Edit uses .file_path too)
FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# Only watch Cabinet shared artifacts — determine source_type by path
SOURCE_TYPE=""
case "$FILE_PATH" in
  */shared/interfaces/captain-decisions.md)
    SOURCE_TYPE="captain_decisions_file"  # versioned entries parsed separately below
    ;;
  */shared/interfaces/tech-radar.md)
    SOURCE_TYPE="tech_radar"
    ;;
  */shared/interfaces/product-specs/*.md)
    SOURCE_TYPE="product_spec"
    ;;
  */shared/backlog.md)
    SOURCE_TYPE="working_note"
    ;;
  */instance/memory/tier2/*/working-notes.md)
    SOURCE_TYPE="working_note"
    ;;
  */instance/memory/tier2/*/reflections/*.md)
    SOURCE_TYPE="reflection"
    ;;
  */memory/skills/*.md|*/memory/skills/evolved/*.md)
    SOURCE_TYPE="skill"
    ;;
  */constitution/*.md)
    SOURCE_TYPE="framework_file"
    ;;
  *)
    exit 0  # Not a watched path
    ;;
esac

# Background: source env + memory lib, queue embed
(
  set -a
  source /opt/founders-cabinet/cabinet/.env 2>/dev/null
  set +a
  source /opt/founders-cabinet/cabinet/scripts/lib/memory.sh 2>/dev/null

  if ! declare -f memory_queue_embed > /dev/null; then
    exit 0
  fi

  [ ! -f "$FILE_PATH" ] && exit 0
  content=$(cat "$FILE_PATH")
  [ -z "$(printf '%s' "$content" | tr -d '[:space:]')" ] && exit 0

  # Captain decisions: parse the full markdown table, queue each row as its own versioned entry
  if [ "$SOURCE_TYPE" = "captain_decisions_file" ]; then
    row_num=0
    while IFS='|' read -r _ date decision why affected _; do
      date=$(printf '%s' "$date" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      decision=$(printf '%s' "$decision" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      why=$(printf '%s' "$why" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      affected=$(printf '%s' "$affected" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [[ ! "$date" =~ ^20[0-9]{2}- ]] && continue
      row_num=$((row_num+1))
      row_content="Decision: $decision | Why: $why | Affected: $affected"
      row_meta=$(jq -nc --arg date "$date" --arg affected "$affected" '{date: $date, affected: $affected}')
      memory_queue_embed "captain_decision" "cd-${date}-${row_num}" "captain" "captain" \
        "$row_content" "$row_meta" "${date}T00:00:00Z" 2>/dev/null
    done < "$FILE_PATH"
    exit 0
  fi

  # Generic file: re-embed the whole file
  rel_path="${FILE_PATH#/opt/founders-cabinet/}"
  mtime=$(date -u -r "$FILE_PATH" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  editor_meta=$(jq -nc --arg officer "$OFFICER" '{edited_by: $officer}')
  memory_queue_embed "$SOURCE_TYPE" "$rel_path" "$OFFICER" "" "$content" "$editor_meta" "$mtime" 2>/dev/null
) > /dev/null 2>&1 &

exit 0
