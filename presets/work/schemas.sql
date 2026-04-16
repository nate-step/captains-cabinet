-- presets/work/schemas.sql
-- Additional database tables specific to the work preset.
-- Applied by the preset loader after framework/schemas-base.sql.
-- Additive-only per Captain directive 2026-04-16 — never DROP or MUTATE
-- existing framework tables.

-- Captain decision log table (persistent alternative to the markdown file)
-- The markdown file (shared/interfaces/captain-decisions.md) remains as
-- the session-preload surface; this table is for queryable history.
CREATE TABLE IF NOT EXISTS captain_decisions (
  id BIGSERIAL PRIMARY KEY,
  decided_at DATE NOT NULL,
  decision TEXT NOT NULL,
  why TEXT NOT NULL,
  affected TEXT,
  domain VARCHAR(64),
  reversibility VARCHAR(32),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cd_decided_at ON captain_decisions(decided_at DESC);
CREATE INDEX IF NOT EXISTS idx_cd_domain ON captain_decisions(domain);

-- Session memories table (Cabinet pre-compact state snapshots)
-- Used by post-compact.sh to preserve session context across compactions.
CREATE TABLE IF NOT EXISTS session_memories (
  id BIGSERIAL PRIMARY KEY,
  officer VARCHAR(32) NOT NULL,
  snapshot_type VARCHAR(32) NOT NULL,   -- 'pre-compact', 'post-compact', 'manual'
  content TEXT,
  structured_state JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sm_officer_created ON session_memories(officer, created_at DESC);
