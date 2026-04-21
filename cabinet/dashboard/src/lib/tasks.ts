/**
 * tasks.ts — officer_tasks DB helpers for Spec 038.
 *
 * All writes broadcast on Redis pub/sub `cabinet:tasks:updated` so the
 * SSE stream can push live updates to the /tasks dashboard page.
 *
 * WIP=1 is enforced at the DB level via a partial unique index. The
 * helpers also do an app-level pre-check for nicer error messages.
 */

import { query, getDbPool } from '@/lib/db'
import redis from '@/lib/redis'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type TaskStatus = 'queue' | 'wip' | 'blocked' | 'done' | 'cancelled'
export type LinkedKind = 'linear' | 'github' | 'library' | null

export interface OfficerTask {
  // pg's QueryResultRow constraint requires Record<string, unknown>; other
  // Library types in lib/library.ts follow the same pattern.
  [key: string]: unknown
  id: number
  officer_slug: string
  title: string
  description: string | null
  status: TaskStatus
  blocked_reason: string | null
  linked_url: string | null
  linked_kind: LinkedKind
  linked_id: string | null
  started_at: string | null
  completed_at: string | null
  created_at: string
  updated_at: string
  context_slug: string | null
}

export interface OfficerTasksBoard {
  wip: OfficerTask | null
  blocked: OfficerTask[]
  queue: OfficerTask[]
  done: OfficerTask[] // last 3 only
}

// ---------------------------------------------------------------------------
// Broadcast helper
// ---------------------------------------------------------------------------

async function broadcastTasksUpdate(officerSlug: string): Promise<void> {
  try {
    // Only broadcast when real Redis is available (ioredis, not mock)
    const REDIS_URL = process.env.REDIS_URL
    if (!REDIS_URL) return
    const { default: Redis } = await import('ioredis')
    const pub = new Redis(REDIS_URL)
    await pub.publish(
      'cabinet:tasks:updated',
      JSON.stringify({ officer_slug: officerSlug, timestamp: new Date().toISOString() })
    )
    await pub.quit()
  } catch {
    // Non-fatal — SSE will degrade to poll fallback
  }
}

// ---------------------------------------------------------------------------
// Read helpers
// ---------------------------------------------------------------------------

/** Fetch the board state for a single officer (wip, blocked, queue, done-last-3).
 *
 * Done rows are LIMIT-ed in SQL so boards stay O(active-set) regardless of the
 * officer's lifetime completed count. Without the limit, a long-lived officer
 * with thousands of done tasks would transfer all of them on every render and
 * every SSE re-fetch (done-last-3 is display, not audit).
 */
export async function getOfficerBoard(officerSlug: string): Promise<OfficerTasksBoard> {
  const activeRows = await query<OfficerTask>(
    `SELECT * FROM officer_tasks
     WHERE officer_slug = $1
       AND status IN ('queue', 'wip', 'blocked')
     ORDER BY
       CASE status WHEN 'wip' THEN 0 WHEN 'blocked' THEN 1 ELSE 2 END,
       created_at DESC`,
    [officerSlug]
  )
  const doneRows = await query<OfficerTask>(
    `SELECT * FROM officer_tasks
     WHERE officer_slug = $1 AND status = 'done'
     ORDER BY completed_at DESC NULLS LAST
     LIMIT 3`,
    [officerSlug]
  )

  const wip = activeRows.find((r) => r.status === 'wip') ?? null
  const blocked = activeRows.filter((r) => r.status === 'blocked')
  const queue = activeRows.filter((r) => r.status === 'queue')

  return { wip, blocked, queue, done: doneRows }
}

/** Fetch all boards for all known officers (runs in parallel). */
export async function getAllOfficerBoards(): Promise<Record<string, OfficerTasksBoard>> {
  // Discover officers from Redis expected keys
  const expectedKeys = await redis.keys('cabinet:officer:expected:*')
  const officerSlugs = expectedKeys
    .map((k) => k.replace('cabinet:officer:expected:', ''))
    .filter((s) => !s.includes(':'))
    .sort()

  if (officerSlugs.length === 0) {
    // Fallback for dev / no Redis
    officerSlugs.push('cos', 'cpo', 'cro', 'cto')
  }

  const entries = await Promise.all(
    officerSlugs.map(async (slug) => [slug, await getOfficerBoard(slug)] as const)
  )
  return Object.fromEntries(entries)
}

/** Fetch current WIP for an officer (null if none). */
export async function getCurrentWip(officerSlug: string): Promise<OfficerTask | null> {
  const rows = await query<OfficerTask>(
    `SELECT * FROM officer_tasks WHERE officer_slug = $1 AND status = 'wip' LIMIT 1`,
    [officerSlug]
  )
  return rows[0] ?? null
}

/** Fetch a single task by id. */
export async function getTask(id: number): Promise<OfficerTask | null> {
  const rows = await query<OfficerTask>('SELECT * FROM officer_tasks WHERE id = $1', [id])
  return rows[0] ?? null
}

// ---------------------------------------------------------------------------
// Write helpers — each broadcasts on success
// ---------------------------------------------------------------------------

/**
 * Start a new WIP task (or promote a queue item).
 * Errors if the officer already has a WIP task.
 *
 * @param officerSlug - officer who owns the task
 * @param title - task title (required)
 * @param opts.linkedUrl - optional linked URL
 * @param opts.linkedKind - 'linear' | 'github' | 'library'
 * @param opts.linkedId - e.g. 'SEN-519'
 * @param opts.contextSlug - context isolation slug
 */
export async function startTask(
  officerSlug: string,
  title: string,
  opts: {
    linkedUrl?: string
    linkedKind?: LinkedKind
    linkedId?: string
    contextSlug?: string
  } = {}
): Promise<OfficerTask> {
  const pool = getDbPool()
  const client = await pool.connect()

  try {
    await client.query('BEGIN')

    // App-level pre-check for readable error (DB unique index is the hard guard)
    const existing = await client.query<OfficerTask>(
      `SELECT id, title FROM officer_tasks WHERE officer_slug = $1 AND status = 'wip' FOR UPDATE`,
      [officerSlug]
    )
    if (existing.rows.length > 0) {
      await client.query('ROLLBACK')
      throw new Error(
        `WIP conflict: ${officerSlug} already has a WIP task: "${existing.rows[0].title}" (id=${existing.rows[0].id}). Finish or block it first.`
      )
    }

    const result = await client.query<OfficerTask>(
      `INSERT INTO officer_tasks
         (officer_slug, title, status, linked_url, linked_kind, linked_id, started_at, context_slug)
       VALUES ($1, $2, 'wip', $3, $4, $5, NOW(), $6)
       RETURNING *`,
      [
        officerSlug,
        title.trim(),
        opts.linkedUrl ?? null,
        opts.linkedKind ?? null,
        opts.linkedId ?? null,
        opts.contextSlug ?? null,
      ]
    )
    await client.query('COMMIT')

    const task = result.rows[0]
    await broadcastTasksUpdate(officerSlug)
    return task
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined)
    throw err
  } finally {
    client.release()
  }
}

/**
 * Mark the current WIP task as done.
 */
export async function doneTask(officerSlug: string): Promise<OfficerTask> {
  const pool = getDbPool()
  const client = await pool.connect()

  try {
    await client.query('BEGIN')

    const wip = await client.query<OfficerTask>(
      `SELECT id FROM officer_tasks WHERE officer_slug = $1 AND status = 'wip' FOR UPDATE`,
      [officerSlug]
    )
    if (wip.rows.length === 0) {
      await client.query('ROLLBACK')
      throw new Error(`No WIP task found for ${officerSlug}. Nothing to mark done.`)
    }

    const result = await client.query<OfficerTask>(
      `UPDATE officer_tasks
       SET status = 'done', completed_at = NOW()
       WHERE id = $1
       RETURNING *`,
      [wip.rows[0].id]
    )
    await client.query('COMMIT')

    const task = result.rows[0]
    await broadcastTasksUpdate(officerSlug)
    return task
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined)
    throw err
  } finally {
    client.release()
  }
}

/**
 * Block the current WIP task with a reason.
 */
export async function blockTask(officerSlug: string, reason: string): Promise<OfficerTask> {
  if (!reason?.trim()) {
    throw new Error('blocked_reason is required when blocking a task.')
  }

  const pool = getDbPool()
  const client = await pool.connect()

  try {
    await client.query('BEGIN')

    const wip = await client.query<OfficerTask>(
      `SELECT id FROM officer_tasks WHERE officer_slug = $1 AND status = 'wip' FOR UPDATE`,
      [officerSlug]
    )
    if (wip.rows.length === 0) {
      await client.query('ROLLBACK')
      throw new Error(`No WIP task found for ${officerSlug}. Nothing to block.`)
    }

    const result = await client.query<OfficerTask>(
      `UPDATE officer_tasks
       SET status = 'blocked', blocked_reason = $2
       WHERE id = $1
       RETURNING *`,
      [wip.rows[0].id, reason.trim()]
    )
    await client.query('COMMIT')

    const task = result.rows[0]
    await broadcastTasksUpdate(officerSlug)
    return task
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined)
    throw err
  } finally {
    client.release()
  }
}

/**
 * Add a task to the officer's queue.
 */
export async function queueTask(
  officerSlug: string,
  title: string,
  opts: {
    linkedUrl?: string
    linkedKind?: LinkedKind
    linkedId?: string
    contextSlug?: string
  } = {}
): Promise<OfficerTask> {
  const rows = await query<OfficerTask>(
    `INSERT INTO officer_tasks
       (officer_slug, title, status, linked_url, linked_kind, linked_id, context_slug)
     VALUES ($1, $2, 'queue', $3, $4, $5, $6)
     RETURNING *`,
    [
      officerSlug,
      title.trim(),
      opts.linkedUrl ?? null,
      opts.linkedKind ?? null,
      opts.linkedId ?? null,
      opts.contextSlug ?? null,
    ]
  )
  await broadcastTasksUpdate(officerSlug)
  return rows[0]
}

/**
 * Update any field of a task. Officer + status checks are caller's responsibility.
 *
 * Only whitelisted columns can be updated — enforced HERE (not at the caller),
 * because updateTask is a library function and any future caller inherits the
 * guarantee. Notably, `status` is NOT updatable through here — status changes
 * must go through the transactional helpers (startTask / doneTask / blockTask /
 * cancelTask) so the WIP=1 invariant is preserved.
 */
const UPDATABLE_COLUMNS = new Set<keyof OfficerTask>([
  'title',
  'description',
  'blocked_reason',
  'linked_url',
  'linked_kind',
  'linked_id',
  'context_slug',
])

export async function updateTask(
  id: number,
  fields: Partial<Omit<OfficerTask, 'id' | 'created_at' | 'updated_at'>>
): Promise<OfficerTask> {
  const sets: string[] = []
  const values: unknown[] = []
  let idx = 1

  for (const [key, val] of Object.entries(fields)) {
    if (!UPDATABLE_COLUMNS.has(key as keyof OfficerTask)) {
      throw new Error(`updateTask: column '${key}' is not updatable`)
    }
    sets.push(`${key} = $${idx}`)
    values.push(val)
    idx++
  }

  if (sets.length === 0) throw new Error('No fields to update')
  values.push(id)

  const rows = await query<OfficerTask>(
    `UPDATE officer_tasks SET ${sets.join(', ')} WHERE id = $${idx} RETURNING *`,
    values
  )
  if (rows.length === 0) throw new Error(`Task id=${id} not found`)

  await broadcastTasksUpdate(rows[0].officer_slug)
  return rows[0]
}

/**
 * Cancel a queued task (or any non-wip, non-done task).
 */
export async function cancelTask(id: number, officerSlug: string): Promise<OfficerTask> {
  const rows = await query<OfficerTask>(
    `UPDATE officer_tasks
     SET status = 'cancelled'
     WHERE id = $1 AND officer_slug = $2 AND status NOT IN ('done', 'cancelled')
     RETURNING *`,
    [id, officerSlug]
  )
  if (rows.length === 0) {
    throw new Error(`Task id=${id} not found, already done/cancelled, or wrong officer.`)
  }
  await broadcastTasksUpdate(officerSlug)
  return rows[0]
}
