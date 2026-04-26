#!/bin/bash
# cabinet/scripts/hooks/personal-work-parity.sh — Spec 043 H3
#
# Soft-warn reminder when an officer edits shared-infra paths in the Work
# tree without a corresponding Personal-tree edit. Captain msg 1955 + 1960
# + 1964 — three reinforcing pulls in 90 minutes asking for parity. The
# parity *mechanism* is sync-framework + this hook; the cue closes the gap
# when an officer is mid-edit.
#
# Wired as PostToolUse(Write|Edit). Per-officer tracker at
# /tmp/.cabinet-parity-tracker-<officer> with 5-min TTL — a Work-tree edit
# within 5 min of a Personal-tree edit is treated as a parity sync in
# flight, no warn. Spec 043 AC #3 (5-min TTL pinned).
#
# Anti-FW-042 discipline:
#   - Warn-only. NEVER exits non-zero. NEVER blocks.
#   - Env-var disable: PARITY_HOOK_ENABLED=0
#   - FP-rate logging to cabinet/logs/hook-fires/personal-work-parity.jsonl
#
# Reversibility: rm this file + drop settings.json registration.

set -u

if [ "${PARITY_HOOK_ENABLED:-1}" = "0" ]; then
  exit 0
fi

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
LOG_DIR="$REPO_ROOT/cabinet/logs/hook-fires"
LOG_FILE="$LOG_DIR/personal-work-parity.jsonl"

OFFICER="${OFFICER_NAME:-${CABINET_OFFICER:-unknown}}"
NOW_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
NOW_TS="$(date +%s)"
TTL_SECONDS=300   # 5-min per Spec 043 AC #3

INPUT="$(cat)"
[ -z "$INPUT" ] && exit 0

# Extract file_path from PostToolUse JSON. Both Write and Edit carry it.
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)"
[ -z "$FILE_PATH" ] && exit 0

# Trigger paths — shared-infra patterns that warrant parity. Per Spec 043 §H3.
# A path matching ANY of these is a candidate for parity reminder.
TRIGGER_PATTERNS=(
  "/cabinet/sql/"
  "/cabinet/scripts/"
  "/framework/"
  "/presets/"
  "/memory/skills/"
)

# Skip if not a trigger path.
TRIGGERED=0
for pat in "${TRIGGER_PATTERNS[@]}"; do
  case "$FILE_PATH" in
    *"$pat"*) TRIGGERED=1; break ;;
  esac
done
[ "$TRIGGERED" = "0" ] && exit 0

# Determine which tree we're in. /opt/founders-cabinet/ = Work; /opt/personal-cabinet/ = Personal.
TREE=""
case "$FILE_PATH" in
  /opt/founders-cabinet/*) TREE="work" ;;
  /opt/personal-cabinet/*) TREE="personal" ;;
  *)
    # Edits outside the known cabinet trees aren't covered by parity.
    exit 0
    ;;
esac

TRACKER="/tmp/.cabinet-parity-tracker-$OFFICER"

# Touch the tracker for this tree's edit.
# Format: <tree> <ts>\n... — appended; we read latest entry per tree.
mkdir -p "$(dirname "$TRACKER")" 2>/dev/null || true
printf '%s %d\n' "$TREE" "$NOW_TS" >> "$TRACKER"

# If we just edited Personal, no warn — that IS the parity.
if [ "$TREE" = "personal" ]; then
  exit 0
fi

# We just edited Work. Look for a recent Personal edit within TTL.
PERSONAL_LAST="$(grep '^personal ' "$TRACKER" 2>/dev/null | tail -1 | awk '{print $2}')"
if [ -n "$PERSONAL_LAST" ] && [ "$((NOW_TS - PERSONAL_LAST))" -lt "$TTL_SECONDS" ]; then
  # Personal edit is fresh — parity sync in flight, no warn.
  exit 0
fi

# No recent Personal edit → emit parity reminder.
mkdir -p "$LOG_DIR" 2>/dev/null
LOG_LINE="$(jq -cn \
  --arg ts "$NOW_ISO" \
  --arg officer "$OFFICER" \
  --arg path "$FILE_PATH" \
  --arg tree "$TREE" \
  '{ts:$ts, hook:"personal-work-parity", officer:$officer, file_path:$path, tree:$tree}' 2>/dev/null)"
[ -n "$LOG_LINE" ] && echo "$LOG_LINE" >> "$LOG_FILE"

# Compute the canonical Personal-side path so officer can copy-paste.
PERSONAL_PATH="$(printf '%s' "$FILE_PATH" | sed 's|^/opt/founders-cabinet/|/opt/personal-cabinet/|')"

WARN="PERSONAL-WORK PARITY REMINDER

Edited Work-tree shared infra: $FILE_PATH

A4 (Personal-Work parity, msg 1955+1960+1964): shared infra defaults to
parity across both Cabinets. Sync-framework propagates most paths
automatically (~5min cron), but explicit edits to Personal may be
needed for: per-instance config, settings.json registrations, runtime
state files.

Personal-side counterpart path: $PERSONAL_PATH

If sync-framework covers it: ignore this warn (advisory).
If per-instance work is needed: edit the Personal counterpart now or
file a parity todo. The S2 skill at memory/skills/evolved/personal-work-parity-checklist.md
has the canonical sync direction + skip-conditions.

Hook: warn-only. Disable via PARITY_HOOK_ENABLED=0."

jq -n --arg ctx "$WARN" '{additionalContext: $ctx}'
exit 0
