#!/bin/bash
# my-tasks.sh — Officer CLI for /tasks board state (Spec 038 Phase A).
#
# Transitions the caller's row in the `officer_tasks` table and broadcasts
# on Redis pub/sub so the /tasks SSE stream pushes a live update.
#
# Usage:
#   my-tasks.sh start "<title>" [--linked-url X] [--linked-kind linear|github|library] [--linked-id Y] [--context SLUG]
#   my-tasks.sh done
#   my-tasks.sh block "<reason>"
#   my-tasks.sh queue "<title>" [--linked-url X] [--linked-kind ...] [--linked-id Y] [--context SLUG]
#   my-tasks.sh list
#   my-tasks.sh cancel <id>
#
# Officer slug resolution (first match wins):
#   1. --officer <slug> flag
#   2. $OFFICER_NAME env var
#   3. basename of $(pwd) if under /opt/founders-cabinet/officers/<slug>
#
# Requires: psql in PATH, $NEON_CONNECTION_STRING. Redis pub is optional
# (silent skip if redis-cli missing — SSE fallback polling still works).

# `set -e` would abort on expected failures (e.g. WIP-conflict psql error) and
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
CANCEL_ID=""
LINKED_URL=""
LINKED_KIND=""
LINKED_ID=""
CONTEXT_SLUG=""
OFFICER_OVERRIDE=""

CMD="$1"; shift

# First positional after command: title or reason for applicable commands
case "$CMD" in
  start|queue) TITLE="${1:-}"; [ $# -gt 0 ] && shift ;;
  block)       REASON="${1:-}"; [ $# -gt 0 ] && shift ;;
  cancel)      CANCEL_ID="${1:-}"; [ $# -gt 0 ] && shift ;;
  done|list)   : ;;
  *) usage ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --linked-url)  LINKED_URL="$2";  shift 2 ;;
    --linked-kind) LINKED_KIND="$2"; shift 2 ;;
    --linked-id)   LINKED_ID="$2";   shift 2 ;;
    --context)     CONTEXT_SLUG="$2"; shift 2 ;;
    --officer)     OFFICER_OVERRIDE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

# --- slug + connection setup -------------------------------------------------

OFFICER_SLUG=""
if [ -n "$OFFICER_OVERRIDE" ]; then
  OFFICER_SLUG="$OFFICER_OVERRIDE"
elif [ -n "${OFFICER_NAME:-}" ]; then
  OFFICER_SLUG="$OFFICER_NAME"
else
  CWD="$(pwd)"
  if [[ "$CWD" =~ ^/opt/founders-cabinet/officers/([a-z0-9-]+) ]]; then
    OFFICER_SLUG="${BASH_REMATCH[1]}"
  fi
fi

if [ -z "$OFFICER_SLUG" ]; then
  echo "ERROR: cannot determine officer slug. Pass --officer, set \$OFFICER_NAME, or run from officers/<slug>/." >&2
  exit 1
fi

if [ -z "${NEON_CONNECTION_STRING:-}" ]; then
  echo "ERROR: \$NEON_CONNECTION_STRING not set." >&2
  exit 1
fi

CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
if [ -z "$CONTEXT_SLUG" ] && [ -f "$CABINET_ROOT/instance/config/active-project.txt" ]; then
  CONTEXT_SLUG="$(tr -d '[:space:]' < "$CABINET_ROOT/instance/config/active-project.txt")"
fi

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

# SQL identifier / literal escaping (PostgreSQL single-quote rule)
# Caller must still pass inputs via --variable to avoid SQL injection fully;
# we use -v + :'var' binding below.

# --- commands ----------------------------------------------------------------

case "$CMD" in

  start)
    [ -z "$TITLE" ] && { echo "ERROR: title required" >&2; exit 2; }
    # WIP=1 is enforced by the `officer_tasks_one_wip_per_officer` partial
    # unique index — a concurrent second WIP raises
    # `duplicate key value violates unique constraint`, which psql prints to
    # stderr. We surface a more readable hint via the `EXISTING` lookup.
    OUTPUT=$(psql_q \
      -v slug="$OFFICER_SLUG" -v title="$TITLE" \
      -v lurl="${LINKED_URL:-}" -v lkind="${LINKED_KIND:-}" \
      -v lid="${LINKED_ID:-}" -v ctx="${CONTEXT_SLUG:-}" \
      <<SQL 2>&1
BEGIN;
INSERT INTO officer_tasks (officer_slug, title, status, linked_url, linked_kind, linked_id, started_at, context_slug)
VALUES (
  :'slug', :'title', 'wip',
  NULLIF(:'lurl',''), NULLIF(:'lkind',''), NULLIF(:'lid',''), NOW(), NULLIF(:'ctx','')
) RETURNING id, title;
COMMIT;
SQL
)
    RC=$?
    if [ $RC -ne 0 ] || echo "$OUTPUT" | grep -q "duplicate key"; then
      # Surface existing WIP for readable error
      EXISTING=$(psql_q -v slug="$OFFICER_SLUG" <<SQL
SELECT id || '|' || title FROM officer_tasks
 WHERE officer_slug = :'slug' AND status = 'wip' LIMIT 1;
SQL
)
      if [ -n "$EXISTING" ]; then
        echo "ERROR: WIP conflict — $OFFICER_SLUG already has WIP: $EXISTING. Finish/block it first." >&2
      else
        echo "$OUTPUT" >&2
      fi
      exit 1
    fi
    echo "$OUTPUT" | grep -E '^[0-9]+\|' | tail -1 | awk -F'|' '{print "STARTED id="$1" title="$2}'
    broadcast
    ;;

  done)
    # BEGIN/FOR UPDATE/COMMIT — two concurrent `done` calls from different
    # terminals of the same officer lock on the WIP row. Loser sees zero rows.
    OUTPUT=$(psql_q -v slug="$OFFICER_SLUG" <<'SQL'
BEGIN;
UPDATE officer_tasks
   SET status = 'done', completed_at = NOW()
 WHERE id = (
   SELECT id FROM officer_tasks
    WHERE officer_slug = :'slug' AND status = 'wip'
    FOR UPDATE SKIP LOCKED
    LIMIT 1
 )
RETURNING id, title;
COMMIT;
SQL
)
    if [ -z "$OUTPUT" ] || ! echo "$OUTPUT" | grep -qE '^[0-9]+'; then
      echo "ERROR: no WIP task for $OFFICER_SLUG" >&2
      exit 1
    fi
    echo "$OUTPUT" | awk -F'|' '{print "DONE id="$1" title="$2}'
    broadcast
    ;;

  block)
    [ -z "$REASON" ] && { echo "ERROR: reason required" >&2; exit 2; }
    # BEGIN/FOR UPDATE/COMMIT — see `done` above for the concurrency rationale.
    OUTPUT=$(psql_q -v slug="$OFFICER_SLUG" -v reason="$REASON" <<'SQL'
BEGIN;
UPDATE officer_tasks
   SET status = 'blocked', blocked_reason = :'reason'
 WHERE id = (
   SELECT id FROM officer_tasks
    WHERE officer_slug = :'slug' AND status = 'wip'
    FOR UPDATE SKIP LOCKED
    LIMIT 1
 )
RETURNING id, title;
COMMIT;
SQL
)
    if [ -z "$OUTPUT" ] || ! echo "$OUTPUT" | grep -qE '^[0-9]+'; then
      echo "ERROR: no WIP task for $OFFICER_SLUG" >&2
      exit 1
    fi
    echo "$OUTPUT" | awk -F'|' '{print "BLOCKED id="$1" title="$2}'
    broadcast
    ;;

  queue)
    [ -z "$TITLE" ] && { echo "ERROR: title required" >&2; exit 2; }
    OUTPUT=$(psql_q \
      -v slug="$OFFICER_SLUG" -v title="$TITLE" \
      -v lurl="${LINKED_URL:-}" -v lkind="${LINKED_KIND:-}" \
      -v lid="${LINKED_ID:-}" -v ctx="${CONTEXT_SLUG:-}" \
      <<'SQL'
INSERT INTO officer_tasks (officer_slug, title, status, linked_url, linked_kind, linked_id, context_slug)
VALUES (
  :'slug', :'title', 'queue',
  NULLIF(:'lurl',''), NULLIF(:'lkind','')::text, NULLIF(:'lid',''), NULLIF(:'ctx','')
) RETURNING id, title;
SQL
)
    RC=$?
    [ $RC -ne 0 ] && { echo "$OUTPUT" >&2; exit 1; }
    echo "$OUTPUT" | awk -F'|' '{print "QUEUED id="$1" title="$2}'
    broadcast
    ;;

  cancel)
    [ -z "$CANCEL_ID" ] && { echo "ERROR: id required" >&2; exit 2; }
    OUTPUT=$(psql_q -v slug="$OFFICER_SLUG" -v id="$CANCEL_ID" <<'SQL'
UPDATE officer_tasks
   SET status = 'cancelled'
 WHERE id = :'id'::bigint
   AND officer_slug = :'slug'
   AND status NOT IN ('done','cancelled')
RETURNING id, title;
SQL
)
    if [ -z "$OUTPUT" ] || ! echo "$OUTPUT" | grep -qE '^[0-9]+'; then
      echo "ERROR: task id=$CANCEL_ID not found, already closed, or wrong officer" >&2
      exit 1
    fi
    echo "$OUTPUT" | awk -F'|' '{print "CANCELLED id="$1" title="$2}'
    broadcast
    ;;

  list)
    psql_q -v slug="$OFFICER_SLUG" <<'SQL'
SELECT
  status,
  id,
  LEFT(COALESCE(title,''), 70) AS title,
  COALESCE(blocked_reason,'') AS blocked_reason
FROM officer_tasks
WHERE officer_slug = :'slug' AND status IN ('wip','blocked','queue')
ORDER BY CASE status WHEN 'wip' THEN 0 WHEN 'blocked' THEN 1 ELSE 2 END, created_at;
SQL
    ;;

  *) usage ;;
esac
