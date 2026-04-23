-- Spec 037 Phase A — Library Notion/Obsidian-like UX
-- New tables: library_record_links, library_record_sections
-- Altered table: library_records (status + superseded_by_record_id)
-- Idempotent — safe to re-run.
--
-- Run:
--   psql "$NEON_CONNECTION_STRING" -f cabinet/sql/037-library-phase-a.sql

-- =============================================================
-- A5: Status field on library_records
-- =============================================================

ALTER TABLE library_records
  ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'draft',
  ADD COLUMN IF NOT EXISTS superseded_by_record_id BIGINT REFERENCES library_records(id) ON DELETE SET NULL;

-- Add CHECK constraint for status enum (only if it doesn't exist)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'library_records_status_check'
      AND conrelid = 'library_records'::regclass
  ) THEN
    ALTER TABLE library_records
      ADD CONSTRAINT library_records_status_check
      CHECK (status IN ('draft', 'in_review', 'approved', 'implemented', 'superseded'));
  END IF;
END $$;

-- Fast filter by status within a Space (sidebar + space list).
-- Partial predicate excludes OLD VERSIONS (records whose version has been
-- replaced by a newer one); status='superseded' records with
-- superseded_by IS NULL are the "latest version but retired by status" case
-- and are intentionally retained here so the sidebar can show them greyed.
CREATE INDEX IF NOT EXISTS idx_kb_records_status
  ON library_records (space_id, status)
  WHERE superseded_by IS NULL;

-- =============================================================
-- A1/A2: library_record_links — wikilink index for backlinks panel
-- =============================================================

CREATE TABLE IF NOT EXISTS library_record_links (
  id BIGSERIAL PRIMARY KEY,
  source_record_id BIGINT NOT NULL REFERENCES library_records(id) ON DELETE CASCADE,
  target_record_id BIGINT NOT NULL REFERENCES library_records(id) ON DELETE CASCADE,
  link_text TEXT NOT NULL,
  link_context TEXT,       -- ±40 chars around the link for backlink preview
  link_position INTEGER NOT NULL DEFAULT 0, -- nth occurrence in source (for scroll-anchor)
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_lrl_target
  ON library_record_links(target_record_id);

CREATE INDEX IF NOT EXISTS idx_lrl_source
  ON library_record_links(source_record_id);

-- =============================================================
-- A6: library_record_sections — stable heading anchors
-- =============================================================

CREATE TABLE IF NOT EXISTS library_record_sections (
  record_id BIGINT NOT NULL REFERENCES library_records(id) ON DELETE CASCADE,
  section_slug TEXT NOT NULL,
  heading_text TEXT NOT NULL,
  heading_level SMALLINT NOT NULL CHECK (heading_level BETWEEN 1 AND 6),
  PRIMARY KEY (record_id, section_slug)
);

-- v3.2 spec §4.7: drop vestigial position column (write-only-never-read;
-- scroll anchoring uses rendered DOM id on section_slug — drift-free).
-- IF EXISTS guard makes this idempotent on fresh schemas that never had it.
ALTER TABLE library_record_sections DROP COLUMN IF EXISTS position;

CREATE INDEX IF NOT EXISTS idx_lrs_slug
  ON library_record_sections(record_id, section_slug);
