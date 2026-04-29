-- presets/step-network/schemas.sql
-- Step Network preset schemas — additive-only on top of framework/schemas-base.sql.
-- Mirrors `presets/work/schemas.sql` shape; adds pool-architecture support.

-- Captain decision log table — same shape as work preset (queryable history).
-- The markdown files (cabinet-local + framework-global per Spec 034 v3 §3.6)
-- remain as session-preload surface; this table is for queryable history.
CREATE TABLE IF NOT EXISTS captain_decisions (
  id BIGSERIAL PRIMARY KEY,
  decided_at DATE NOT NULL,
  decision TEXT NOT NULL,
  why TEXT NOT NULL,
  affected TEXT,
  domain VARCHAR(64),
  reversibility VARCHAR(32),
  affected_projects TEXT[],     -- Step Network addition: which projects this decision touches
  scope VARCHAR(32),             -- 'project' | 'cabinet' | 'framework' (Spec 034 v3 §3.6)
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cd_decided_at ON captain_decisions(decided_at DESC);
CREATE INDEX IF NOT EXISTS idx_cd_domain ON captain_decisions(domain);
CREATE INDEX IF NOT EXISTS idx_cd_scope ON captain_decisions(scope);

-- Session memories table (Cabinet pre-compact state snapshots) — same as work.
CREATE TABLE IF NOT EXISTS session_memories (
  id BIGSERIAL PRIMARY KEY,
  officer VARCHAR(32) NOT NULL,
  snapshot_type VARCHAR(32) NOT NULL,
  content TEXT,
  structured_state JSONB,
  active_project VARCHAR(64),    -- Step Network addition: per-tmux-window project context at snapshot time
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_sm_officer_created ON session_memories(officer, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sm_active_project ON session_memories(active_project) WHERE active_project IS NOT NULL;

-- Pool window registry — tracks which (officer, project) tmux windows are warm vs hibernated.
-- Backs the dashboard pool-state widget (Spec 034 v3 AC #46).
CREATE TABLE IF NOT EXISTS pool_windows (
  id BIGSERIAL PRIMARY KEY,
  officer VARCHAR(32) NOT NULL,
  project_slug VARCHAR(64) NOT NULL,
  state VARCHAR(32) NOT NULL CHECK (state IN ('warm', 'hibernating', 'hibernated', 'waking')),
  last_active_at TIMESTAMPTZ DEFAULT NOW(),
  rss_bytes BIGINT,                -- last-observed memory footprint
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (officer, project_slug)
);

CREATE INDEX IF NOT EXISTS idx_pool_state ON pool_windows(state);
CREATE INDEX IF NOT EXISTS idx_pool_lru ON pool_windows(last_active_at) WHERE state = 'warm';

-- Project switch audit log — every Captain project switch (per Captain or per officer)
-- recorded for retro analysis + active-project-queue debugging.
CREATE TABLE IF NOT EXISTS project_switches (
  id BIGSERIAL PRIMARY KEY,
  switched_at TIMESTAMPTZ DEFAULT NOW(),
  initiated_by VARCHAR(32) NOT NULL,    -- 'captain' | '<officer-slug>' | 'cron'
  from_project VARCHAR(64),
  to_project VARCHAR(64) NOT NULL,
  switch_method VARCHAR(32),            -- 'pool_select' | 'resume_warm_up' | 'cold_start'
  warm_up_seconds REAL,                 -- NULL for pool_select; populated for resume paths
  notes TEXT
);

CREATE INDEX IF NOT EXISTS idx_ps_switched_at ON project_switches(switched_at DESC);
CREATE INDEX IF NOT EXISTS idx_ps_to_project ON project_switches(to_project);
