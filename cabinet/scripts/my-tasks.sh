#!/bin/bash
# my-tasks.sh — Officer CLI for /tasks board state (Spec 038 Phase A v1.2).
#
# Transitions the caller's rows in the `officer_tasks` table and broadcasts
# on Redis pub/sub so the /tasks SSE stream pushes a live update.
#
# v1.2 deltas (COO adversary ratified msg 1623):
#   038.3 — context YAML absence is FATAL at CLI entry (not just a warning).
#   038.4 — block/unblock accept status IN ('queue','wip'); done/cancel clear
#           blocked + blocked_reason (the trigger's CHECK enforces this).
#   038.9 — every transaction SETs LOCAL app.cabinet_officer = :'slug' so the
#           officer_task_history AFTER trigger records the actual actor.
#
# Usage:
#   my-tasks.sh start "<title>" [--linked-url X] [--linked-kind linear|github|library] [--linked-id Y] [--context SLUG]
#   my-tasks.sh done <id>
#   my-tasks.sh block <id> "<reason>"
#   my-tasks.sh unblock <id>
#   my-tasks.sh queue "<title>" [--linked-url X] [--linked-kind ...] [--linked-id Y] [--context SLUG]
#   my-tasks.sh list
#   my-tasks.sh cancel <id>
#
# WIP cap per officer = 3 (Spec 038 v1.1). `start` errors listing current WIP
# titles if caller is at cap; `block` flips the `blocked` boolean overlay on
# a specific WIP row (still counts toward cap — blocked is a state, not a
# separate bucket).
#
# Caller identity (first match wins — Spec 038 v1.1 AC #9 requires at least
# one of the first two to be set):
#   1. --as <slug> flag               (spec-primary)
#   2. $CABINET_OFFICER env var       (spec-primary)
#   3. --officer <slug> flag          (legacy alias, kept for compat)
#   4. $OFFICER_NAME env var          (legacy alias, kept for compat)
#   5. basename of $(pwd) if under /opt/founders-cabinet/officers/<slug>
#
# Context isolation (Spec 038 v1.1 AC #21 — context_slug is NOT NULL):
#   --context <slug>            (overrides everything)
#   $CABINET_CONTEXT env var    (session-scoped)
#   instance/config/active-project.txt (deployment default)
# If none resolves, the script errors before touching the DB.
#
# Requires: psql in PATH, $NEON_CONNECTION_STRING. Redis pub is optional
# (silent skip if redis-cli missing — SSE fallback polling still works).

# `set -e` would abort on expected failures (e.g. WIP-cap psql error) and
# short-circuit our human-readable error reporting. We opt in to -u (undefined
# vars) and pipefail (pipeline exit propagation) only.
set -uo pipefail

usage() {
  grep '^# ' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

[ $# -lt 1 ] && usage

CMD=""
TITLE=""
REASON=""
TARGET_ID=""
LINKED_URL=""
LINKED_KIND=""
LINKED_ID=""
CONTEXT_SLUG=""
OFFICER_OVERRIDE=""

CMD="$1"; shift

# First positional after command: title, reason, or task id for applicable commands
case "$CMD" in
  start|queue)
    TITLE="${1:-}"; [ $# -gt 0 ] && shift
    ;;
  block)
    TARGET_ID="${1:-}"; [ $# -gt 0 ] && shift
    REASON="${1:-}"; [ $# -gt 0 ] && shift
    ;;
  unblock|done|cancel)
    TARGET_ID="${1:-}"; [ $# -gt 0 ] && shift
    ;;
  list) : ;;
  *) usage ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --linked-url)  LINKED_URL="$2";  shift 2 ;;
    --linked-kind) LINKED_KIND="$2"; shift 2 ;;
    --linked-id)   LINKED_ID="$2";   shift 2 ;;
    --context)     CONTEXT_SLUG="$2"; shift 2 ;;
    --as)          OFFICER_OVERRIDE="$2"; shift 2 ;;  # Spec 038 v1.1 AC #9
    --officer)     OFFICER_OVERRIDE="$2"; shift 2 ;;  # legacy alias
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- slug + connection setup -------------------------------------------------

OFFICER_SLUG=""
if [ -n "$OFFICER_OVERRIDE" ]; then
  OFFICER_SLUG="$OFFICER_OVERRIDE"
elif [ -n "${CABINET_OFFICER:-}" ]; then
  OFFICER_SLUG="$CABINET_OFFICER"
elif [ -n "${OFFICER_NAME:-}" ]; then
  OFFICER_SLUG="$OFFICER_NAME"
else
  CWD="$(pwd)"
  if [[ "$CWD" =~ ^/opt/founders-cabinet/officers/([a-z0-9-]+) ]]; then
    OFFICER_SLUG="${BASH_REMATCH[1]}"
  fi
fi

if [ -z "$OFFICER_SLUG" ]; then
  echo "ERROR: cannot determine officer slug. Pass --as <slug>, set \$CABINET_OFFICER, or run from officers/<slug>/." >&2
  exit 1
fi

if [ -z "${NEON_CONNECTION_STRING:-}" ]; then
  echo "ERROR: \$NEON_CONNECTION_STRING not set." >&2
  exit 1
fi

CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
if [ -z "$CONTEXT_SLUG" ] && [ -n "${CABINET_CONTEXT:-}" ]; then
  CONTEXT_SLUG="$CABINET_CONTEXT"
fi
if [ -z "$CONTEXT_SLUG" ] && [ -f "$CABINET_ROOT/instance/config/active-project.txt" ]; then
  CONTEXT_SLUG="$(tr -d '[:space:]' < "$CABINET_ROOT/instance/config/active-project.txt")"
fi

# Spec 038 v1.1 AC #21: context_slug is NOT NULL at DB level. Fail fast with
# a readable message rather than letting psql report a CHECK violation.
if [ -z "$CONTEXT_SLUG" ]; then
  echo "ERROR: context_slug required. Pass --context <slug>, set \$CABINET_CONTEXT, or write instance/config/active-project.txt." >&2
  exit 1
fi

# Per AC #21 + v1.2 038.3: the context MUST resolve to a readable YAML file.
# Fatal — otherwise rows would refer to contexts that never exist on disk,
# orphaning them from config and confusing the dashboard badge logic.
if [ ! -f "$CABINET_ROOT/instance/config/contexts/$CONTEXT_SLUG.yml" ]; then
  echo "ERROR: context '$CONTEXT_SLUG' has no YAML at instance/config/contexts/$CONTEXT_SLUG.yml." >&2
  echo "       Create the file first (see instance/config/contexts/README), or pick a valid --context." >&2
  exit 1
fi

WIP_CAP=3

# psql wrapper: -v ON_ERROR_STOP=1 propagates errors; -A -t for clean output
psql_q() {
  psql "$NEON_CONNECTION_STRING" -v ON_ERROR_STOP=1 -A -t -q "$@"
}

# Broadcast helper (fire-and-forget — SSE will degrade to polling if skipped)
broadcast() {
  command -v redis-cli >/dev/null 2>&1 || return 0
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  redis-cli -h "${REDIS_HOST:-redis}" -p "${REDIS_PORT:-6379}" \
    PUBLISH cabinet:tasks:updated \
    "{\"officer_slug\":\"$OFFICER_SLUG\",\"timestamp\":\"$ts\"}" >/dev/null 2>&1 || true
}

# --- commands ----------------------------------------------------------------

case "$CMD" in

  start)
    [ -z "$TITLE" ] && { echo "ERROR: title required" >&2; exit 2; }
    # WIP<=3 is enforced by the `trg_enforce_officer_wip` BEFORE trigger —
    # a concurrent start that would bring the count to 4 raises
    # `WIP limit (3) exceeded ...`, which psql prints to stderr. We surface
    # a readable hint listing current WIP via the EXISTING lookup.
    OUTPUT=$({ psql_q \
      -v slug="$OFFICER_SLUG" -v title="$TITLE" \
      -v lurl="${LINKED_URL:-}" -v lkind="${LINKED_KIND:-}" \
      -v lid="${LINKED_ID:-}" -v ctx="${CONTEXT_SLUG:-}" \
      <<'SQL'
BEGIN;
SELECT set_config('app.cabinet_officer', :'slug', true);
INSERT INTO officer_tasks (officer_slug, title, status, linked_url, linked_kind, linked_id, started_at, context_slug)
VALUES (
  :'slug', :'title', 'wip',
  NULLIF(:'lurl',''), NULLIF(:'lkind',''), NULLIF(:'lid',''), NOW(), NULLIF(:'ctx','')
) RETURNING id, title;
COMMIT;
SQL
} 2>&1)
    RC=$?
    if [ $RC -ne 0 ] || echo "$OUTPUT" | grep -qE "WIP limit|duplicate key"; then
      # Surface existing WIP titles for a readable error
      EXISTING=$(psql_q -v slug="$OFFICER_SLUG" -v ctx="${CONTEXT_SLUG:-}" <<SQL
SELECT id || '|' || title FROM officer_tasks
 WHERE officer_slug = :'slug'
   AND COALESCE(context_slug,'') = COALESCE(NULLIF(:'ctx',''),'')
   AND status = 'wip'
 ORDER BY started_at DESC NULLS LAST;
SQL
)
      if [ -n "$EXISTING" ]; then
        echo "ERROR: WIP cap ($WIP_CAP) reached for $OFFICER_SLUG. Current WIP:" >&2
        echo "$EXISTING" | awk -F'|' '{print "  - id="$1" "$2}' >&2
        echo "Finish/cancel one before starting another." >&2
      else
        echo "$OUTPUT" >&2
      fi
      exit 1
    fi
    echo "$OUTPUT" | grep -E '^[0-9]+\|' | tail -1 | awk -F'|' '{print "STARTED id="$1" title="$2}'
    broadcast
    ;;

  done)
    [ -z "$TARGET_ID" ] && { echo "ERROR: task id required (use 'my-tasks.sh list' to find yours)" >&2; exit 2; }
    OUTPUT=$(psql_q -v slug="$OFFICER_SLUG" -v id="$TARGET_ID" <<'SQL'
BEGIN;
SELECT set_config('app.cabinet_officer', :'slug', true);
UPDATE officer_tasks
   SET status = 'done', completed_at = NOW(), blocked = false, blocked_reason = NULL
 WHERE id = :'id'::bigint
   AND officer_slug = :'slug'
   AND status = 'wip'
RETURNING id, title;
COMMIT;
SQL
)
    if [ -z "$OUTPUT" ] || ! echo "$OUTPUT" | grep -qE '^[0-9]+'; then
      echo "ERROR: task id=$TARGET_ID not found, not in WIP, or wrong officer" >&2
      exit 1
    fi
    echo "$OUTPUT" | awk -F'|' '{print "DONE id="$1" title="$2}'
    broadcast
    ;;

  block)
    [ -z "$TARGET_ID" ] && { echo "ERROR: task id required" >&2; exit 2; }
    [ -z "$REASON" ] && { echo "ERROR: reason required" >&2; exit 2; }
    # 038.4: block accepts status IN ('queue','wip'). blocked_state_coherent
    # CHECK enforces done/cancelled cannot be blocked.
    OUTPUT=$(psql_q -v slug="$OFFICER_SLUG" -v id="$TARGET_ID" -v reason="$REASON" <<'SQL'
BEGIN;
SELECT set_config('app.cabinet_officer', :'slug', true);
UPDATE officer_tasks
   SET blocked = true, blocked_reason = :'reason'
 WHERE id = :'id'::bigint
   AND officer_slug = :'slug'
   AND status IN ('queue', 'wip')
RETURNING id, title;
COMMIT;
SQL
)
    if [ -z "$OUTPUT" ] || ! echo "$OUTPUT" | grep -qE '^[0-9]+'; then
      echo "ERROR: task id=$TARGET_ID not found, not in queue/WIP, or wrong officer" >&2
      exit 1
    fi
    echo "$OUTPUT" | awk -F'|' '{print "BLOCKED id="$1" title="$2}'
    broadcast
    ;;

  unblock)
    # Spec §3.3 AC #7: idempotent on already-unblocked rows.
    # UPDATE matches any queue/wip row owned by caller; SET clears both cols
    # regardless of current state so re-running is a no-op (blocked was
    # already false, blocked_reason already NULL → same row after UPDATE).
    [ -z "$TARGET_ID" ] && { echo "ERROR: task id required" >&2; exit 2; }
    OUTPUT=$(psql_q -v slug="$OFFICER_SLUG" -v id="$TARGET_ID" <<'SQL'
BEGIN;
SELECT set_config('app.cabinet_officer', :'slug', true);
UPDATE officer_tasks
   SET blocked = false, blocked_reason = NULL
 WHERE id = :'id'::bigint
   AND officer_slug = :'slug'
   AND status IN ('queue', 'wip')
RETURNING id, title;
COMMIT;
SQL
)
    if [ -z "$OUTPUT" ] || ! echo "$OUTPUT" | grep -qE '^[0-9]+'; then
      # Row genuinely not found / wrong owner / not active — NOT the
      # "already unblocked" case (that matched and no-op'd).
      echo "ERROR: task id=$TARGET_ID not found, not in queue/WIP, or wrong officer" >&2
      exit 1
    fi
    echo "$OUTPUT" | awk -F'|' '{print "UNBLOCKED id="$1" title="$2}'
    broadcast
    ;;

  queue)
    [ -z "$TITLE" ] && { echo "ERROR: title required" >&2; exit 2; }
    OUTPUT=$(psql_q \
      -v slug="$OFFICER_SLUG" -v title="$TITLE" \
      -v lurl="${LINKED_URL:-}" -v lkind="${LINKED_KIND:-}" \
      -v lid="${LINKED_ID:-}" -v ctx="${CONTEXT_SLUG:-}" \
      <<'SQL'
BEGIN;
SELECT set_config('app.cabinet_officer', :'slug', true);
INSERT INTO officer_tasks (officer_slug, title, status, linked_url, linked_kind, linked_id, context_slug)
VALUES (
  :'slug', :'title', 'queue',
  NULLIF(:'lurl',''), NULLIF(:'lkind','')::text, NULLIF(:'lid',''), NULLIF(:'ctx','')
) RETURNING id, title;
COMMIT;
SQL
)
    RC=$?
    [ $RC -ne 0 ] && { echo "$OUTPUT" >&2; exit 1; }
    echo "$OUTPUT" | awk -F'|' '{print "QUEUED id="$1" title="$2}'
    broadcast
    ;;

  cancel)
    [ -z "$TARGET_ID" ] && { echo "ERROR: id required" >&2; exit 2; }
    OUTPUT=$(psql_q -v slug="$OFFICER_SLUG" -v id="$TARGET_ID" <<'SQL'
BEGIN;
SELECT set_config('app.cabinet_officer', :'slug', true);
UPDATE officer_tasks
   SET status = 'cancelled', blocked = false, blocked_reason = NULL
 WHERE id = :'id'::bigint
   AND officer_slug = :'slug'
   AND status NOT IN ('done','cancelled')
RETURNING id, title;
COMMIT;
SQL
)
    if [ -z "$OUTPUT" ] || ! echo "$OUTPUT" | grep -qE '^[0-9]+'; then
      echo "ERROR: task id=$TARGET_ID not found, already closed, or wrong officer" >&2
      exit 1
    fi
    echo "$OUTPUT" | awk -F'|' '{print "CANCELLED id="$1" title="$2}'
    broadcast
    ;;

  list)
    # v1.2: filter by active context so Personal/Work/Adhoc tasks don't mix.
    psql_q -v slug="$OFFICER_SLUG" -v ctx="$CONTEXT_SLUG" <<'SQL'
SELECT
  status,
  CASE WHEN blocked THEN '⛓' ELSE ' ' END AS b,
  id,
  LEFT(COALESCE(title,''), 70) AS title,
  COALESCE(blocked_reason,'') AS blocked_reason
FROM officer_tasks
WHERE officer_slug = :'slug'
  AND context_slug = :'ctx'
  AND status IN ('wip','queue')
ORDER BY CASE status WHEN 'wip' THEN 0 ELSE 1 END, created_at;
SQL
    ;;

  *) usage ;;
esac
