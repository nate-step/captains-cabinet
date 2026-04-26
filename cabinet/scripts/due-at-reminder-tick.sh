#!/bin/bash
# cabinet/scripts/due-at-reminder-tick.sh — Spec 041 cron worker
#
# Drains officer_tasks rows where due_at <= NOW() AND status IN (queue, wip)
# AND reminder_fired_at IS NULL. Atomic SELECT-FOR-UPDATE-SKIP-LOCKED + UPDATE
# pattern in a single CTE statement; rows are claimed + marked fired in the
# same transaction. For each claimed row, pushes a task_reminder trigger to
# the owning officer's Redis stream via trigger_send.
#
# Cron suggestion (every 5 min, per Cabinet):
#   */5 * * * * cd /opt/founders-cabinet && \
#               bash cabinet/scripts/due-at-reminder-tick.sh >> \
#               memory/logs/due-at-reminder-tick.log 2>&1
#
# Connection string: reads CONN > NEON_CONNECTION_STRING > DATABASE_URL.
# In Work Cabinet, NEON_CONNECTION_STRING points at the Sensed Neon (where
# officer_tasks lives — same DB the dashboard reads). Personal Cabinet
# points at its own postgres. Each Cabinet runs its own cron entry.
#
# Idempotent: re-running after a fire produces zero new triggers for the
# same task. Re-arm trigger (officer_tasks_due_at_rearm_trg) clears
# reminder_fired_at on any due_at change so the new time can fire.
#
# Exits 0 always — never block the next cron run.

set -u

CONN="${CONN:-${NEON_CONNECTION_STRING:-${DATABASE_URL:-}}}"
if [ -z "$CONN" ]; then
  echo "[due-at-reminder-tick] no DB connection string set (CONN | NEON_CONNECTION_STRING | DATABASE_URL)" >&2
  exit 0
fi

# shellcheck disable=SC1091
source /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh

# Identify the worker for trigger sender attribution + log readability.
export OFFICER_NAME="${OFFICER_NAME:-due-at-reminder}"

# Atomic claim + mark in a single statement. CTE FOR UPDATE SKIP LOCKED prevents
# two ticks from double-firing the same row; the outer UPDATE flips
# reminder_fired_at on those locked rows; RETURNING gives the work payload.
# LIMIT 100 = safety cap per tick (spec §cron-worker).
#
# psql -tA emits a trailing "UPDATE N" status line on RETURNING UPDATE statements
# even with --tuples-only. Filter to lines containing a tab (valid row delimiter)
# so the status line is dropped before the row loop.
RAW="$(psql "$CONN" -tA -F $'\t' --no-psqlrc -v ON_ERROR_STOP=1 -c "
WITH due_tasks AS (
  SELECT id, officer_slug, title, due_at
  FROM officer_tasks
  WHERE due_at IS NOT NULL
    AND due_at <= NOW()
    AND status IN ('queue', 'wip')
    AND reminder_fired_at IS NULL
  ORDER BY due_at ASC
  LIMIT 100
  FOR UPDATE SKIP LOCKED
)
UPDATE officer_tasks
SET reminder_fired_at = NOW()
WHERE id IN (SELECT id FROM due_tasks)
RETURNING id, officer_slug, title, due_at;
" 2>&1)"
psql_rc=$?

if [ $psql_rc -ne 0 ]; then
  echo "[due-at-reminder-tick] psql failed rc=$psql_rc output=${RAW}" >&2
  exit 0
fi

# Keep only lines containing the tab field separator (drop the "UPDATE N" status).
ROWS="$(printf '%s\n' "$RAW" | grep -E $'\t' || true)"

if [ -z "$ROWS" ]; then
  exit 0
fi

count=0
fail=0
now_iso="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

while IFS=$'\t' read -r task_id officer_slug title due_at; do
  [ -z "$task_id" ] && continue
  # Build JSON payload — jq -n with --arg sanitises every value (no shell injection).
  payload="$(jq -cn \
    --arg type "task_reminder" \
    --argjson id "$task_id" \
    --arg t "$title" \
    --arg d "$due_at" \
    --arg n "$now_iso" \
    '{type:$type, task_id:$id, title:$t, due_at:$d, now:$n}' 2>/dev/null)"
  if [ -z "$payload" ]; then
    echo "[due-at-reminder-tick] jq payload build failed task_id=$task_id" >&2
    fail=$((fail + 1))
    continue
  fi
  if trigger_send "$officer_slug" "$payload"; then
    count=$((count + 1))
  else
    fail=$((fail + 1))
    echo "[due-at-reminder-tick] trigger_send failed officer_slug=$officer_slug task_id=$task_id" >&2
  fi
done <<< "$ROWS"

echo "[due-at-reminder-tick] fired=$count fail=$fail elapsed_at=$now_iso"
