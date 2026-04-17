-- cabinet/sql/cabinet-id-phase1b.sql
-- Phase 1 CP9b — Extend cabinet_id stamping to the remaining Cabinet
-- infrastructure tables (cabinet postgres side). CP9 covered the hot path
-- (experience_records); CP9b covers the slower but still-officer-produced
-- tables so no Cabinet record can escape a Phase 2 split without identity.
--
-- Target tables (cabinet postgres): decision_log, skills, action_log,
-- research_archive, cabinet_research.
--
-- Additive + idempotent. DEFAULT 'main' backfills existing rows at
-- column-add time (Postgres 11+).

ALTER TABLE decision_log
  ADD COLUMN IF NOT EXISTS cabinet_id TEXT NOT NULL DEFAULT 'main';
CREATE INDEX IF NOT EXISTS decision_log_cabinet_idx ON decision_log(cabinet_id);

ALTER TABLE skills
  ADD COLUMN IF NOT EXISTS cabinet_id TEXT NOT NULL DEFAULT 'main';
CREATE INDEX IF NOT EXISTS skills_cabinet_idx ON skills(cabinet_id);

ALTER TABLE action_log
  ADD COLUMN IF NOT EXISTS cabinet_id TEXT NOT NULL DEFAULT 'main';
CREATE INDEX IF NOT EXISTS action_log_cabinet_idx ON action_log(cabinet_id);

ALTER TABLE research_archive
  ADD COLUMN IF NOT EXISTS cabinet_id TEXT NOT NULL DEFAULT 'main';
CREATE INDEX IF NOT EXISTS research_archive_cabinet_idx ON research_archive(cabinet_id);

ALTER TABLE cabinet_research
  ADD COLUMN IF NOT EXISTS cabinet_id TEXT NOT NULL DEFAULT 'main';
CREATE INDEX IF NOT EXISTS cabinet_research_cabinet_idx ON cabinet_research(cabinet_id);
