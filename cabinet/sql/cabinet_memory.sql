-- Cabinet Memory — Universal semantic-search layer
-- Indexes all text the Cabinet produces (Telegram DMs, officer triggers, captain decisions,
-- research briefs, skills, specs, reflections, etc.) as pgvector embeddings.
--
-- Target: Neon PostgreSQL (or any PG with pgvector >= 0.5.0).
-- Connection via $NEON_CONNECTION_STRING.
--
-- Run once per Cabinet deployment:
--   psql "$NEON_CONNECTION_STRING" -f cabinet/sql/cabinet_memory.sql

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS cabinet_memory (
  id BIGSERIAL PRIMARY KEY,
  source_type VARCHAR(32) NOT NULL,        -- telegram_dm, officer_trigger, captain_decision, etc.
  source_id TEXT,                           -- natural key (file path, message id); nullable
  officer VARCHAR(16),                      -- owning officer (if applicable)
  sender VARCHAR(16),                       -- originator (for triggers/messages)
  content TEXT NOT NULL,
  summary TEXT,                             -- optional short summary
  embedding VECTOR(1024),                   -- voyage-4-large
  metadata JSONB DEFAULT '{}'::jsonb,
  version INT DEFAULT 1,                    -- bumped on UPSERT conflict
  superseded_by BIGINT REFERENCES cabinet_memory(id),  -- soft-delete / versioning pointer
  created_at TIMESTAMPTZ DEFAULT NOW(),
  source_created_at TIMESTAMPTZ             -- when the source event happened (not when indexed)
);

-- Idempotent ingestion — re-running backfill or handling duplicate events is a no-op.
-- Partial index: unique only for live (non-superseded) rows with a natural key.
CREATE UNIQUE INDEX IF NOT EXISTS idx_cm_unique_source
  ON cabinet_memory(source_type, source_id)
  WHERE source_id IS NOT NULL AND superseded_by IS NULL;

-- Time-based filtering (e.g., "captain decisions in the last 7 days")
CREATE INDEX IF NOT EXISTS idx_cm_source
  ON cabinet_memory(source_type, source_created_at DESC);

-- Officer-scoped queries (e.g., "everything CRO said about pricing")
CREATE INDEX IF NOT EXISTS idx_cm_officer
  ON cabinet_memory(officer, source_created_at DESC);

-- Vector similarity search (cosine distance)
CREATE INDEX IF NOT EXISTS idx_cm_embed
  ON cabinet_memory USING hnsw (embedding vector_cosine_ops);
