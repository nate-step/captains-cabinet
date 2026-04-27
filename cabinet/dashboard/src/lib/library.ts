/**
 * library.ts — Server-side library data access.
 * Mirrors the query shapes in library.sh but uses pg directly.
 * Semantic search calls Voyage AI REST API (same key as library.sh uses).
 *
 * Spec 037 Phase A additions:
 *   - status field on LibraryRecord + LibraryRecordSummary
 *   - listRecordsForSidebar() — capped 20 per space for sidebar tree
 *   - updateRecord() now calls indexLinks() + indexSections() after save
 *   - createRecord() same
 *   - updateRecordStatus() — status state machine PATCH
 */

import { query } from './db'
import { indexLinks, indexSections } from './wikilinks'

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

// A5: Status enum values
export type RecordStatus = 'draft' | 'in_review' | 'approved' | 'implemented' | 'superseded'

// A5: Valid state transitions — v3.2 state machine (Spec 037 §12, AC #16)
// New reverse edges added in v3: in_review→draft (author rescind),
// approved→in_review (re-open after initial approval; review cycles aren't one-shot).
// Terminals: superseded→{} (strictly terminal), implemented→{superseded} only.
export const STATUS_TRANSITIONS: Record<RecordStatus, RecordStatus[]> = {
  draft:       ['in_review', 'superseded'],
  in_review:   ['draft', 'approved', 'superseded'],
  approved:    ['in_review', 'implemented', 'superseded'],
  implemented: ['superseded'],
  superseded:  [],
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
  // A5 additions
  status: RecordStatus
  superseded_by_record_id: string | null
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
  // A5
  status: RecordStatus
  created_by_officer: string | null
  created_at: string
  updated_at: string
}

// A4: Sidebar record type — lighter weight
export interface SidebarRecord {
  [key: string]: unknown
  id: string
  title: string
  status: RecordStatus
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

// Spec 044 v2 Phase 2 — getEmbedding logs cost data per call to a JSONL stream
// at LIBRARY_EMBED_LOG_PATH (default cabinet/logs/library-embeddings.jsonl).
// The log stream is per-cabinet runtime data (gitignored). Phase 3 weekly
// aggregator can roll it up to surface API spend.
//
// Failure mode: log-write errors are swallowed; never block the embed path
// or the surrounding record save.

async function logEmbeddingCost(
  recordId: string | null,
  tokens: number,
  latencyMs: number
): Promise<void> {
  try {
    const { appendFile } = await import('node:fs/promises')
    const logPath =
      process.env.LIBRARY_EMBED_LOG_PATH ??
      '/opt/founders-cabinet/cabinet/logs/library-embeddings.jsonl'
    const line = JSON.stringify({
      ts: new Date().toISOString(),
      record_id: recordId,
      tokens,
      latency_ms: latencyMs,
    })
    await appendFile(logPath, line + '\n')
  } catch {
    // Swallow — log path may not exist or fs access may be restricted.
  }
}

async function getEmbedding(
  text: string,
  recordId?: string | null
): Promise<number[] | null> {
  const apiKey = process.env.VOYAGE_API_KEY
  if (!apiKey) return null

  const start = Date.now()
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
  const latencyMs = Date.now() - start

  if (!response.ok) return null

  const data = (await response.json()) as {
    data: { embedding: number[] }[]
    usage?: { total_tokens?: number }
  }
  const embedding = data.data?.[0]?.embedding ?? null
  if (embedding) {
    // Voyage usually reports total_tokens; fall back to a rough char/4 estimate.
    const tokens = data.usage?.total_tokens ?? Math.round(text.length / 4)
    await logEmbeddingCost(recordId ?? null, tokens, latencyMs)
  }
  return embedding
}

// ============================================================
// Cabinet Memory integration — async, fire-and-forget
// Queues a library record into cabinet_memory via the Redis embed queue
// so cross-system search (memory_search) finds Library content.
// Uses the same XADD payload schema as memory.sh:memory_queue_embed.
// Non-blocking: never throws; logs on failure only.
// ============================================================

async function queueLibraryRecordInMemory(params: {
  recordId: string
  spaceId: string
  spaceName: string
  title: string
  content: string
  officer: string
  sourceCreatedAt?: string
}): Promise<void> {
  const redisHost = process.env.REDIS_HOST ?? 'redis'
  const redisPort = process.env.REDIS_PORT ?? '6379'
  const sourceId = `lib-${params.recordId}`
  const content = params.content.trim()
  if (!content) return

  const payload = JSON.stringify({
    source_type: 'library_record',
    source_id: sourceId,
    officer: params.officer,
    sender: '',
    content,
    metadata: {
      space_id: params.spaceId,
      space_name: params.spaceName,
      record_id: params.recordId,
    },
    source_ts: params.sourceCreatedAt ?? new Date().toISOString(),
  })

  // Best-effort: push to Redis Stream — memory-worker picks it up asynchronously.
  // Use execFile (not exec/shell string) so payload content cannot cause shell injection.
  try {
    const { execFile } = await import('node:child_process')
    execFile(
      'redis-cli',
      ['-h', redisHost, '-p', redisPort, 'XADD', 'cabinet:memory:embed_queue', '*', 'payload', payload],
      (err) => {
        if (err) console.error('[library] memory queue push failed:', err.message)
      }
    )
  } catch (err) {
    console.error('[library] memory queue push error:', err)
  }
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
        COALESCE(status, 'draft') AS status,
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
      COALESCE(status, 'draft') AS status,
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
      COALESCE(status, 'draft') AS status,
      superseded_by_record_id::text,
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

// A4: Sidebar — top 20 records per space ordered by updated_at
export async function listRecordsForSidebar(
  spaceId: string,
  opts?: { limit?: number; statusFilter?: RecordStatus[] }
): Promise<SidebarRecord[]> {
  const limit = opts?.limit ?? 20
  const statusFilter = opts?.statusFilter ?? ['draft', 'in_review', 'approved', 'implemented']

  return query<SidebarRecord>(
    `
    SELECT
      id::text,
      title,
      COALESCE(status, 'draft') AS status,
      updated_at::text
    FROM library_records
    WHERE space_id = $1::bigint
      AND superseded_by IS NULL
      AND COALESCE(status, 'draft') = ANY($2::text[])
    ORDER BY updated_at DESC
    LIMIT $3
    `,
    [spaceId, statusFilter, limit]
  )
}

// A5: Status state-machine PATCH — atomic compare-and-swap to prevent lost-update
// races. Two concurrent PATCHes reading the same current status would both pass
// the pre-check; the WHERE status IN (...allowed reverses) clause in the UPDATE
// serializes them: only the first succeeds, the second finds 0 rows and 409s.
export async function updateRecordStatus(
  id: string,
  newStatus: RecordStatus,
  supersededByRecordId?: string
): Promise<{ ok: boolean; error?: string; allowed_transitions?: RecordStatus[]; current_status?: RecordStatus }> {
  // Find every status from which `newStatus` is reachable — used as the CAS guard.
  const reachableFrom = (Object.keys(STATUS_TRANSITIONS) as RecordStatus[]).filter((from) =>
    STATUS_TRANSITIONS[from].includes(newStatus)
  )
  if (reachableFrom.length === 0) {
    return { ok: false, error: `No valid transition to ${newStatus}` }
  }

  const updated = await query<{ status: RecordStatus; [key: string]: unknown }>(
    `UPDATE library_records
     SET status = $2,
         superseded_by_record_id = $3::bigint
     WHERE id = $1::bigint
       AND superseded_by IS NULL
       AND COALESCE(status, 'draft') = ANY($4::text[])
     RETURNING COALESCE(status, 'draft') AS status`,
    [id, newStatus, supersededByRecordId ?? null, reachableFrom]
  )
  if (updated[0]) return { ok: true }

  // CAS failed — either record is gone/superseded or current status can't reach newStatus.
  const current = await query<{ status: RecordStatus; [key: string]: unknown }>(
    `SELECT COALESCE(status, 'draft') AS status FROM library_records WHERE id = $1::bigint AND superseded_by IS NULL`,
    [id]
  )
  if (!current[0]) return { ok: false, error: 'Record not found or already superseded' }
  const cs = current[0].status as RecordStatus
  return {
    ok: false,
    error: 'Invalid status transition',
    allowed_transitions: STATUS_TRANSITIONS[cs],
    current_status: cs,
  }
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

  // Spec 044 v2 Phase 2 — write embedded_at = NOW() when embedding is non-null
  // so staleness tracking is accurate from row creation. The re-embed-on-edit
  // trigger from Phase 1 will null both columns on subsequent content/title edits.
  const embeddedAt = embedding ? new Date().toISOString() : null

  const rows = await query<LibraryRecord>(
    `
    INSERT INTO library_records
      (space_id, title, content_markdown, schema_data, labels, embedding, embedded_at, created_by_officer, created_at)
    VALUES
      ($1::bigint, $2, $3, $4::jsonb, $5::text[], $6, $7::timestamptz, $8, COALESCE($9::timestamptz, NOW()))
    RETURNING
      id::text, space_id::text, title, content_markdown, schema_data, labels,
      version, superseded_by::text,
      COALESCE(status, 'draft') AS status,
      superseded_by_record_id::text,
      created_by_officer, created_at::text, updated_at::text
  `,
    [
      params.space_id,
      params.title,
      params.content_markdown ?? '',
      JSON.stringify(params.schema_data ?? {}),
      params.labels ?? [],
      embedding ? `[${embedding.join(',')}]` : null,
      embeddedAt,
      params.created_by_officer ?? 'captain',
      params.created_at ?? null,
    ]
  )
  const record = rows[0]

  if (record) {
    // A1/A6: Index wikilinks + section anchors BEFORE returning so backlinks land
    // same-turn (AC-12). Failures are swallowed individually to keep record save
    // durable — a stale link index is recoverable, a lost save is not.
    const content = params.content_markdown ?? ''
    await Promise.all([
      indexLinks(record.id, content, params.space_id).catch((err) => {
        console.warn('[library] indexLinks failed for record', record.id, err)
      }),
      indexSections(record.id, content).catch((err) => {
        console.warn('[library] indexSections failed for record', record.id, err)
      }),
    ])

    // Queue in cabinet_memory for cross-system search (async, non-blocking)
    getSpace(params.space_id)
      .then((space) => {
        queueLibraryRecordInMemory({
          recordId: record.id,
          spaceId: params.space_id,
          spaceName: space?.name ?? '',
          title: params.title,
          content: [params.title, params.content_markdown ?? ''].filter(Boolean).join('\n\n'),
          officer: params.created_by_officer ?? 'captain',
          sourceCreatedAt: params.created_at ?? undefined,
        })
      })
      .catch(() => {/* non-fatal */})
  }

  return record
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
  const embedding = embedText ? await getEmbedding(embedText, id) : null

  // Spec 044 v2 Phase 2 — write embedded_at = NOW() on the new version row
  // when embedding is non-null. Re-embed-on-edit trigger from Phase 1 covers
  // the staleness invariant; this write is the positive-side timestamp.
  const embeddedAt = embedding ? new Date().toISOString() : null

  // Single atomic transaction: SELECT FOR UPDATE locks the old row so concurrent
  // updates serialize. Without the lock, two callers could both read version=N
  // and both insert version=N+1, creating a phantom "v2" with no parent pointer.
  const rows = await query<LibraryRecord>(
    `
    WITH locked AS (
      SELECT id, space_id, version, COALESCE(status, 'draft') AS status
      FROM library_records
      WHERE id = $1::bigint AND superseded_by IS NULL
      FOR UPDATE
    ),
    inserted AS (
      INSERT INTO library_records
        (space_id, title, content_markdown, schema_data, labels, embedding, embedded_at, version, created_by_officer, status)
      SELECT
        locked.space_id,
        $2, $3, $4::jsonb, $5::text[], $6, $7::timestamptz, locked.version + 1, NULLIF($8, ''),
        locked.status
      FROM locked
      RETURNING
        id, space_id, title, content_markdown, schema_data, labels,
        version, superseded_by, status, superseded_by_record_id,
        created_by_officer, created_at, updated_at
    ),
    update_old AS (
      UPDATE library_records
      SET superseded_by = (SELECT id FROM inserted)
      WHERE id = (SELECT id FROM locked)
    )
    SELECT
      id::text, space_id::text, title, content_markdown, schema_data, labels,
      version, superseded_by::text,
      COALESCE(status, 'draft') AS status,
      superseded_by_record_id::text,
      created_by_officer, created_at::text, updated_at::text
    FROM inserted
  `,
    [
      id,
      params.title,
      params.content_markdown,
      JSON.stringify(params.schema_data ?? {}),
      params.labels ?? [],
      embedding ? `[${embedding.join(',')}]` : null,
      embeddedAt,
      params.created_by_officer ?? '',
    ]
  )
  if (!rows[0]) {
    throw new Error(`Record ${id} not found or already superseded`)
  }
  const updated = rows[0]

  // A1/A6: Index wikilinks + section anchors for new version — awaited so
  // backlinks land same-turn (AC-12). Failures logged, not thrown.
  await Promise.all([
    indexLinks(updated.id, params.content_markdown, updated.space_id).catch((err) => {
      console.warn('[library] indexLinks failed for record', updated.id, err)
    }),
    indexSections(updated.id, params.content_markdown).catch((err) => {
      console.warn('[library] indexSections failed for record', updated.id, err)
    }),
  ])

  // Queue in cabinet_memory for cross-system search (async, non-blocking)
  getSpace(updated.space_id)
    .then((space) => {
      queueLibraryRecordInMemory({
        recordId: updated.id,
        spaceId: updated.space_id,
        spaceName: space?.name ?? '',
        title: params.title,
        content: [params.title, params.content_markdown].filter(Boolean).join('\n\n'),
        officer: params.created_by_officer ?? 'captain',
      })
    })
    .catch(() => {/* non-fatal */})

  return updated
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

// Spec 044 v2 Phase 2 — env-knob hybrid ranking weights.
// Defaults preserve the current pure-semantic behavior (semantic only).
// Set KEYWORD_W or RECENCY_W > 0 in env to dial in hybrid scoring.
//   - SEMANTIC_W * (1 - cosine_distance)
//   - KEYWORD_W  * (title ILIKE '%query%' ? 1 : 0)
//   - RECENCY_W  * 1 / (1 + days_since_update)
// Sum → ORDER BY DESC. Pure-semantic path (KEYWORD_W=0 AND RECENCY_W=0)
// keeps the original SQL shape for byte-identical query plans.
function getSearchWeights(): { semantic: number; keyword: number; recency: number } {
  const semantic = parseFloat(process.env.LIBRARY_SEARCH_SEMANTIC_W ?? '1.0')
  const keyword = parseFloat(process.env.LIBRARY_SEARCH_KEYWORD_W ?? '0.0')
  const recency = parseFloat(process.env.LIBRARY_SEARCH_RECENCY_W ?? '0.0')
  return {
    semantic: Number.isFinite(semantic) ? semantic : 1.0,
    keyword: Number.isFinite(keyword) ? keyword : 0.0,
    recency: Number.isFinite(recency) ? recency : 0.0,
  }
}

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
  const weights = getSearchWeights()
  const isHybrid = weights.keyword > 0 || weights.recency > 0

  // Hybrid path activates only when keyword or recency weight is non-zero.
  // At defaults (SEMANTIC=1.0, KEYWORD=0.0, RECENCY=0.0) we keep the original
  // pure-semantic SQL shape below for stable plans + byte-identical results.
  if (isHybrid) {
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
        AND ($3::text[] IS NULL OR labels && $3::text[])
      ORDER BY (
        $4::float8 * (1 - (embedding <=> $1::vector))
        + $5::float8 * (CASE WHEN title ILIKE '%' || $6 || '%' THEN 1.0 ELSE 0.0 END)
        + $7::float8 * (1.0 / (1.0 + EXTRACT(EPOCH FROM (NOW() - updated_at)) / 86400.0))
      ) DESC
      LIMIT $8
    `,
      [
        embeddingLiteral,
        params.space_id ?? null,
        params.labels && params.labels.length > 0 ? params.labels : null,
        weights.semantic,
        weights.keyword,
        params.query,
        weights.recency,
        params.limit ?? 10,
      ]
    )
  }

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

// Spec 045 Phase 2 — graph data for /library/graph force-directed view.
// Returns top-N nodes by degree (descending) so the cap keeps the most
// connected records when corpus exceeds limit. Edges are filtered to the
// included node set so the client never receives dangling references.
export interface LibraryGraphNode {
  [key: string]: unknown
  id: string
  title: string
  space_id: string
  degree: number
}

export interface LibraryGraphEdge {
  [key: string]: unknown
  source: string
  target: string
}

export interface LibraryGraphData {
  nodes: LibraryGraphNode[]
  edges: LibraryGraphEdge[]
}

export async function getGraphData(opts?: {
  spaceIds?: string[]
  limitNodes?: number
}): Promise<LibraryGraphData> {
  const limit = opts?.limitNodes ?? 500
  const spaceIds = opts?.spaceIds && opts.spaceIds.length > 0 ? opts.spaceIds : null

  const nodes = await query<LibraryGraphNode>(
    `
    WITH degree_counts AS (
      SELECT r.id, COALESCE(s.cnt, 0) + COALESCE(t.cnt, 0) AS degree
      FROM library_records r
      LEFT JOIN (
        SELECT source_record_id AS id, COUNT(*) AS cnt
        FROM library_record_links
        GROUP BY source_record_id
      ) s ON s.id = r.id
      LEFT JOIN (
        SELECT target_record_id AS id, COUNT(*) AS cnt
        FROM library_record_links
        GROUP BY target_record_id
      ) t ON t.id = r.id
      WHERE r.superseded_by IS NULL
        AND ($1::bigint[] IS NULL OR r.space_id = ANY($1::bigint[]))
    )
    SELECT
      r.id::text AS id,
      r.title,
      r.space_id::text AS space_id,
      dc.degree::int AS degree
    FROM library_records r
    JOIN degree_counts dc ON dc.id = r.id
    WHERE r.superseded_by IS NULL
      AND ($1::bigint[] IS NULL OR r.space_id = ANY($1::bigint[]))
    ORDER BY dc.degree DESC, r.id ASC
    LIMIT $2
  `,
    [spaceIds, limit]
  )

  if (nodes.length === 0) {
    return { nodes: [], edges: [] }
  }

  // Bigint comparison (not text cast) so the index on
  // library_record_links.source_record_id / target_record_id is used.
  const nodeIdsBigint = nodes.map((n) => n.id)
  const edges = await query<LibraryGraphEdge>(
    `
    SELECT DISTINCT
      source_record_id::text AS source,
      target_record_id::text AS target
    FROM library_record_links
    WHERE source_record_id = ANY($1::bigint[])
      AND target_record_id = ANY($1::bigint[])
      AND source_record_id <> target_record_id
    LIMIT 5000
  `,
    [nodeIdsBigint]
  )

  return { nodes, edges }
}
