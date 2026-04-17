-- Spec 034: Cabinet Provisioning — DB migration
-- Creates: cabinets, cabinet_provisioning_events, migrations_applied
-- Idempotent — safe to re-run.
--
-- Run:
--   psql "$NEON_CONNECTION_STRING" -f cabinet/sql/2026-04-17-spec-034-provisioning-schema.sql

-- =============================================================
-- cabinets — one row per provisioned Cabinet
-- =============================================================
CREATE TABLE IF NOT EXISTS cabinets (
  cabinet_id          TEXT PRIMARY KEY,
  captain_id          TEXT NOT NULL,
  name                TEXT NOT NULL,
  preset              TEXT NOT NULL,
  capacity            TEXT NOT NULL,
  state               TEXT NOT NULL,
  state_entered_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  officer_slots       JSONB NOT NULL DEFAULT '[]'::jsonb,
  retry_count         INTEGER NOT NULL DEFAULT 0,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (captain_id, name)
);

CREATE INDEX IF NOT EXISTS idx_cabinets_captain_id
  ON cabinets(captain_id);

CREATE INDEX IF NOT EXISTS idx_cabinets_state
  ON cabinets(state, state_entered_at);

-- =============================================================
-- cabinet_provisioning_events — full audit trail
-- =============================================================
CREATE TABLE IF NOT EXISTS cabinet_provisioning_events (
  event_id      BIGSERIAL PRIMARY KEY,
  cabinet_id    TEXT NOT NULL,
  timestamp     TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor         TEXT NOT NULL,
  entry_point   TEXT NOT NULL,
  event_type    TEXT NOT NULL,
  state_before  TEXT,
  state_after   TEXT,
  payload       JSONB NOT NULL DEFAULT '{}'::jsonb,
  error         TEXT
);

CREATE INDEX IF NOT EXISTS idx_cpe_cabinet_timestamp
  ON cabinet_provisioning_events(cabinet_id, timestamp DESC);

CREATE INDEX IF NOT EXISTS idx_cpe_event_type
  ON cabinet_provisioning_events(event_type);

-- =============================================================
-- migrations_applied — idempotency guard for split-cabinet.sh
-- =============================================================
CREATE TABLE IF NOT EXISTS migrations_applied (
  id                  BIGSERIAL PRIMARY KEY,
  job_id              TEXT NOT NULL,
  row_table           TEXT NOT NULL,
  row_id              TEXT NOT NULL,
  source_cabinet_id   TEXT NOT NULL,
  target_cabinet_id   TEXT NOT NULL,
  migrated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (job_id, row_table, row_id)
);

CREATE INDEX IF NOT EXISTS idx_ma_job_id
  ON migrations_applied(job_id);
