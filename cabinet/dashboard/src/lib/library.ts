/**
 * library.ts — Server-side library data access.
 * Mirrors the query shapes in library.sh but uses pg directly.
 * Semantic search calls Voyage AI REST API (same key as library.sh uses).
 */

import { query } from './db'

// ============================================================
// Types
// ============================================================

// Index signature on each row type — pg's QueryResultRow constraint requires
// Record<string, unknown>. Without it, TS strict mode rejects query<Row>() calls.
export interface LibrarySpace {
  [key: string]: unknown
  id: string
  name: string
  description: string | null
  schema_json: Record<string, unknown>
  starter_template: string | null
  owner: string | null
  access_rules: Record<string, unknown>
  created_at: string
  updated_at: string
  record_count: number
  latest_update: string | null
}

export interface LibraryRecord {
  [key: string]: unknown
  id: string
  space_id: string
  title: string
  content_markdown: string
  schema_data: Record<string, unknown>
  labels: string[]
  version: number
  superseded_by: string | null
  created_by_officer: string | null
  created_at: string
  updated_at: string
}

export interface LibraryRecordSummary {
  [key: string]: unknown
  id: string
  title: string
  labels: string[]
  preview: string
  version: number
  created_by_officer: string | null
  created_at: string
  updated_at: string
}

export interface SearchResult {
  [key: string]: unknown
  space_id: string
  record_id: string
  title: string
  similarity: number
  preview: string
  created_by_officer: string | null
  created_at: string
}

export interface VersionHistoryEntry {
  [key: string]: unknown
  id: string
  version: number
  title: string
  is_active: boolean
  created_at: string
}

// ============================================================
// Embedding via Voyage AI
// ============================================================

async function getEmbedding(text: string): Promise<number[] | null> {
  const apiKey = process.env.VOYAGE_API_KEY
  if (!apiKey) return null

  const response = await fetch('https://api.voyageai.com/v1/embeddings', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: 'voyage-4-large',
      input: [text],
    }),
  })

  if (!response.ok) return null

  const data = (await response.json()) as {
    data: { embedding: number[] }[]
  }
  return data.data?.[0]?.embedding ?? null
}

// ============================================================
// Spaces
// ============================================================

export async function listSpaces(): Promise<LibrarySpace[]> {
  return query<LibrarySpace>(`
    SELECT
      s.id::text,
      s.name,
      s.description,
      s.schema_json,
      s.starter_template,
      s.owner,
      s.access_rules,
      s.created_at::text,
      s.updated_at::text,
      COUNT(r.id)::int AS record_count,
      MAX(r.updated_at)::text AS latest_update
    FROM library_spaces s
    LEFT JOIN library_records r
      ON r.space_id = s.id AND r.superseded_by IS NULL
    GROUP BY s.id
    ORDER BY s.created_at DESC
  `)
}

export async function getSpace(id: string): Promise<LibrarySpace | null> {
  const rows = await query<LibrarySpace>(
    `
    SELECT
      s.id::text,
      s.name,
      s.description,
      s.schema_json,
      s.starter_template,
      s.owner,
      s.access_rules,
      s.created_at::text,
      s.updated_at::text,
      COUNT(r.id)::int AS record_count,
      MAX(r.updated_at)::text AS latest_update
    FROM library_spaces s
    LEFT JOIN library_records r
      ON r.space_id = s.id AND r.superseded_by IS NULL
    WHERE s.id = $1::bigint
    GROUP BY s.id
  `,
    [id]
  )
  return rows[0] ?? null
}

export async function createSpace(params: {
  name: string
  description?: string
  schema_json?: Record<string, unknown>
  starter_template?: string
  owner?: string
  access_rules?: Record<string, unknown>
}): Promise<LibrarySpace> {
  const rows = await query<LibrarySpace>(
    `
    INSERT INTO library_spaces (name, description, schema_json, starter_template, owner, access_rules)
    VALUES ($1, $2, $3::jsonb, $4, $5, $6::jsonb)
    ON CONFLICT (name) DO UPDATE SET
      description = EXCLUDED.description,
      schema_json = EXCLUDED.schema_json,
      access_rules = EXCLUDED.access_rules
    RETURNING
      id::text, name, description, schema_json, starter_template, owner, access_rules,
      created_at::text, updated_at::text,
      0 AS record_count, NULL AS latest_update
  `,
    [
      params.name,
      params.description ?? null,
      JSON.stringify(params.schema_json ?? {}),
      params.starter_template ?? 'blank',
      params.owner ?? 'captain',
      JSON.stringify(params.access_rules ?? {}),
    ]
  )
  return rows[0]
}

// ============================================================
// Records
// ============================================================

export async function listRecords(
  spaceId: string,
  opts?: { labels?: string[]; limit?: number; offset?: number }
): Promise<LibraryRecordSummary[]> {
  const limit = opts?.limit ?? 50
  const offset = opts?.offset ?? 0
  const labels = opts?.labels

  if (labels && labels.length > 0) {
    return query<LibraryRecordSummary>(
      `
      SELECT
        id::text,
        title,
        labels,
        left(regexp_replace(content_markdown, E'[\\t\\n\\r]+', ' ', 'g'), 120) AS preview,
        version,
        created_by_officer,
        created_at::text,
        updated_at::text
      FROM library_records
      WHERE space_id = $1::bigint
        AND superseded_by IS NULL
        AND labels && $2::text[]
      ORDER BY created_at DESC
      LIMIT $3 OFFSET $4
    `,
      [spaceId, labels, limit, offset]
    )
  }

  return query<LibraryRecordSummary>(
    `
    SELECT
      id::text,
      title,
      labels,
      left(regexp_replace(content_markdown, E'[\\t\\n\\r]+', ' ', 'g'), 120) AS preview,
      version,
      created_by_officer,
      created_at::text,
      updated_at::text
    FROM library_records
    WHERE space_id = $1::bigint
      AND superseded_by IS NULL
    ORDER BY created_at DESC
    LIMIT $2 OFFSET $3
  `,
    [spaceId, limit, offset]
  )
}

export async function getRecord(id: string): Promise<LibraryRecord | null> {
  const rows = await query<LibraryRecord>(
    `
    SELECT
      id::text,
      space_id::text,
      title,
      content_markdown,
      schema_data,
      labels,
      version,
      superseded_by::text,
      created_by_officer,
      created_at::text,
      updated_at::text
    FROM library_records
    WHERE id = $1::bigint
  `,
    [id]
  )
  return rows[0] ?? null
}

export async function createRecord(params: {
  space_id: string
  title: string
  content_markdown?: string
  schema_data?: Record<string, unknown>
  labels?: string[]
  created_by_officer?: string
  /** ISO 8601 timestamp to use as created_at instead of NOW(). Use for source-faithful imports. */
  created_at?: string
}): Promise<LibraryRecord> {
  // Try to get an embedding; if Voyage isn't available, insert without it
  const embedText = [
    params.title,
    params.content_markdown ?? '',
  ]
    .filter(Boolean)
    .join('\n\n')
    .trim()

  const embedding = embedText ? await getEmbedding(embedText) : null

  const rows = await query<LibraryRecord>(
    `
    INSERT INTO library_records
      (space_id, title, content_markdown, schema_data, labels, embedding, created_by_officer, created_at)
    VALUES
      ($1::bigint, $2, $3, $4::jsonb, $5::text[], $6, $7, COALESCE($8::timestamptz, NOW()))
    RETURNING
      id::text, space_id::text, title, content_markdown, schema_data, labels,
      version, superseded_by::text, created_by_officer, created_at::text, updated_at::text
  `,
    [
      params.space_id,
      params.title,
      params.content_markdown ?? '',
      JSON.stringify(params.schema_data ?? {}),
      params.labels ?? [],
      embedding ? `[${embedding.join(',')}]` : null,
      params.created_by_officer ?? 'captain',
      params.created_at ?? null,
    ]
  )
  return rows[0]
}

export async function updateRecord(
  id: string,
  params: {
    title: string
    content_markdown: string
    schema_data?: Record<string, unknown>
    labels?: string[]
    created_by_officer?: string
  }
): Promise<LibraryRecord> {
  // Compute embedding first — do not hold a row lock across a network call.
  const embedText = [params.title, params.content_markdown]
    .filter(Boolean)
    .join('\n\n')
    .trim()
  const embedding = embedText ? await getEmbedding(embedText) : null

  // Single atomic transaction: SELECT FOR UPDATE locks the old row so concurrent
  // updates serialize. Without the lock, two callers could both read version=N
  // and both insert version=N+1, creating a phantom "v2" with no parent pointer.
  const rows = await query<LibraryRecord>(
    `
    WITH locked AS (
      SELECT id, space_id, version
      FROM library_records
      WHERE id = $1::bigint AND superseded_by IS NULL
      FOR UPDATE
    ),
    inserted AS (
      INSERT INTO library_records
        (space_id, title, content_markdown, schema_data, labels, embedding, version, created_by_officer)
      SELECT
        locked.space_id,
        $2, $3, $4::jsonb, $5::text[], $6, locked.version + 1, NULLIF($7, '')
      FROM locked
      RETURNING
        id, space_id, title, content_markdown, schema_data, labels,
        version, superseded_by, created_by_officer, created_at, updated_at
    ),
    update_old AS (
      UPDATE library_records
      SET superseded_by = (SELECT id FROM inserted)
      WHERE id = (SELECT id FROM locked)
    )
    SELECT
      id::text, space_id::text, title, content_markdown, schema_data, labels,
      version, superseded_by::text, created_by_officer, created_at::text, updated_at::text
    FROM inserted
  `,
    [
      id,
      params.title,
      params.content_markdown,
      JSON.stringify(params.schema_data ?? {}),
      params.labels ?? [],
      embedding ? `[${embedding.join(',')}]` : null,
      params.created_by_officer ?? '',
    ]
  )
  if (!rows[0]) {
    throw new Error(`Record ${id} not found or already superseded`)
  }
  return rows[0]
}

export async function deleteRecord(id: string): Promise<boolean> {
  const rows = await query<{ id: string; [key: string]: unknown }>(
    `UPDATE library_records
     SET superseded_by = id
     WHERE id = $1::bigint AND superseded_by IS NULL
     RETURNING id::text`,
    [id]
  )
  return rows.length > 0
}

export async function getRecordHistory(id: string): Promise<VersionHistoryEntry[]> {
  // Walk the superseded_by chain: starting from the given id, find all records
  // in the same chain by traversing backwards (superseded_by pointers) and forwards.
  // Simpler approach: fetch all records in the same space with the same chain root.
  // We find the chain by collecting all superseded_by links.
  // Postgres recursive CTEs allow ONE recursive reference via UNION ALL —
  // multiple recursive arms produce "recursive reference to query X must not
  // appear within its non-recursive term" at runtime. So split the walk:
  // first find HEAD (walk forward through superseded_by pointers), then walk
  // backward from HEAD through the chain. Each row visited once per walk.
  const rows = await query<VersionHistoryEntry>(
    `
    WITH RECURSIVE
      forward AS (
        SELECT id, superseded_by
        FROM library_records
        WHERE id = $1::bigint
        UNION ALL
        SELECT r.id, r.superseded_by
        FROM library_records r
        JOIN forward f ON f.superseded_by = r.id
        WHERE r.superseded_by IS NULL OR r.id != r.superseded_by
      ),
      head AS (
        SELECT id FROM forward WHERE superseded_by IS NULL OR superseded_by = id
      ),
      chain AS (
        SELECT id, version, title, superseded_by, created_at
        FROM library_records
        WHERE id = (SELECT id FROM head)
        UNION ALL
        SELECT r.id, r.version, r.title, r.superseded_by, r.created_at
        FROM library_records r
        JOIN chain c ON r.superseded_by = c.id AND r.id != c.id
      )
    SELECT
      id::text,
      version,
      title,
      (superseded_by IS NULL) AS is_active,
      created_at::text
    FROM chain
    ORDER BY version DESC
  `,
    [id]
  )
  return rows
}

// ============================================================
// Semantic search
// ============================================================

export async function searchRecords(params: {
  query: string
  space_id?: string
  labels?: string[]
  limit?: number
}): Promise<SearchResult[]> {
  const embedding = await getEmbedding(params.query)
  if (!embedding) {
    // Fallback: plain text title search
    return query<SearchResult>(
      `
      SELECT
        space_id::text,
        id::text AS record_id,
        title,
        0 AS similarity,
        left(regexp_replace(content_markdown, E'[\\t\\n\\r]+', ' ', 'g'), 200) AS preview,
        created_by_officer,
        created_at::text
      FROM library_records
      WHERE superseded_by IS NULL
        AND ($1::bigint IS NULL OR space_id = $1::bigint)
        AND title ILIKE '%' || $2 || '%'
      LIMIT $3
    `,
      [params.space_id ?? null, params.query, params.limit ?? 10]
    )
  }

  const embeddingLiteral = `[${embedding.join(',')}]`

  if (params.labels && params.labels.length > 0) {
    return query<SearchResult>(
      `
      SELECT
        space_id::text,
        id::text AS record_id,
        title,
        round((1 - (embedding <=> $1::vector))::numeric, 3) AS similarity,
        left(regexp_replace(content_markdown, E'[\\t\\n\\r]+', ' ', 'g'), 200) AS preview,
        created_by_officer,
        created_at::text
      FROM library_records
      WHERE superseded_by IS NULL
        AND ($2::bigint IS NULL OR space_id = $2::bigint)
        AND labels && $3::text[]
      ORDER BY embedding <=> $1::vector
      LIMIT $4
    `,
      [embeddingLiteral, params.space_id ?? null, params.labels, params.limit ?? 10]
    )
  }

  return query<SearchResult>(
    `
    SELECT
      space_id::text,
      id::text AS record_id,
      title,
      round((1 - (embedding <=> $1::vector))::numeric, 3) AS similarity,
      left(regexp_replace(content_markdown, E'[\\t\\n\\r]+', ' ', 'g'), 200) AS preview,
      created_by_officer,
      created_at::text
    FROM library_records
    WHERE superseded_by IS NULL
      AND ($2::bigint IS NULL OR space_id = $2::bigint)
    ORDER BY embedding <=> $1::vector
    LIMIT $3
  `,
    [embeddingLiteral, params.space_id ?? null, params.limit ?? 10]
  )
}
