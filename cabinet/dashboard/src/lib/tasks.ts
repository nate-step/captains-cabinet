/**
 * tasks.ts — officer_tasks DB helpers for Spec 038 v1.2.
 *
 * v1.2 deltas (COO adversary MUST-FIX, CoS-ratified msg 1623):
 *   038.4 — done/cancel/unblock clear blocked + blocked_reason;
 *           block permitted on status IN ('queue','wip').
 *   038.5 — Postgres errcode 23514 from the WIP trigger is surfaced as
 *           WipCapExceededError so the route handler can return 409.
 *   038.9 — Every transaction SETs app.cabinet_officer for the
 *           officer_task_history AFTER trigger.
 *
 * All writes broadcast on Redis pub/sub `cabinet:tasks:updated` so the
 * SSE stream can push live updates to the /tasks dashboard page.
 */

import { access, constants as fsConstants } from 'node:fs/promises'
import path from 'node:path'
import { query, getDbPool } from '@/lib/db'
import redis from '@/lib/redis'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type TaskStatus = 'queue' | 'wip' | 'done' | 'cancelled'
export type LinkedKind = 'linear' | 'github' | 'library' | null

export const WIP_CAP = 3 as const

export interface OfficerTask {
  // pg's QueryResultRow constraint requires Record<string, unknown>; other
  // Library types in lib/library.ts follow the same pattern.
  [key: string]: unknown
  id: number
  officer_slug: string
  title: string
  description: string | null
  status: TaskStatus
  blocked: boolean
  blocked_reason: string | null
  linked_url: string | null
  linked_kind: LinkedKind
  linked_id: string | null
  started_at: string | null
  completed_at: string | null
  created_at: string
  updated_at: string
  context_slug: string  // NOT NULL per AC #21; every row has a validated slug
}

export interface OfficerTasksBoard {
  wip: OfficerTask[]   // 0..WIP_CAP WIP rows, may include blocked=true
  queue: OfficerTask[]
  done: OfficerTask[]  // last 3 only
}

export interface BoardStats {
  officers: number
  totalWip: number
  totalCap: number    // officers × WIP_CAP
  totalBlocked: number
  totalQueue: number
  recentDone: number  // v1.2 038.7: last N done globally (N = RECENT_DONE_LIMIT)
}

/** Spec 038 v1.2 AC #19 (post-COO 038.7): rollup (b) shows "N done" using a
 *  count-based framing, not a calendar-time ("this week") framing. Captain msg
 *  1619 phases-not-calendar rule. Value: last 20 completed tasks across all
 *  officers, most recent first. */
export const RECENT_DONE_LIMIT = 20 as const

/**
 * Thrown when a WIP-advancing write hits the cap. API layer maps to 409 with
 * a structured body. Emitted by the `startTask` pre-check AND by the route
 * layer when it coerces Postgres errcode 23514 from the WIP trigger (038.5).
 */
export class WipCapExceededError extends Error {
  readonly current: number
  readonly cap: number
  readonly titles: string[]
  constructor(officerSlug: string, titles: string[], current?: number) {
    const n = current ?? titles.length
    super(
      titles.length > 0
        ? `WIP cap exceeded: ${officerSlug} already has ${n} WIP tasks (${titles.map((t) => `"${t}"`).join(', ')}). Finish or cancel one before starting another.`
        : `WIP cap exceeded: ${officerSlug} already has ${n}/${WIP_CAP} WIP tasks. Finish or cancel one before starting another.`
    )
    this.name = 'WipCapExceededError'
    this.current = n
    this.cap = WIP_CAP
    this.titles = titles
  }
}

/** Coerce a Postgres error into a `WipCapExceededError` if it originated from
 *  the `enforce_officer_wip_limit` trigger (errcode 23514, check_violation with
 *  a distinct constraint name). Returns null if not our case — caller rethrows.
 *
 *  v1.2 038.5: the trigger is the backstop — even if the app-level pre-check
 *  passes, a concurrent writer or direct SQL UPDATE can still trip the cap.
 *  The route handlers call this and map non-null returns to HTTP 409.
 */
export function coerceWipCapError(err: unknown, officerSlug: string): WipCapExceededError | null {
  if (!err || typeof err !== 'object') return null
  const e = err as { code?: string; message?: string; constraint?: string }
  // Postgres errcode for check_violation is 23514; the trigger uses RAISE with
  // that errcode and includes a sentinel token the user can grep for.
  if (e.code !== '23514') return null
  const msg = e.message || ''
  // Trigger raises "WIP limit (3) exceeded for officer X in context Y".
  if (!msg.includes('WIP limit')) return null
  return new WipCapExceededError(officerSlug, [], WIP_CAP)
}

// ---------------------------------------------------------------------------
// context_slug validator (Spec 038 v1.1 AC #21 — app-side validation)
// ---------------------------------------------------------------------------

const CONTEXTS_DIR =
  process.env.CONTEXTS_DIR ||
  path.join(process.env.CABINET_ROOT || '/opt/founders-cabinet', 'instance/config/contexts')

// Slug format: lowercase alphanumeric + dashes; no path traversal.
const CONTEXT_SLUG_RE = /^[a-z0-9][a-z0-9-]{0,63}$/

/** Verify the context slug is syntactically valid AND resolves to a YAML file
 *  in instance/config/contexts/. Throws on invalid; returns normalized slug on OK.
 *  Per Spec 038 v1.1 AC #21 (Cabinet decision 2026-04-16 — no `contexts` FK). */
export async function validateContextSlug(slug: string | null | undefined): Promise<string> {
  if (!slug?.trim()) {
    throw new Error('context_slug is required (Spec 038 v1.1 AC #21)')
  }
  const trimmed = slug.trim()
  if (!CONTEXT_SLUG_RE.test(trimmed)) {
    throw new Error(`context_slug '${trimmed}' is invalid (must match ${CONTEXT_SLUG_RE})`)
  }
  const yamlPath = path.join(CONTEXTS_DIR, `${trimmed}.yml`)
  try {
    await access(yamlPath, fsConstants.R_OK)
  } catch {
    throw new Error(
      `context_slug '${trimmed}' not found in ${CONTEXTS_DIR} (no ${trimmed}.yml)`
    )
  }
  return trimmed
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

/** Fetch the board state for a single officer within a context.
 *  `contextSlug` is REQUIRED — the WIP cap is per (context, officer), so a
 *  board without a context scope would conflate tasks across contexts and
 *  fire false integrity alarms for officers active in multiple contexts.
 *
 * Done rows are LIMIT-ed in SQL so boards stay O(active-set) regardless of the
 * officer's lifetime completed count. Without the limit, a long-lived officer
 * with thousands of done tasks would transfer all of them on every render and
 * every SSE re-fetch (done-last-3 is display, not audit).
 */
export async function getOfficerBoard(
  officerSlug: string,
  contextSlug: string
): Promise<OfficerTasksBoard> {
  const activeRows = await query<OfficerTask>(
    `SELECT * FROM officer_tasks
     WHERE officer_slug = $1
       AND context_slug = $2
       AND status IN ('queue', 'wip')
     ORDER BY
       CASE status WHEN 'wip' THEN 0 ELSE 1 END,
       started_at DESC NULLS LAST,
       created_at DESC`,
    [officerSlug, contextSlug]
  )
  const doneRows = await query<OfficerTask>(
    `SELECT * FROM officer_tasks
     WHERE officer_slug = $1
       AND context_slug = $2
       AND status = 'done'
     ORDER BY completed_at DESC NULLS LAST
     LIMIT 3`,
    [officerSlug, contextSlug]
  )

  // Do NOT slice at WIP_CAP — let the page-level integrity banner surface any
  // DB-state violation that slipped past the trigger. Slicing would mask bugs.
  const wip = activeRows.filter((r) => r.status === 'wip')
  const queue = activeRows.filter((r) => r.status === 'queue')

  return { wip, queue, done: doneRows }
}

/** Fetch all boards for all known officers (runs in parallel) scoped to a
 *  single context. Context scoping matches the WIP cap semantics — without
 *  it, a multi-context officer would appear over-cap. */
export async function getAllOfficerBoards(
  contextSlug: string
): Promise<Record<string, OfficerTasksBoard>> {
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
    officerSlugs.map(async (slug) => [slug, await getOfficerBoard(slug, contextSlug)] as const)
  )
  return Object.fromEntries(entries)
}

/** Aggregate stats for the page-header stat strip (Spec 038 v1.2 AC #19).
 *
 * Single aggregate query + one bounded LIMIT for recent-done count. `contextSlug`
 * optional: pass to scope stats to one context; omit for cross-context aggregate.
 *
 * v1.2 deltas (COO 038.6 / 038.7):
 *   - `recentDone` replaces `doneThisWeek` — count-based (N=20), not calendar-time.
 *   - `totalBlocked` filter `status IN ('queue','wip')` prevents done/cancelled
 *     blocked rows from polluting the metric (blocked_state_coherent CHECK now
 *     enforces this at DB level too, so the filter is belt-and-suspenders).
 */
export async function getBoardStats(contextSlug?: string | null): Promise<BoardStats> {
  const ctxPredicate = contextSlug
    ? `AND COALESCE(context_slug, '') = $1`
    : ``
  const params = contextSlug ? [contextSlug] : []

  const rows = await query<{
    officers: string // pg BIGINT comes back as string
    total_wip: string
    total_blocked: string
    total_queue: string
  }>(
    `SELECT
       COUNT(DISTINCT officer_slug)                                               AS officers,
       COUNT(*) FILTER (WHERE status = 'wip')                                     AS total_wip,
       COUNT(*) FILTER (WHERE status IN ('queue', 'wip') AND blocked = true)      AS total_blocked,
       COUNT(*) FILTER (WHERE status = 'queue')                                   AS total_queue
     FROM officer_tasks
     WHERE status != 'cancelled'
       ${ctxPredicate}`,
    params
  )

  // recentDone — last N done rows across all officers. Separate query because
  // it needs a LIMIT, not a COUNT. Cheap: idx_officer_tasks_completed covers
  // `status='done' ORDER BY completed_at DESC`.
  const doneRows = await query<{ c: string }>(
    `SELECT COUNT(*)::text AS c FROM (
       SELECT id FROM officer_tasks
        WHERE status = 'done'
          ${ctxPredicate}
        ORDER BY completed_at DESC NULLS LAST
        LIMIT ${RECENT_DONE_LIMIT}
     ) sub`,
    params
  )

  const r = rows[0] ?? {
    officers: '0',
    total_wip: '0',
    total_blocked: '0',
    total_queue: '0',
  }
  const officers = parseInt(r.officers, 10) || 0
  return {
    officers,
    totalWip: parseInt(r.total_wip, 10) || 0,
    totalCap: officers * WIP_CAP,
    totalBlocked: parseInt(r.total_blocked, 10) || 0,
    totalQueue: parseInt(r.total_queue, 10) || 0,
    recentDone: parseInt(doneRows[0]?.c ?? '0', 10) || 0,
  }
}

/** Fetch current WIP list for an officer (up to WIP_CAP rows). */
export async function getCurrentWip(officerSlug: string): Promise<OfficerTask[]> {
  const rows = await query<OfficerTask>(
    `SELECT * FROM officer_tasks
     WHERE officer_slug = $1 AND status = 'wip'
     ORDER BY started_at DESC NULLS LAST, created_at DESC`,
    [officerSlug]
  )
  return rows
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
 * Start a new WIP task. Errors with `WipCapExceededError` if the caller already
 * has WIP_CAP WIP rows (for the same context_slug). The DB trigger is the hard
 * backstop; this pre-check just produces a cleaner error + lists current titles.
 */
export async function startTask(
  officerSlug: string,
  title: string,
  opts: {
    linkedUrl?: string
    linkedKind?: LinkedKind
    linkedId?: string
    contextSlug?: string
    actorOfficer?: string
  } = {}
): Promise<OfficerTask> {
  const contextSlug = await validateContextSlug(opts.contextSlug)
  const actor = opts.actorOfficer ?? 'api'

  const pool = getDbPool()
  const client = await pool.connect()

  try {
    await client.query('BEGIN')
    await client.query(`SELECT set_config('app.cabinet_officer', $1, true)`, [actor])

    // App-level pre-check for a readable error. The DB trigger's advisory
    // lock (`pg_advisory_xact_lock` on hashtextextended(context/officer, 42))
    // is the ONLY true concurrent-writer guard — a concurrent INSERT is not
    // visible through `FOR UPDATE` (which re-fetches locked rows, not future
    // inserts). Do NOT remove the trigger lock thinking this check covers it.
    const existing = await client.query<OfficerTask>(
      `SELECT id, title FROM officer_tasks
        WHERE officer_slug = $1
          AND context_slug = $2
          AND status = 'wip'
        ORDER BY started_at DESC NULLS LAST
        FOR UPDATE`,
      [officerSlug, contextSlug]
    )
    if (existing.rows.length >= WIP_CAP) {
      await client.query('ROLLBACK')
      throw new WipCapExceededError(
        officerSlug,
        existing.rows.map((r) => r.title)
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
        contextSlug,
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

/** Mark a specific WIP task as done. Clears blocked + blocked_reason (038.4).
 *  Ownership is enforced with officer_slug so an errant PATCH with a wrong id
 *  cannot close another officer's task (even though all dashboard users share
 *  one session, typos are still a liability). */
export async function doneTask(
  id: number,
  officerSlug: string,
  actorOfficer: string = 'api'
): Promise<OfficerTask> {
  const pool = getDbPool()
  const client = await pool.connect()

  try {
    await client.query('BEGIN')
    await client.query(`SELECT set_config('app.cabinet_officer', $1, true)`, [actorOfficer])

    const wip = await client.query<OfficerTask>(
      `SELECT id, officer_slug FROM officer_tasks
        WHERE id = $1 AND officer_slug = $2 AND status = 'wip' FOR UPDATE`,
      [id, officerSlug]
    )
    if (wip.rows.length === 0) {
      await client.query('ROLLBACK')
      throw new Error(`Task id=${id} not found, not in WIP, or wrong officer.`)
    }

    const result = await client.query<OfficerTask>(
      `UPDATE officer_tasks
         SET status = 'done', completed_at = NOW(), blocked = false, blocked_reason = NULL
         WHERE id = $1
       RETURNING *`,
      [wip.rows[0].id]
    )
    await client.query('COMMIT')

    const task = result.rows[0]
    await broadcastTasksUpdate(task.officer_slug)
    return task
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined)
    throw err
  } finally {
    client.release()
  }
}

/** Flip the `blocked` overlay on a queue or WIP task. Requires a reason when blocked=true.
 *  v1.2 COO 038.4: blocked permitted on status IN ('queue','wip'); the
 *  `blocked_state_coherent` CHECK enforces done/cancelled cannot be blocked.
 *  Ownership enforced with officer_slug. */
export async function setBlocked(
  id: number,
  officerSlug: string,
  blocked: boolean,
  reason?: string,
  actorOfficer: string = 'api'
): Promise<OfficerTask> {
  if (blocked && !reason?.trim()) {
    throw new Error('blocked_reason is required when blocking a task.')
  }

  const pool = getDbPool()
  const client = await pool.connect()

  try {
    await client.query('BEGIN')
    await client.query(`SELECT set_config('app.cabinet_officer', $1, true)`, [actorOfficer])

    const active = await client.query<OfficerTask>(
      `SELECT id, officer_slug FROM officer_tasks
        WHERE id = $1 AND officer_slug = $2 AND status IN ('queue', 'wip') FOR UPDATE`,
      [id, officerSlug]
    )
    if (active.rows.length === 0) {
      await client.query('ROLLBACK')
      throw new Error(`Task id=${id} not found, not in queue/WIP, or wrong officer.`)
    }

    const result = await client.query<OfficerTask>(
      `UPDATE officer_tasks
         SET blocked = $2,
             blocked_reason = CASE WHEN $2 THEN $3 ELSE NULL END
         WHERE id = $1
       RETURNING *`,
      [id, blocked, blocked ? reason!.trim() : null]
    )
    await client.query('COMMIT')

    const task = result.rows[0]
    await broadcastTasksUpdate(task.officer_slug)
    return task
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined)
    throw err
  } finally {
    client.release()
  }
}

/** Add a task to the officer's queue. */
export async function queueTask(
  officerSlug: string,
  title: string,
  opts: {
    linkedUrl?: string
    linkedKind?: LinkedKind
    linkedId?: string
    contextSlug?: string
    actorOfficer?: string
  } = {}
): Promise<OfficerTask> {
  const contextSlug = await validateContextSlug(opts.contextSlug)
  const actor = opts.actorOfficer ?? 'api'

  const pool = getDbPool()
  const client = await pool.connect()
  try {
    await client.query('BEGIN')
    await client.query(`SELECT set_config('app.cabinet_officer', $1, true)`, [actor])
    const result = await client.query<OfficerTask>(
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
        contextSlug,
      ]
    )
    await client.query('COMMIT')
    await broadcastTasksUpdate(officerSlug)
    return result.rows[0]
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined)
    throw err
  } finally {
    client.release()
  }
}

/**
 * Update any whitelisted field of a task. Officer + status checks are caller's responsibility.
 *
 * Only whitelisted columns can be updated — enforced HERE (not at the caller),
 * because updateTask is a library function and any future caller inherits the
 * guarantee. Notably, `status` and `blocked` are NOT updatable through here —
 * state changes go through the transactional helpers so the WIP cap invariant
 * and blocked_reason CHECK are preserved.
 */
const UPDATABLE_COLUMNS = new Set<keyof OfficerTask>([
  'title',
  'description',
  'linked_url',
  'linked_kind',
  'linked_id',
])

export async function updateTask(
  id: number,
  fields: Partial<Omit<OfficerTask, 'id' | 'created_at' | 'updated_at'>>,
  actorOfficer: string = 'api'
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

  const pool = getDbPool()
  const client = await pool.connect()
  try {
    await client.query('BEGIN')
    await client.query(`SELECT set_config('app.cabinet_officer', $1, true)`, [actorOfficer])
    const result = await client.query<OfficerTask>(
      `UPDATE officer_tasks SET ${sets.join(', ')} WHERE id = $${idx} RETURNING *`,
      values
    )
    if (result.rows.length === 0) {
      await client.query('ROLLBACK')
      throw new Error(`Task id=${id} not found`)
    }
    await client.query('COMMIT')
    await broadcastTasksUpdate(result.rows[0].officer_slug)
    return result.rows[0]
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined)
    throw err
  } finally {
    client.release()
  }
}

/** Cancel a queued or WIP task (not done/cancelled). Clears blocked + blocked_reason (038.4). */
export async function cancelTask(
  id: number,
  officerSlug: string,
  actorOfficer: string = 'api'
): Promise<OfficerTask> {
  const pool = getDbPool()
  const client = await pool.connect()
  try {
    await client.query('BEGIN')
    await client.query(`SELECT set_config('app.cabinet_officer', $1, true)`, [actorOfficer])
    const result = await client.query<OfficerTask>(
      `UPDATE officer_tasks
       SET status = 'cancelled', blocked = false, blocked_reason = NULL
       WHERE id = $1 AND officer_slug = $2 AND status NOT IN ('done', 'cancelled')
       RETURNING *`,
      [id, officerSlug]
    )
    if (result.rows.length === 0) {
      await client.query('ROLLBACK')
      throw new Error(`Task id=${id} not found, already done/cancelled, or wrong officer.`)
    }
    await client.query('COMMIT')
    await broadcastTasksUpdate(officerSlug)
    return result.rows[0]
  } catch (err) {
    await client.query('ROLLBACK').catch(() => undefined)
    throw err
  } finally {
    client.release()
  }
}
