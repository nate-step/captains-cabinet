-- Spec 041 — /tasks due_at + auto-fire reminders
-- Apply to BOTH Work + Personal cabinet postgres (per Personal-Work parity).
-- Reversibility: drop the two columns + index + trigger + function; no data loss
-- since due_at/reminder_fired_at are NULL on every existing row.
--
-- Idempotent: each statement uses IF NOT EXISTS / CREATE OR REPLACE.

-- ---------------------------------------------------------------
-- 1. Add due_at + reminder_fired_at columns (NULL on every existing row)
-- ---------------------------------------------------------------
ALTER TABLE officer_tasks
  ADD COLUMN IF NOT EXISTS due_at TIMESTAMPTZ NULL,
  ADD COLUMN IF NOT EXISTS reminder_fired_at TIMESTAMPTZ NULL;

-- ---------------------------------------------------------------
-- 2. Partial index sized for the cron query — only pending tasks with a
-- due_at that haven't fired yet. Most tasks have no due_at, so the partial
-- predicate keeps the index small.
-- ---------------------------------------------------------------
CREATE INDEX IF NOT EXISTS officer_tasks_due_pending_idx
  ON officer_tasks (due_at)
  WHERE due_at IS NOT NULL
    AND reminder_fired_at IS NULL
    AND status IN ('queue', 'wip');

-- ---------------------------------------------------------------
-- 3. Re-arm trigger: when due_at changes (forward, backward, or to NULL),
-- clear reminder_fired_at so the new due_at can fire on the next cron tick.
-- Single source of truth for "did this fire yet" — no app-side state.
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION officer_tasks_due_at_rearm()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.due_at IS DISTINCT FROM OLD.due_at THEN
    NEW.reminder_fired_at := NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS officer_tasks_due_at_rearm_trg ON officer_tasks;
CREATE TRIGGER officer_tasks_due_at_rearm_trg
  BEFORE UPDATE OF due_at ON officer_tasks
  FOR EACH ROW EXECUTE FUNCTION officer_tasks_due_at_rearm();
