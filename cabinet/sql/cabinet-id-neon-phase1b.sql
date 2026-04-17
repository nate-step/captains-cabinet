-- cabinet/sql/cabinet-id-neon-phase1b.sql
-- Phase 1 CP9b — Cabinet-id stamping for Cabinet-infrastructure tables
-- in product Neon. CP9 covered cabinet_memory + library_records; this
-- covers session_memories, cabinet_research (mirrors the cabinet-postgres
-- table), and library_spaces.
--
-- Additive + idempotent. DEFAULT 'main' backfills at column-add.

ALTER TABLE session_memories
  ADD COLUMN IF NOT EXISTS cabinet_id TEXT NOT NULL DEFAULT 'main';
CREATE INDEX IF NOT EXISTS session_memories_cabinet_idx ON session_memories(cabinet_id);

ALTER TABLE cabinet_research
  ADD COLUMN IF NOT EXISTS cabinet_id TEXT NOT NULL DEFAULT 'main';
CREATE INDEX IF NOT EXISTS cabinet_research_cabinet_idx ON cabinet_research(cabinet_id);

ALTER TABLE library_spaces
  ADD COLUMN IF NOT EXISTS cabinet_id TEXT NOT NULL DEFAULT 'main';
CREATE INDEX IF NOT EXISTS library_spaces_cabinet_idx ON library_spaces(cabinet_id);
