/**
 * Spec 034 — POST /api/cabinets (create) + GET /api/cabinets (list)
 */

import { NextRequest, NextResponse } from 'next/server'
import { requireProvisioningAccess } from '@/lib/provisioning/guard'
import { startProvisioningJob } from '@/lib/provisioning/worker'
import { writeAuditEvent } from '@/lib/provisioning/audit'
import { query } from '@/lib/db'
import redis from '@/lib/redis'
import crypto from 'crypto'

export const dynamic = 'force-dynamic'

/** Slug validation: lowercase alphanumeric + hyphens, 2–48 chars */
const SLUG_RE = /^[a-z0-9][a-z0-9-]{1,47}$/

// ----------------------------------------------------------------
// GET /api/cabinets — list all Cabinets for the authenticated Captain
// ----------------------------------------------------------------

export async function GET() {
  const guard = await requireProvisioningAccess()
  if (guard.response) return guard.response

  try {
    const cabinets = await query<{
      cabinet_id: string
      captain_id: string
      name: string
      preset: string
      capacity: string
      state: string
      state_entered_at: string
      officer_slots: unknown
      retry_count: number
      created_at: string
    }>(
      `SELECT cabinet_id, captain_id, name, preset, capacity, state,
              state_entered_at, officer_slots, retry_count, created_at
       FROM cabinets
       ORDER BY created_at DESC`
    )

    return NextResponse.json({ ok: true, cabinets })
  } catch (err) {
    console.error('[api/cabinets] GET error', err)
    return NextResponse.json({ ok: false, message: 'Failed to list cabinets' }, { status: 500 })
  }
}

// ----------------------------------------------------------------
// POST /api/cabinets — create + start provisioning a new Cabinet
// ----------------------------------------------------------------

interface CreateCabinetBody {
  name: string
  preset: string
  capacity?: string
}

export async function POST(req: NextRequest) {
  const guard = await requireProvisioningAccess()
  if (guard.response) return guard.response

  const { user } = guard

  let body: CreateCabinetBody
  try {
    body = (await req.json()) as CreateCabinetBody
  } catch {
    return NextResponse.json({ ok: false, message: 'Invalid JSON body' }, { status: 400 })
  }

  // Input validation
  if (!body.name?.trim()) {
    return NextResponse.json({ ok: false, message: 'name is required' }, { status: 400 })
  }
  if (!SLUG_RE.test(body.name.trim())) {
    return NextResponse.json(
      {
        ok: false,
        message:
          'name must be lowercase alphanumeric with hyphens, 2–48 characters, starting with a letter or digit',
      },
      { status: 400 }
    )
  }
  if (!body.preset?.trim()) {
    return NextResponse.json({ ok: false, message: 'preset is required' }, { status: 400 })
  }

  const name = body.name.trim()
  const preset = body.preset.trim()
  const capacity = (body.capacity || preset).trim()
  const captain_id = user.token // TODO (PR 5): real captain identity

  // ---- Concurrent-name lock: Redis SETNX cabinet:provisioning-lock:<captain_id> ----
  const lockKey = `cabinet:provisioning-lock:${captain_id}`
  const LOCK_TTL_SECONDS = 30 * 60 // 30 minutes

  // ioredis: SET key value NX EX seconds returns 'OK' or null
  // For mock Redis, fall back to get+set pattern
  let lockAcquired: boolean
  try {
    // Try real Redis SET NX EX
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const r = redis as any
    if (typeof r.set === 'function') {
      const result = await r.set(lockKey, '1', 'NX', 'EX', LOCK_TTL_SECONDS)
      lockAcquired = result === 'OK'
    } else {
      // Mock Redis: simulate SETNX
      const existing = await redis.get(lockKey)
      if (existing) {
        lockAcquired = false
      } else {
        await redis.set(lockKey, '1')
        lockAcquired = true
      }
    }
  } catch (err) {
    console.error('[api/cabinets] Redis lock error', err)
    // Fail open: allow creation but log
    lockAcquired = true
  }

  if (!lockAcquired) {
    return NextResponse.json(
      { ok: false, message: 'Another cabinet creation is already in flight for this Captain' },
      { status: 409 }
    )
  }

  // ---- Generate cabinet_id ----
  const cabinet_id = `cab_${crypto.randomBytes(8).toString('hex')}`

  try {
    // ---- Insert with unique constraint check ----
    // INSERT ... ON CONFLICT (captain_id, name) DO NOTHING
    const result = await query<{ cabinet_id: string }>(
      `INSERT INTO cabinets
         (cabinet_id, captain_id, name, preset, capacity, state, state_entered_at, officer_slots, retry_count)
       VALUES ($1, $2, $3, $4, $5, 'creating', now(), '[]'::jsonb, 0)
       ON CONFLICT (captain_id, name) DO NOTHING
       RETURNING cabinet_id`,
      [cabinet_id, captain_id, name, preset, capacity]
    )

    if (result.length === 0) {
      // Conflict: cabinet with same name already exists for this captain
      await redis.del(lockKey)
      return NextResponse.json(
        { ok: false, message: `Cabinet '${name}' already exists` },
        { status: 409 }
      )
    }

    // Write initial audit event
    await writeAuditEvent({
      cabinet_id,
      actor: user.token,
      entry_point: 'dashboard',
      event_type: 'state_transition',
      state_before: null,
      state_after: 'creating',
      payload: { name, preset, capacity },
    })

    // Dispatch async provisioning job (fire-and-forget; does NOT re-insert the row)
    startProvisioningJob({
      cabinet_id,
      captain_id,
      name,
      preset,
      capacity,
      actor: user.token,
    })

    // Lock is released by the worker when Cabinet reaches a stable state.
    // We keep it set here so concurrent creates are blocked during provisioning.

    return NextResponse.json({ ok: true, cabinet_id }, { status: 202 })
  } catch (err) {
    // Release lock on unexpected errors
    try {
      await redis.del(lockKey)
    } catch { /* swallow */ }

    console.error('[api/cabinets] POST error', err)
    return NextResponse.json({ ok: false, message: 'Failed to create cabinet' }, { status: 500 })
  }
}
