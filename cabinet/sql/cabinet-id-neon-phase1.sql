-- cabinet/sql/cabinet-id-neon-phase1.sql
-- Phase 1 CP9 — Cabinet identity, product Neon side.
--
-- Adds cabinet_id to cabinet_memory and library_records in product Neon.
-- Default 'main' for Phase 1.

ALTER TABLE cabinet_memory
  ADD COLUMN IF NOT EXISTS cabinet_id TEXT NOT NULL DEFAULT 'main';

ALTER TABLE library_records
  ADD COLUMN IF NOT EXISTS cabinet_id TEXT NOT NULL DEFAULT 'main';

CREATE INDEX IF NOT EXISTS cabinet_memory_cabinet_idx
  ON cabinet_memory(cabinet_id);

CREATE INDEX IF NOT EXISTS library_records_cabinet_idx
  ON library_records(cabinet_id);
