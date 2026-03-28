-- Cabinet Memory Database
-- PostgreSQL + pgvector for episodic memory and structured logs

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- Experience Records (Tier 3 episodic memory)
-- ============================================================
CREATE TABLE experience_records (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  officer VARCHAR(20) NOT NULL,
  task_summary TEXT NOT NULL,
  outcome VARCHAR(20) NOT NULL CHECK (outcome IN ('success', 'failure', 'partial', 'escalated')),
  what_happened TEXT NOT NULL,
  lessons_learned TEXT,
  tags TEXT[],
  embedding vector(1024),  -- Voyage 4 Large = 1024 dimensions
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_experience_officer ON experience_records(officer);
CREATE INDEX idx_experience_outcome ON experience_records(outcome);
CREATE INDEX idx_experience_created ON experience_records(created_at DESC);
CREATE INDEX idx_experience_tags ON experience_records USING GIN(tags);

-- ============================================================
-- Decision Log (Captain decisions for institutional memory)
-- ============================================================
CREATE TABLE decision_log (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  decision_summary TEXT NOT NULL,
  context TEXT,
  captain_response TEXT,
  officer_requesting VARCHAR(20),
  embedding vector(1024),
  decided_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_decisions_date ON decision_log(decided_at DESC);

-- ============================================================
-- Research Archive (CRO research artifacts)
-- ============================================================
CREATE TABLE research_archive (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  title TEXT NOT NULL,
  topic VARCHAR(100),
  brief_summary TEXT NOT NULL,
  full_content TEXT,
  sources TEXT[],
  tags TEXT[],
  embedding vector(1024),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_research_topic ON research_archive(topic);
CREATE INDEX idx_research_created ON research_archive(created_at DESC);
CREATE INDEX idx_research_tags ON research_archive USING GIN(tags);

-- ============================================================
-- Action Log (structured logs from hooks)
-- ============================================================
CREATE TABLE action_log (
  id BIGSERIAL PRIMARY KEY,
  officer VARCHAR(20) NOT NULL,
  tool_name VARCHAR(50) NOT NULL,
  tool_input JSONB,
  output_preview TEXT,
  cost_estimate_cents INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX idx_actions_officer ON action_log(officer);
CREATE INDEX idx_actions_created ON action_log(created_at DESC);
CREATE INDEX idx_actions_tool ON action_log(tool_name);

-- Partition action_log by month for easy cleanup
-- (manual partitioning — create new partitions monthly)

-- ============================================================
-- Skill Library Metadata
-- ============================================================
CREATE TABLE skills (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name VARCHAR(200) NOT NULL UNIQUE,
  description TEXT NOT NULL,
  file_path TEXT NOT NULL,
  validated BOOLEAN DEFAULT FALSE,
  validation_results JSONB,
  usage_count INTEGER DEFAULT 0,
  created_by VARCHAR(20),
  embedding vector(1024),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- Vector similarity search functions
-- ============================================================

-- Find similar experience records
CREATE OR REPLACE FUNCTION search_experiences(
  query_embedding vector(1024),
  match_count INTEGER DEFAULT 5,
  similarity_threshold FLOAT DEFAULT 0.7
)
RETURNS TABLE (
  id UUID,
  officer VARCHAR,
  task_summary TEXT,
  outcome VARCHAR,
  lessons_learned TEXT,
  similarity FLOAT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    e.id, e.officer, e.task_summary, e.outcome, e.lessons_learned,
    1 - (e.embedding <=> query_embedding) AS similarity
  FROM experience_records e
  WHERE e.embedding IS NOT NULL
    AND 1 - (e.embedding <=> query_embedding) > similarity_threshold
  ORDER BY e.embedding <=> query_embedding
  LIMIT match_count;
END;
$$ LANGUAGE plpgsql;

-- Find similar research
CREATE OR REPLACE FUNCTION search_research(
  query_embedding vector(1024),
  match_count INTEGER DEFAULT 5,
  similarity_threshold FLOAT DEFAULT 0.7
)
RETURNS TABLE (
  id UUID,
  title TEXT,
  topic VARCHAR,
  brief_summary TEXT,
  similarity FLOAT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    r.id, r.title, r.topic, r.brief_summary,
    1 - (r.embedding <=> query_embedding) AS similarity
  FROM research_archive r
  WHERE r.embedding IS NOT NULL
    AND 1 - (r.embedding <=> query_embedding) > similarity_threshold
  ORDER BY r.embedding <=> query_embedding
  LIMIT match_count;
END;
$$ LANGUAGE plpgsql;

-- Find relevant skills
CREATE OR REPLACE FUNCTION search_skills(
  query_embedding vector(1024),
  match_count INTEGER DEFAULT 3
)
RETURNS TABLE (
  id UUID,
  name VARCHAR,
  description TEXT,
  file_path TEXT,
  similarity FLOAT
) AS $$
BEGIN
  RETURN QUERY
  SELECT
    s.id, s.name, s.description, s.file_path,
    1 - (s.embedding <=> query_embedding) AS similarity
  FROM skills s
  WHERE s.embedding IS NOT NULL AND s.validated = TRUE
  ORDER BY s.embedding <=> query_embedding
  LIMIT match_count;
END;
$$ LANGUAGE plpgsql;
