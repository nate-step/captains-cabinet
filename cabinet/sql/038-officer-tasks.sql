-- cabinet/sql/038-officer-tasks.sql
-- Spec 038 — officer_tasks table with WIP=1 partial unique index.
--
-- No FK to a contexts table (captain decision 2026-04-16: context_slug is a
-- plain TEXT column validated by hook; no DB-level referential integrity
-- against contexts). officer_slug is likewise a plain TEXT — officers are
-- defined in YAML, not a DB table.
--
-- Idempotent — safe to re-run.
-- Target: Cabinet Postgres (same DB as experience_records, library_records).

-- =============================================================
-- officer_tasks
-- =============================================================
CREATE TABLE IF NOT EXISTS officer_tasks (
  id BIGSERIAL PRIMARY KEY,
  officer_slug TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL CHECK (status IN ('queue', 'wip', 'blocked', 'done', 'cancelled')),
  blocked_reason TEXT,
  linked_url TEXT,
  linked_kind TEXT CHECK (linked_kind IN ('linear', 'github', 'library') OR linked_kind IS NULL),
  linked_id TEXT,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  context_slug TEXT,

  -- DB-level constraint: blocked tasks must have a reason
  CONSTRAINT blocked_needs_reason
    CHECK (status != 'blocked' OR blocked_reason IS NOT NULL)
);

-- Hard WIP=1 invariant per officer (partial unique index)
CREATE UNIQUE INDEX IF NOT EXISTS idx_officer_tasks_wip_unique
  ON officer_tasks(officer_slug)
  WHERE status = 'wip';

-- Fast per-officer+status lookups (the most common dashboard query)
CREATE INDEX IF NOT EXISTS idx_officer_tasks_officer_status
  ON officer_tasks(officer_slug, status);

-- Done-section query: order completed tasks newest-first
CREATE INDEX IF NOT EXISTS idx_officer_tasks_completed
  ON officer_tasks(completed_at DESC)
  WHERE status = 'done';

-- Context-scoped lookups
CREATE INDEX IF NOT EXISTS idx_officer_tasks_context_slug
  ON officer_tasks(context_slug)
  WHERE context_slug IS NOT NULL;

-- Auto-touch updated_at on every UPDATE
CREATE OR REPLACE FUNCTION officer_tasks_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS officer_tasks_touch_updated_at ON officer_tasks;
CREATE TRIGGER officer_tasks_touch_updated_at
  BEFORE UPDATE ON officer_tasks
  FOR EACH ROW EXECUTE FUNCTION officer_tasks_touch_updated_at();
