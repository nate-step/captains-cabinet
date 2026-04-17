-- presets/personal/schemas.sql
-- Personal preset additional schemas. Applied to product Neon by
-- load-preset.sh AFTER framework base schemas (cabinet_memory.sql,
-- library.sql, contexts-*, cabinet-id-*).
--
-- All tables additive + idempotent (CREATE TABLE IF NOT EXISTS).
-- Every table carries cabinet_id TEXT NOT NULL DEFAULT 'main' per
-- CP9+9b so rows remain queryable after a Phase 2 Cabinet split.
-- Every table carries context_slug TEXT per CP1 so capacity-coupling
-- enforcement works at the hook.
--
-- Table inventory:
--   longitudinal_metrics    — numeric time-series (sleep hours, HRV, weight, mood)
--   coaching_narratives     — agent-written notes on Captain's longitudinal arc
--   coaching_consent_log             — every consent granted / withdrawn / overridden
--   coaching_experiments    — tracked interventions with outcomes
--
-- Deletion pattern: personal safety-addendum requires HARD deletion on
-- Captain request. No soft-delete columns; rows are either there or
-- they aren't. Meta-log of deletions lives in coaching_narratives with
-- a fact-of-deletion entry.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ----------------------------------------------------------------
-- longitudinal_metrics
-- ----------------------------------------------------------------
-- Numeric time-series. Use this for anything you want to graph or
-- correlate over weeks/months. Source is opaque (HealthKit, manual
-- entry, third-party app) — the source slug lets queries filter.
CREATE TABLE IF NOT EXISTS longitudinal_metrics (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cabinet_id   TEXT NOT NULL DEFAULT 'main',
  context_slug TEXT NOT NULL DEFAULT 'personal',
  metric_name  TEXT NOT NULL,           -- e.g. 'sleep_hours', 'hrv_rmssd', 'weight_kg'
  source       TEXT NOT NULL,           -- e.g. 'healthkit', 'manual', 'oura'
  recorded_at  TIMESTAMPTZ NOT NULL,
  value        NUMERIC NOT NULL,
  unit         TEXT NOT NULL,           -- e.g. 'hours', 'ms', 'kg'
  metadata     JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS longitudinal_metrics_cabinet_idx
  ON longitudinal_metrics(cabinet_id);
CREATE INDEX IF NOT EXISTS longitudinal_metrics_metric_time_idx
  ON longitudinal_metrics(metric_name, recorded_at DESC);
CREATE INDEX IF NOT EXISTS longitudinal_metrics_source_idx
  ON longitudinal_metrics(source);

-- ----------------------------------------------------------------
-- coaching_narratives
-- ----------------------------------------------------------------
-- Agent-written notes. The "what the coach saw" record. Keep these
-- short-to-medium — narratives are not journal entries, they're
-- pattern observations with enough context to be useful next week.
-- Deletion meta-log entries also live here (kind='deletion').
CREATE TABLE IF NOT EXISTS coaching_narratives (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cabinet_id    TEXT NOT NULL DEFAULT 'main',
  context_slug  TEXT NOT NULL DEFAULT 'personal',
  coach_slug    TEXT NOT NULL,          -- physical-coach, mindfulness-coach, etc.
  kind          TEXT NOT NULL,          -- 'observation' | 'pattern' | 'handoff' | 'deletion'
  title         TEXT NOT NULL,
  body          TEXT,                   -- redacted per safety-addendum
  related_metrics UUID[] DEFAULT ARRAY[]::UUID[],
  tags          TEXT[] DEFAULT ARRAY[]::TEXT[],
  created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS coaching_narratives_cabinet_idx
  ON coaching_narratives(cabinet_id);
CREATE INDEX IF NOT EXISTS coaching_narratives_coach_kind_idx
  ON coaching_narratives(coach_slug, kind);
CREATE INDEX IF NOT EXISTS coaching_narratives_tags_idx
  ON coaching_narratives USING GIN (tags);

-- ----------------------------------------------------------------
-- coaching_consent_log
-- ----------------------------------------------------------------
-- Every consent decision Captain makes (or overrides). Read this
-- before any gated action. Written on every grant / withdrawal /
-- one-shot override. No soft-delete: revocation is a new row with
-- event='withdrawn', not a delete of the 'granted' row.
CREATE TABLE IF NOT EXISTS coaching_consent_log (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cabinet_id  TEXT NOT NULL DEFAULT 'main',
  context_slug TEXT NOT NULL DEFAULT 'personal',
  event       TEXT NOT NULL,            -- 'granted' | 'withdrawn' | 'override' | 'ask'
  scope       TEXT NOT NULL,            -- e.g. 'healthkit.read', 'pattern.publish'
  source      TEXT,                     -- data source if relevant
  granted_for TEXT,                     -- 'persistent' | 'one_shot' | 'session'
  granted_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  expires_at  TIMESTAMPTZ,              -- optional bounded consent
  notes       TEXT
);

CREATE INDEX IF NOT EXISTS coaching_consent_log_scope_time_idx
  ON coaching_consent_log(scope, granted_at DESC);
CREATE INDEX IF NOT EXISTS coaching_consent_log_cabinet_idx
  ON coaching_consent_log(cabinet_id);

-- ----------------------------------------------------------------
-- coaching_experiments
-- ----------------------------------------------------------------
-- Tracked interventions: one row per experiment. Required fields
-- prevent drive-by "try this" recommendations (safety-addendum §7).
CREATE TABLE IF NOT EXISTS coaching_experiments (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  cabinet_id     TEXT NOT NULL DEFAULT 'main',
  context_slug   TEXT NOT NULL DEFAULT 'personal',
  coach_slug     TEXT NOT NULL,
  hypothesis     TEXT NOT NULL,          -- "sleep improves if X"
  intervention   TEXT NOT NULL,          -- concrete action
  metric         TEXT NOT NULL,          -- what we're measuring (maps to longitudinal_metrics.metric_name)
  duration_days  INTEGER NOT NULL,
  started_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  ended_at       TIMESTAMPTZ,            -- NULL while running
  outcome        TEXT,                   -- 'positive' | 'null' | 'negative' | 'abandoned'
  outcome_notes  TEXT,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS coaching_experiments_cabinet_idx
  ON coaching_experiments(cabinet_id);
CREATE INDEX IF NOT EXISTS coaching_experiments_active_idx
  ON coaching_experiments(coach_slug, ended_at) WHERE ended_at IS NULL;
