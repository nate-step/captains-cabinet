-- The Library — Captain's Cabinet structured-edit layer
-- User-defined Spaces with schemas, versioned records, full CRUD.
-- Complements cabinet_memory (universal search layer): same infrastructure,
-- different surface. Library records also get indexed into cabinet_memory
-- on create/update via the post-file-write-memory hook equivalent.
--
-- Target: Neon PostgreSQL (or any PG >= 15 with pgvector >= 0.5.0).
-- Idempotent — safe to re-run.
--
-- Run:
--   psql "$NEON_CONNECTION_STRING" -f cabinet/sql/library.sql

CREATE EXTENSION IF NOT EXISTS vector;

-- =============================================================
-- library_spaces — user-defined collections
-- =============================================================
CREATE TABLE IF NOT EXISTS library_spaces (
  id BIGSERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  description TEXT,
  schema_json JSONB DEFAULT '{}'::jsonb,   -- field definitions: {"fields": [{"name":"priority","type":"select","options":[...]}, ...]}
  starter_template TEXT,                    -- 'blank', 'issues', 'business_brain', 'research_archive', ...
  owner VARCHAR(32),                        -- officer or captain who created the Space
  access_rules JSONB DEFAULT '{}'::jsonb,   -- {"read": ["*"], "write": ["cos","cto"], "comment": ["*"]}
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- =============================================================
-- library_records — the actual knowledge records
-- =============================================================
CREATE TABLE IF NOT EXISTS library_records (
  id BIGSERIAL PRIMARY KEY,
  space_id BIGINT NOT NULL REFERENCES library_spaces(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  content_markdown TEXT DEFAULT '',
  schema_data JSONB DEFAULT '{}'::jsonb,    -- custom fields per Space schema
  labels TEXT[] DEFAULT ARRAY[]::TEXT[],    -- freeform tags, work cross-Space
  embedding VECTOR(1024),                   -- voyage-4-large on title + content + schema_data summary
  version INT DEFAULT 1,
  superseded_by BIGINT REFERENCES library_records(id),  -- pointer to newer version; NULL = active record
  created_by_officer VARCHAR(16),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Idempotent ingestion — a Space's natural key is its name.
-- Records get a globally unique id; no natural-key UPSERT at the record level.
-- Record revisions happen via explicit UPDATE with version++, not via INSERT...ON CONFLICT.

-- Per-Space listing: scan active records in a Space, newest first
CREATE INDEX IF NOT EXISTS idx_lr_space_active
  ON library_records(space_id, created_at DESC)
  WHERE superseded_by IS NULL;

-- Label filtering (cross-Space queries like "everything tagged blocker")
CREATE INDEX IF NOT EXISTS idx_lr_labels
  ON library_records USING GIN(labels);

-- Semantic search (cosine distance over voyage-4-large)
CREATE INDEX IF NOT EXISTS idx_lr_embedding
  ON library_records USING hnsw (embedding vector_cosine_ops);

-- JSONB filter (e.g. schema_data->>'priority' = 'P1')
CREATE INDEX IF NOT EXISTS idx_lr_schema_data
  ON library_records USING GIN(schema_data);

-- Version history lookups (rare but should still be fast)
CREATE INDEX IF NOT EXISTS idx_lr_superseded
  ON library_records(superseded_by)
  WHERE superseded_by IS NOT NULL;

-- Maintain updated_at automatically on UPDATE
CREATE OR REPLACE FUNCTION library_records_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS library_records_touch_updated_at ON library_records;
CREATE TRIGGER library_records_touch_updated_at
  BEFORE UPDATE ON library_records
  FOR EACH ROW EXECUTE FUNCTION library_records_touch_updated_at();

CREATE OR REPLACE FUNCTION library_spaces_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS library_spaces_touch_updated_at ON library_spaces;
CREATE TRIGGER library_spaces_touch_updated_at
  BEFORE UPDATE ON library_spaces
  FOR EACH ROW EXECUTE FUNCTION library_spaces_touch_updated_at();
