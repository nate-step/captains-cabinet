-- cabinet/sql/contexts-cabinet-phase1.sql
-- Phase 1 CP1 — cabinet postgres only.
--
-- Design (Captain 2026-04-16): no contexts DB table. YAML files at
-- instance/config/contexts/*.yml are source of truth. Target tables
-- carry a context_slug string; validation happens in pre-tool-use hook
-- (CP2) against the known slug list loaded from yaml at session start.
--
-- Additive + idempotent. Legacy rows stay NULL; new rows get a slug
-- at write time or fail validation.

ALTER TABLE experience_records
  ADD COLUMN IF NOT EXISTS context_slug TEXT;

CREATE INDEX IF NOT EXISTS experience_records_context_slug_idx
  ON experience_records(context_slug);
