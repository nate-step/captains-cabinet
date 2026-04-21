-- cabinet/sql/038-officer-tasks.sql
-- Spec 038 v1.2 — officer_tasks table with per-(context,officer) WIP=3 cap.
--
-- v1.2 amendments (COO adversary MUST-FIX, CoS-ratified msg 1623):
--   038.1 — pg_advisory_xact_lock in enforce_officer_wip_limit so the COUNT
--           can't race under READ COMMITTED (previous version was violable).
--   038.4 — `blocked_state_coherent` CHECK: no blocked=true with status in
--           ('done','cancelled'). Plus tighter `blocked_needs_reason` with
--           length(blocked_reason) > 0 (weaker IS NOT NULL allowed '').
--   038.9 — officer_task_history append-only log, AFTER trigger.
--   038.10 — bump_officer_tasks_updated_at BEFORE UPDATE trigger (replaces
--            the previous officer_tasks_touch_updated_at; function renamed
--            to match spec-normative name).
--
-- v1.1 baseline: WIP limit 1→3 per officer; partial UNIQUE index replaced
-- with BEFORE-INSERT-OR-UPDATE trigger; `blocked` is a boolean overlay on
-- WIP rows (still counts toward cap); `status='blocked'` removed.
--
-- `context_slug` is NOT NULL per AC #21 (app-validated against
-- instance/config/contexts/*.yml; no FK per Cabinet decision 2026-04-16).
--
-- Idempotent — safe to re-run.
-- Target: Cabinet Postgres (same DB as experience_records, library_records).
--
-- Forward migration from v1 (parked) / v1.1 (never landed):
--   * DROP INDEX IF EXISTS idx_officer_tasks_wip_unique  (v1 partial UNIQUE)
--   * ADD COLUMN IF NOT EXISTS blocked                    (v1 had none)
--   * UPDATE status='blocked' → status='wip', blocked=true (v1 overlay)
--   * Tighten blocked_needs_reason CHECK to length > 0     (v1.1 had weaker)
--   * Add blocked_state_coherent CHECK                     (v1.2 new)
--   * Drop old officer_tasks_touch_updated_at trigger      (rename)

-- =============================================================
-- officer_tasks
-- =============================================================
CREATE TABLE IF NOT EXISTS officer_tasks (
  id BIGSERIAL PRIMARY KEY,
  officer_slug TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT,
  status TEXT NOT NULL CHECK (status IN ('queue', 'wip', 'done', 'cancelled')),
  blocked BOOLEAN NOT NULL DEFAULT false,
  blocked_reason TEXT,
  linked_url TEXT,
  linked_kind TEXT CHECK (linked_kind IN ('linear', 'github', 'library') OR linked_kind IS NULL),
  linked_id TEXT,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  context_slug TEXT NOT NULL,  -- Spec 038 v1.1 AC #21

  -- v1.2 038.4 tightening: blocked=true requires a non-empty reason string.
  CONSTRAINT blocked_needs_reason
    CHECK (blocked = false OR (blocked_reason IS NOT NULL AND length(blocked_reason) > 0)),

  -- v1.2 038.4 new: `blocked` is only coherent on pending work. A done or
  -- cancelled row cannot also be blocked — the block is moot once the task
  -- is finished. Enforced DB-side to stop blocked+done from polluting
  -- rollup (b) blocked counts even if app transitions miss the clear.
  CONSTRAINT blocked_state_coherent
    CHECK (blocked = false OR status IN ('queue', 'wip'))
);

-- --------------------------------------------------------------
-- Forward-migration fixups for developers who ran the v1 parked
-- migration locally. In any fresh environment these are no-ops.
-- --------------------------------------------------------------
DROP INDEX IF EXISTS idx_officer_tasks_wip_unique;
ALTER TABLE officer_tasks ADD COLUMN IF NOT EXISTS blocked BOOLEAN NOT NULL DEFAULT false;

-- If a developer's local DB has v1 `status='blocked'` rows, migrate to overlay.
UPDATE officer_tasks SET status = 'wip', blocked = true WHERE status = 'blocked';

-- v1.2 038.4 migrate: clear blocked on any existing done/cancelled rows so
-- the new blocked_state_coherent CHECK doesn't reject the ADD CONSTRAINT.
UPDATE officer_tasks
   SET blocked = false, blocked_reason = NULL
 WHERE blocked = true AND status IN ('done', 'cancelled');

-- v1.2 038.4 migrate: tighten blocked_needs_reason if a v1.1-era DB has the
-- weaker IS-NOT-NULL form. Drop the constraint by name if present; the CREATE
-- TABLE above will have added the tightened form on fresh installs.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'officer_tasks'::regclass
       AND conname = 'blocked_needs_reason'
       AND pg_get_constraintdef(oid) NOT LIKE '%length%'
  ) THEN
    ALTER TABLE officer_tasks DROP CONSTRAINT blocked_needs_reason;
    ALTER TABLE officer_tasks
      ADD CONSTRAINT blocked_needs_reason
      CHECK (blocked = false OR (blocked_reason IS NOT NULL AND length(blocked_reason) > 0));
  END IF;
END $$;

-- v1.2 038.4 migrate: add blocked_state_coherent if missing.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'officer_tasks'::regclass
       AND conname = 'blocked_state_coherent'
  ) THEN
    ALTER TABLE officer_tasks
      ADD CONSTRAINT blocked_state_coherent
      CHECK (blocked = false OR status IN ('queue', 'wip'));
  END IF;
END $$;

-- Drop the legacy status CHECK that included 'blocked' (if present).
DO $$
DECLARE
  constraint_name TEXT;
BEGIN
  SELECT conname INTO constraint_name
    FROM pg_constraint
   WHERE conrelid = 'officer_tasks'::regclass
     AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%blocked%done%'
   LIMIT 1;
  IF constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE officer_tasks DROP CONSTRAINT %I', constraint_name);
  END IF;
END $$;

-- Re-add v1.1 status CHECK if missing.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'officer_tasks'::regclass
       AND contype = 'c'
       AND pg_get_constraintdef(oid) = 'CHECK (status = ANY (ARRAY[''queue''::text, ''wip''::text, ''done''::text, ''cancelled''::text]))'
  ) THEN
    ALTER TABLE officer_tasks
      ADD CONSTRAINT officer_tasks_status_check
      CHECK (status IN ('queue', 'wip', 'done', 'cancelled'));
  END IF;
END $$;

-- =============================================================
-- WIP <= 3 per (context_slug, officer_slug) — enforced by trigger
-- =============================================================
-- The trigger is the hard invariant (§3.1 v1.2). API layer does a pre-check
-- for nicer error messages, but the trigger is the backstop.
--
-- v1.2 CRITICAL fix (COO 038.1): pg_advisory_xact_lock on a synthetic key
-- derived from (context, officer) serializes concurrent writers on the same
-- pair. Without it, two parallel INSERTs at count=2 both see 2 committed
-- rows under READ COMMITTED, both pass the check, both commit → count=4.
-- The lock is transaction-scoped (auto-released on commit/rollback), uses a
-- synthetic int8 key (no row contention), and is cheap.
CREATE OR REPLACE FUNCTION enforce_officer_wip_limit() RETURNS TRIGGER AS $$
BEGIN
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

DROP TRIGGER IF EXISTS trg_enforce_officer_wip ON officer_tasks;
CREATE TRIGGER trg_enforce_officer_wip
  BEFORE INSERT OR UPDATE OF status ON officer_tasks
  FOR EACH ROW EXECUTE FUNCTION enforce_officer_wip_limit();

-- =============================================================
-- Indexes
-- =============================================================

-- Hot-path dashboard query: boards grouped by (context,officer,status)
CREATE INDEX IF NOT EXISTS idx_officer_tasks_officer_status
  ON officer_tasks(context_slug, officer_slug, status);

-- Done-section query: newest-first within (context,officer,status=done)
CREATE INDEX IF NOT EXISTS idx_officer_tasks_completed
  ON officer_tasks(context_slug, officer_slug, completed_at DESC)
  WHERE status = 'done';

-- Blocked-overlay lookups — sparse by design
CREATE INDEX IF NOT EXISTS idx_officer_tasks_blocked
  ON officer_tasks(context_slug, officer_slug)
  WHERE blocked = true;

-- =============================================================
-- Auto-touch updated_at on every UPDATE (Spec 038 v1.2 / COO 038.10)
-- =============================================================
-- Renamed from officer_tasks_touch_updated_at for spec alignment; drop the
-- old trigger if present so a re-run doesn't double-fire.
DROP TRIGGER IF EXISTS officer_tasks_touch_updated_at ON officer_tasks;

CREATE OR REPLACE FUNCTION bump_officer_tasks_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_bump_officer_tasks_updated ON officer_tasks;
CREATE TRIGGER trg_bump_officer_tasks_updated
  BEFORE UPDATE ON officer_tasks
  FOR EACH ROW EXECUTE FUNCTION bump_officer_tasks_updated_at();

-- =============================================================
-- officer_task_history — append-only transition log (v1.2 / COO 038.9)
-- =============================================================
-- A dashboard that surfaces drift must also explain WHY drift happened.
-- Every status or blocked change writes one row here. `actor` comes from
-- the session variable `app.cabinet_officer`, set by API + my-tasks.sh.
CREATE TABLE IF NOT EXISTS officer_task_history (
  id BIGSERIAL PRIMARY KEY,
  task_id BIGINT NOT NULL REFERENCES officer_tasks(id) ON DELETE CASCADE,
  from_status TEXT,
  to_status TEXT,
  from_blocked BOOLEAN,
  to_blocked BOOLEAN,
  blocked_reason TEXT,
  actor TEXT NOT NULL,
  transition_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_officer_task_history_task
  ON officer_task_history(task_id, transition_at DESC);

CREATE OR REPLACE FUNCTION log_officer_task_transition() RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO officer_task_history
      (task_id, from_status, to_status, from_blocked, to_blocked, blocked_reason, actor)
    VALUES
      (NEW.id, NULL, NEW.status, NULL, NEW.blocked, NEW.blocked_reason,
       COALESCE(current_setting('app.cabinet_officer', TRUE), 'unknown'));
  ELSIF TG_OP = 'UPDATE' THEN
    IF NEW.status IS DISTINCT FROM OLD.status
       OR NEW.blocked IS DISTINCT FROM OLD.blocked THEN
      INSERT INTO officer_task_history
        (task_id, from_status, to_status, from_blocked, to_blocked, blocked_reason, actor)
      VALUES
        (NEW.id, OLD.status, NEW.status, OLD.blocked, NEW.blocked, NEW.blocked_reason,
         COALESCE(current_setting('app.cabinet_officer', TRUE), 'unknown'));
    END IF;
  END IF;
  RETURN NULL;  -- AFTER trigger, return value ignored
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_log_officer_task_transition ON officer_tasks;
CREATE TRIGGER trg_log_officer_task_transition
  AFTER INSERT OR UPDATE OF status, blocked ON officer_tasks
  FOR EACH ROW EXECUTE FUNCTION log_officer_task_transition();
