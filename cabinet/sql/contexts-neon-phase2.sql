-- cabinet/sql/contexts-neon-phase2.sql
-- Phase 2: extend context_slug column to library_spaces.
--
-- Background: contexts-neon-phase1.sql (2026-04-16) added context_slug to
-- cabinet_memory + library_records, but missed library_spaces. The pool-
-- architecture greenlight (Captain msg 2160, 2026-04-28) requires every
-- project-scoped table to carry a slug so multi-project cabinets can split
-- cleanly. Sensed-vs-framework Spaces commingle in the same row-set today,
-- which blocks the planned `split-cabinet.sh --project sensed` migration.
--
-- Pattern follows phase1 (additive + idempotent + nullable). NOT NULL
-- constraint applies in a future phase3 after operational backfill of
-- existing rows assigns a slug — same two-step pattern Spec 038 used for
-- officer_tasks. Rationale: NOT NULL on day 1 would refuse the legacy rows
-- and brick read-paths until backfill runs; nullable + indexed lets
-- write-paths start tagging new rows immediately while existing rows wait.
--
-- Run:
--   psql "$NEON_CONNECTION_STRING" -f cabinet/sql/contexts-neon-phase2.sql
--
-- Reversibility:
--   ALTER TABLE library_spaces DROP COLUMN IF EXISTS context_slug;
--   DROP INDEX IF EXISTS library_spaces_context_slug_idx;

ALTER TABLE library_spaces
  ADD COLUMN IF NOT EXISTS context_slug TEXT;

CREATE INDEX IF NOT EXISTS library_spaces_context_slug_idx
  ON library_spaces(context_slug);
