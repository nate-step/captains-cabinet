-- cabinet/sql/session-memories-context-slug.sql
-- Phase 2 CP5 — Add context_slug to session_memories so split-cabinet.sh
-- can restamp them alongside other Cabinet-infrastructure tables.
-- Additive + idempotent.

ALTER TABLE session_memories
  ADD COLUMN IF NOT EXISTS context_slug TEXT;

CREATE INDEX IF NOT EXISTS session_memories_context_slug_idx
  ON session_memories(context_slug);
