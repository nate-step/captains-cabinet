-- cabinet/sql/039-linear-to-tasks-schema.sql
-- Spec 039 Phase A — Additive schema extension to officer_tasks.
--
-- Extends the Spec 038 v1.2 baseline (cabinet/sql/038-officer-tasks.sql)
-- with first-class columns for the Linear → /tasks migration across three
-- Cabinet contexts (sensed / cabinet-framework / personal). All changes are
-- ADDITIVE — no column rename, no type narrowing, no destructive DDL. Safe
-- to re-run (idempotent).
--
-- Architecture notes (COO consolidation 2026-04-21, post-adversary Fix-B1):
--
--   Bypassable invariants are BEFORE INSERT OR UPDATE triggers reading
--   current_setting(..., true) — NOT CHECK constraints. CHECK constraints
--   cannot be bypassed via SET LOCAL session variables; they fire on every
--   write. The ETL needs a session-scoped escape hatch to land historical
--   rows that lack due_date / decision_ref, so those invariants are
--   declared as triggers mirroring Spec 038's enforce_officer_wip_limit.
--
--   Structural invariants (epic_no_parent, epic_cannot_ref_self) are pure
--   CHECKs — no bypass path needed. Shipped via ADD CONSTRAINT … NOT VALID
--   + DO $$ VALIDATE CONSTRAINT block so pre-existing rows don't block
--   migration (C-1 pattern absorbed from CTO tech-pass).
--
-- Target: Cabinet Postgres (same DB as officer_tasks, experience_records,
-- library_records). Registered in cabinet/scripts/load-preset.sh Neon
-- loop for cold-start idempotency.
--
-- Dependencies: cabinet/sql/038-officer-tasks.sql must be applied first
-- (officer_tasks + officer_task_history tables, bump_officer_tasks_updated_at
-- function). Load-preset ordering guarantees this.

-- =============================================================
-- 1. ADD COLUMNS (10 new + cancelled_at per COO B-2 resolution)
-- =============================================================
-- All columns nullable-by-default or boolean-default-false to preserve
-- back-compat with Spec 038 v1.2 rows (zero existing rows at migration
-- time per PR #37 commit message; this is defensive for future re-runs).

ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS priority TEXT;
ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS type TEXT NOT NULL DEFAULT 'task';
-- parent_epic_ref: no ON DELETE clause = NO ACTION (Postgres default). H-6 policy
-- per CPO v1.1 §4: epics never DELETE — obsolete epics transition to
-- status='cancelled' so children retain attribution + history lineage. Any
-- attempt to DELETE a referenced epic row will raise a foreign-key violation,
-- which is the desired failure mode (app-layer callers must cancel instead).
ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS parent_epic_ref BIGINT REFERENCES officer_tasks(id);
ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS founder_action BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS due_date DATE;
ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS captain_decision BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS decision_ref TEXT;
ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS external_ref TEXT;
ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS external_source TEXT;
ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS pr_url TEXT;
ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS cancelled_at TIMESTAMPTZ;

-- Relax officer_slug NOT NULL. Spec 039 §5.A1 mandates officer_slug=NULL for
-- synthesized epic rows (`type='epic'`) and unassigned issues from Linear/GH.
-- 038 baseline declared the column NOT NULL when /tasks was native-only; the
-- migration surface requires a NULL state for un-attributed rows. Idempotent —
-- ALTER … DROP NOT NULL succeeds whether or not the column was NOT NULL.
ALTER TABLE officer_tasks ALTER COLUMN officer_slug DROP NOT NULL;

-- =============================================================
-- 2. Column-level CHECK constraints (enum guards)
-- =============================================================
-- These are pure column-shape invariants — safe to add inline since
-- all existing rows have NULL for these new cols, which satisfies
-- the "OR … IS NULL" disjunct in each constraint.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'officer_tasks'::regclass
       AND conname = 'officer_tasks_priority_check'
  ) THEN
    ALTER TABLE officer_tasks
      ADD CONSTRAINT officer_tasks_priority_check
      CHECK (priority IN ('P0','P1','P2','P3') OR priority IS NULL);
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'officer_tasks'::regclass
       AND conname = 'officer_tasks_type_check'
  ) THEN
    ALTER TABLE officer_tasks
      ADD CONSTRAINT officer_tasks_type_check
      CHECK (type IN ('task','epic'));
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'officer_tasks'::regclass
       AND conname = 'officer_tasks_external_source_check'
  ) THEN
    ALTER TABLE officer_tasks
      ADD CONSTRAINT officer_tasks_external_source_check
      CHECK (external_source IN ('linear','github-issues','claude-tasks','native') OR external_source IS NULL);
  END IF;
END $$;

-- =============================================================
-- 3. Structural CHECK constraints (epic hierarchy invariants)
-- =============================================================
-- These are structural — no bypass path needed. Ship via NOT VALID to
-- avoid blocking migration on hypothetical pre-existing violating rows,
-- then VALIDATE in the same migration after zero-row scan guarantees
-- no existing row violates (safe since all existing rows have type='task'
-- default and parent_epic_ref NULL post-ADD-COLUMN).

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'officer_tasks'::regclass
       AND conname = 'epic_no_parent'
  ) THEN
    ALTER TABLE officer_tasks
      ADD CONSTRAINT epic_no_parent
      CHECK (NOT (type = 'epic' AND parent_epic_ref IS NOT NULL))
      NOT VALID;
  END IF;
END $$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'officer_tasks'::regclass
       AND conname = 'epic_cannot_ref_self'
  ) THEN
    ALTER TABLE officer_tasks
      ADD CONSTRAINT epic_cannot_ref_self
      CHECK (parent_epic_ref IS NULL OR id <> parent_epic_ref)
      NOT VALID;
  END IF;
END $$;

-- Validate structural CHECKs against existing rows (no-op if already validated
-- or if table is empty, which is the expected state at first run).
ALTER TABLE officer_tasks VALIDATE CONSTRAINT epic_no_parent;
ALTER TABLE officer_tasks VALIDATE CONSTRAINT epic_cannot_ref_self;

-- =============================================================
-- 4. Bypassable trigger: founder_action_requires_due_date (COO Fix-B1)
-- =============================================================
-- Fires BEFORE INSERT OR UPDATE. Enforces that any forward-going row
-- flagged founder_action has a due_date. Bypassable for historical ETL
-- rows via `SET LOCAL app.etl.suspend_founder_check = 'true'`.
--
-- "Forward-going" = status IN ('queue','wip') AND NOT blocked.
-- Done / cancelled / blocked rows are historical — no commitment needed.

CREATE OR REPLACE FUNCTION enforce_founder_action_due_date() RETURNS TRIGGER AS $$
BEGIN
  IF current_setting('app.etl.suspend_founder_check', true) = 'true' THEN
    RETURN NEW;
  END IF;

  IF NEW.founder_action
     AND NEW.status IN ('queue','wip')
     AND NOT NEW.blocked
     AND NEW.due_date IS NULL THEN
    RAISE EXCEPTION 'founder_action requires due_date on forward-going rows (task id=%, officer=%)',
                    COALESCE(NEW.id::text, '<new>'), NEW.officer_slug
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_enforce_founder_action_due_date ON officer_tasks;
CREATE TRIGGER trg_enforce_founder_action_due_date
  BEFORE INSERT OR UPDATE ON officer_tasks
  FOR EACH ROW EXECUTE FUNCTION enforce_founder_action_due_date();

-- =============================================================
-- 5. Bypassable trigger: captain_decision_requires_ref (COO Fix-B1)
-- =============================================================
-- Captain-decision flag must cross-ref a captain-decisions.md entry.
-- ETL flips flag from Linear label but decision_ref backfill is a
-- separate CoS/CPO pass post-ETL, so the trigger honors the bypass.

CREATE OR REPLACE FUNCTION enforce_captain_decision_ref() RETURNS TRIGGER AS $$
BEGIN
  IF current_setting('app.etl.suspend_captain_decision_check', true) = 'true' THEN
    RETURN NEW;
  END IF;

  IF NEW.captain_decision AND NEW.decision_ref IS NULL THEN
    RAISE EXCEPTION 'captain_decision requires decision_ref (task id=%, officer=%)',
                    COALESCE(NEW.id::text, '<new>'), NEW.officer_slug
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_enforce_captain_decision_ref ON officer_tasks;
CREATE TRIGGER trg_enforce_captain_decision_ref
  BEFORE INSERT OR UPDATE ON officer_tasks
  FOR EACH ROW EXECUTE FUNCTION enforce_captain_decision_ref();

-- =============================================================
-- 6. Extend Spec 038's bump_officer_tasks_updated_at (H-5)
-- =============================================================
-- Spec 038's trigger unconditionally bumps updated_at on every UPDATE.
-- Spec 039 ETL needs to preserve Linear/GH source `updatedAt` values so
-- reconstructed history is accurate. Adds honored bypass via
-- `SET LOCAL app.etl.suppress_bump = 'true'`.
--
-- CREATE OR REPLACE preserves the existing trigger binding (trigger was
-- created in 038; we only replace the underlying function body). No
-- need to DROP/CREATE the trigger itself.

CREATE OR REPLACE FUNCTION bump_officer_tasks_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  IF current_setting('app.etl.suppress_bump', true) = 'true' THEN
    RETURN NEW;
  END IF;
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================
-- 6b. Extend Spec 038's enforce_officer_wip_limit with ETL bypass
-- =============================================================
-- Historical Linear issues in "In Progress" state for an officer already at
-- WIP=3 cap must still land — the cap is a forward-going governance lever,
-- not a historical constraint. Adds honored bypass via
-- `SET LOCAL app.etl.suspend_wip_limit = 'true'`.
--
-- CREATE OR REPLACE preserves the existing trigger binding (trg_enforce_officer_wip
-- created in 038); we only replace the underlying function body. Registry extended
-- in spec §4.2.1 (session-var bypass table).

CREATE OR REPLACE FUNCTION enforce_officer_wip_limit() RETURNS TRIGGER AS $$
BEGIN
  IF current_setting('app.etl.suspend_wip_limit', true) = 'true' THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'wip' THEN
    PERFORM pg_advisory_xact_lock(
      hashtextextended(NEW.context_slug || '/' || NEW.officer_slug, 42)
    );

    IF (
      SELECT COUNT(*) FROM officer_tasks
       WHERE context_slug = NEW.context_slug
         AND officer_slug = NEW.officer_slug
         AND status = 'wip'
         AND (TG_OP = 'INSERT' OR id <> NEW.id)
    ) >= 3 THEN
      RAISE EXCEPTION 'WIP limit (3) exceeded for officer % in context %',
                      NEW.officer_slug, NEW.context_slug
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- =============================================================
-- 7. Indexes — CREATE INDEX CONCURRENTLY in separate statements
-- =============================================================
-- COO ask-list item 18: "All 5 new indexes declared via CREATE INDEX
-- CONCURRENTLY in separate transactions (one-per-index migration script;
-- not batched inside a single BEGIN…COMMIT)." psql applies these as
-- individual statements without an outer transaction, so CONCURRENTLY
-- is safe. IF NOT EXISTS keeps the migration idempotent.

CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS idx_officer_tasks_external
  ON officer_tasks(external_source, external_ref)
  WHERE external_ref IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_officer_tasks_priority
  ON officer_tasks(context_slug, priority)
  WHERE status <> 'done';

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_officer_tasks_parent_epic
  ON officer_tasks(parent_epic_ref)
  WHERE parent_epic_ref IS NOT NULL;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_officer_tasks_founder_action
  ON officer_tasks(context_slug, status)
  WHERE founder_action = TRUE;

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_officer_tasks_captain_decision
  ON officer_tasks(context_slug, created_at)
  WHERE captain_decision = TRUE;
