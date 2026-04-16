-- cabinet/sql/contexts-neon-phase1.sql
-- Phase 1 CP1 — product Neon only.
--
-- Design (Captain 2026-04-16): no contexts DB table. YAML files at
-- instance/config/contexts/*.yml are source of truth. Target tables
-- carry a context_slug string; validation happens in pre-tool-use hook
-- (CP2) against the known slug list loaded from yaml at session start.
--
-- Additive + idempotent. Legacy rows stay NULL; new rows get a slug
-- at write time or fail validation.

ALTER TABLE cabinet_memory
  ADD COLUMN IF NOT EXISTS context_slug TEXT;

ALTER TABLE library_records
  ADD COLUMN IF NOT EXISTS context_slug TEXT;

CREATE INDEX IF NOT EXISTS cabinet_memory_context_slug_idx
  ON cabinet_memory(context_slug);

CREATE INDEX IF NOT EXISTS library_records_context_slug_idx
  ON library_records(context_slug);
