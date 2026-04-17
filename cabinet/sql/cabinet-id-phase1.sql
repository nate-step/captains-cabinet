-- cabinet/sql/cabinet-id-phase1.sql
-- Phase 1 CP9 — Cabinet identity in structured logs.
--
-- Add a `cabinet_id` column to every table that carries officer-produced
-- records. Default 'main' for Phase 1 (single Cabinet). Phase 2 sets
-- CABINET_ID per instance so records remain queryable after splitting
-- into a Cabinet Suite.
--
-- Applied to both cabinet postgres (experience_records) and product
-- Neon (cabinet_memory, library_records) by load-preset.sh. Each file
-- is additive + idempotent.

ALTER TABLE experience_records
  ADD COLUMN IF NOT EXISTS cabinet_id TEXT NOT NULL DEFAULT 'main';

CREATE INDEX IF NOT EXISTS experience_records_cabinet_idx
  ON experience_records(cabinet_id);
