-- cabinet/sql/044-library-embedding-hardening.sql
-- Spec 044 v2 Phase 1 — Library embedding hardening (SQL surface).
--
-- Adds:
--   1. embedded_at TIMESTAMPTZ NULL on library_records — staleness tracking.
--   2. BEFORE UPDATE trigger that clears embedding + embedded_at when
--      content_markdown or title changes, forcing re-embed-on-edit on next
--      embedding pass. Records currently keep stale embeddings if title or
--      content is edited; this trigger closes Gap 1 from Spec 044 v2.
--
-- Reversibility: drop the column + revert the trigger (keep the existing
-- updated_at trigger untouched). Idempotent CREATEs throughout.
--
-- Apply to:
--   - Sensed Neon (Work Cabinet) — where library_records lives today.
--   - Personal cabinet_memory (when Spec 044 v2 Gap 5 dual-bootstrap ships).
--
-- App-side follow-up (Spec 044 v2 Phase 2):
--   - createRecord / updateRecord write embedded_at = NOW() after a
--     successful Voyage embed (cabinet/dashboard/src/lib/library.ts).
--   - Embedding pipeline JSONL cost log at cabinet/logs/library-embeddings.jsonl.

-- =============================================================
-- Column: embedded_at
-- =============================================================
-- NULL for records that haven't been embedded yet (or were just edited
-- and cleared by the re-embed trigger). NOT NULL means embedding is
-- current as of the timestamp.
ALTER TABLE library_records
  ADD COLUMN IF NOT EXISTS embedded_at TIMESTAMPTZ NULL;

-- Backfill existing rows that already have an embedding but no timestamp.
-- One-shot: rows with embedding NOT NULL get embedded_at = updated_at as
-- a best-guess provenance; future writes set NOW() via app-side code.
UPDATE library_records
SET embedded_at = updated_at
WHERE embedding IS NOT NULL
  AND embedded_at IS NULL;

-- Optional partial index for "what needs re-embedding" scans (e.g. a future
-- embed-tick cron). Keep it lean — only rows that need work are indexed.
CREATE INDEX IF NOT EXISTS idx_lr_pending_embed
  ON library_records(updated_at)
  WHERE embedding IS NULL;

-- =============================================================
-- Trigger: re-embed-on-edit
-- =============================================================
-- Fires BEFORE UPDATE OF content_markdown OR title. When either changes,
-- clear embedding + embedded_at so the existing pipeline (sync-after-write
-- in dashboard/src/lib/library.ts, or any future cron drainer) re-embeds
-- on next save. Pure SQL — no app-side state, no race conditions.
--
-- Note: the existing library_records_touch_updated_at trigger ALSO fires
-- BEFORE UPDATE (any column). Postgres trigger ordering is alphabetical by
-- name; library_records_clear_embedding sorts before *_touch_*, so it
-- runs first. NEW.embedding/embedded_at = NULL takes effect; then
-- *_touch_* sets updated_at. Both compose cleanly.

CREATE OR REPLACE FUNCTION library_records_clear_embedding_on_content_change()
RETURNS TRIGGER AS $$
BEGIN
  -- IS DISTINCT FROM handles NULL on either side correctly (NULL = NULL → false here).
  IF NEW.content_markdown IS DISTINCT FROM OLD.content_markdown
     OR NEW.title IS DISTINCT FROM OLD.title
  THEN
    NEW.embedding   := NULL;
    NEW.embedded_at := NULL;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS library_records_clear_embedding_trg ON library_records;
CREATE TRIGGER library_records_clear_embedding_trg
  BEFORE UPDATE OF content_markdown, title ON library_records
  FOR EACH ROW EXECUTE FUNCTION library_records_clear_embedding_on_content_change();

-- =============================================================
-- Verification queries (run manually post-migration)
-- =============================================================
-- 1. Confirm column + index + trigger exist:
--    \d library_records
-- 2. Check backfill:
--    SELECT COUNT(*) FROM library_records WHERE embedding IS NOT NULL AND embedded_at IS NULL;
--    -- Expected: 0
-- 3. Smoke test the trigger:
--    BEGIN;
--    UPDATE library_records SET title = title || ' (test)' WHERE id = <some_id>;
--    SELECT id, title, embedding IS NULL AS embedding_cleared, embedded_at FROM library_records WHERE id = <some_id>;
--    -- Expected: embedding_cleared = true, embedded_at = NULL
--    ROLLBACK;
