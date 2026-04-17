/**
 * Spec 034 — POST /api/cabinets/[id]/archive
 *
 * Archive a Cabinet: stop containers, remove peers.yml entries, PRESERVE rows.
 * This is NOT a delete. Data is retained under cabinet_id for future recovery.
 *
 * Hard constraints (per COO 034.5 + COO 034.7):
 *  - Returns 409 Conflict in non-stable states: creating, adopting-bots,
 *    provisioning, starting, archiving, archived
 *  - Requires re-auth (Captain password confirmation) — body must include
 *    `confirm_password` field (distinct from session cookie auth)
 *  - Requires name-type confirmation — body must include `confirm_name` matching
 *    the Cabinet's name
 *
 * Archive is valid from: active | suspended | failed
 *
 * PR 1 scope: state transition + audit. Actual Docker stop + peers.yml removal
 * is wired in PR 5.
 */

import { NextRequest, NextResponse } from 'next/server'
import { requireProvisioningAccess } from '@/lib/provisioning/guard'
import { writeTransitionEvent, writeAuditEvent } from '@/lib/provisioning/audit'
import { ARCHIVE_BLOCKED_STATES, canTransition } from '@/lib/provisioning/state-machine'
import { checkPassword } from '@/lib/auth'
import { query, getDbPool } from '@/lib/db'
import redis from '@/lib/redis'

export const dynamic = 'force-dynamic'

interface ArchiveBody {
  /** Cabinet name typed by Captain to confirm (must match exactly) */
  confirm_name: string
  /** Captain's dashboard password (re-auth requirement per COO 034.7) */
  confirm_password: string
}

export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const guard = await requireProvisioningAccess()
  if (guard.response) return guard.response

  const { user } = guard
  const { id } = await params

  let body: ArchiveBody
  try {
    body = (await req.json()) as ArchiveBody
  } catch {
    return NextResponse.json({ ok: false, message: 'Invalid JSON body' }, { status: 400 })
  }

  if (!body.confirm_name?.trim()) {
    return NextResponse.json(
      { ok: false, message: 'confirm_name is required (type the Cabinet name to confirm)' },
      { status: 400 }
    )
  }
  if (!body.confirm_password) {
    return NextResponse.json(
      { ok: false, message: 'confirm_password is required (re-authentication for destructive op)' },
      { status: 400 }
    )
  }

  // Re-auth check (per COO 034.7)
  if (!checkPassword(body.confirm_password)) {
    return NextResponse.json(
      { ok: false, message: 'Re-authentication failed — incorrect password' },
      { status: 401 }
    )
  }

  const pool = getDbPool()
  const client = await pool.connect()
  try {
    await client.query('BEGIN')

    const result = await client.query<{
      captain_id: string
      name: string
      state: string
    }>(
      'SELECT captain_id, name, state FROM cabinets WHERE cabinet_id = $1 FOR UPDATE',
      [id]
    )

    if (result.rows.length === 0) {
      await client.query('ROLLBACK')
      return NextResponse.json({ ok: false, message: 'Cabinet not found' }, { status: 404 })
    }

    const { captain_id, name, state } = result.rows[0]

    // Name-type confirmation (second friction layer)
    if (body.confirm_name.trim() !== name) {
      await client.query('ROLLBACK')
      return NextResponse.json(
        {
          ok: false,
          message: `Cabinet name confirmation mismatch. Expected '${name}', got '${body.confirm_name.trim()}'`,
        },
        { status: 400 }
      )
    }

    // State check: archive blocked in non-stable in-flight states
    if (ARCHIVE_BLOCKED_STATES.includes(state as never)) {
      await client.query('ROLLBACK')
      return NextResponse.json(
        {
          ok: false,
          message: `Archive is not available in '${state}' state. Wait for a stable state (active, suspended, failed) or let the operation complete.`,
        },
        { status: 409 }
      )
    }

    const check = canTransition(state as never, 'archiving')
    if (!check.ok) {
      await client.query('ROLLBACK')
      return NextResponse.json(
        { ok: false, message: `Cannot archive: ${check.reason}` },
        { status: 409 }
      )
    }

    // Transition to archiving
    await client.query(
      `UPDATE cabinets SET state = 'archiving', state_entered_at = now() WHERE cabinet_id = $1`,
      [id]
    )

    await client.query('COMMIT')

    await writeTransitionEvent({
      cabinet_id: id,
      actor: user.token,
      entry_point: 'dashboard',
      from: state as never,
      to: 'archiving',
      payload: { confirm_name: body.confirm_name },
    })

    // Release provisioning lock if held
    const lockKey = `cabinet:provisioning-lock:${captain_id}`
    try {
      await redis.del(lockKey)
    } catch (err) {
      console.warn(`[api/cabinets/${id}/archive] Could not release lock:`, err)
    }

    // TODO (PR 5): Kick off async archival worker:
    //   1. docker compose stop for Cabinet's containers
    //   2. Remove peers.yml entries in both Cabinets (two-phase atomic)
    //   3. Leave rows in DB tagged by cabinet_id (data preservation)
    //   4. Transition archiving → archived on success

    // For PR 1, transition directly to archived (stub)
    try {
      await query(
        `UPDATE cabinets SET state = 'archived', state_entered_at = now() WHERE cabinet_id = $1`,
        [id]
      )
      await writeTransitionEvent({
        cabinet_id: id,
        actor: 'system',
        entry_point: 'worker',
        from: 'archiving',
        to: 'archived',
        payload: { note: 'PR 1 stub — actual archival in PR 5' },
      })
    } catch (err) {
      console.error(`[api/cabinets/${id}/archive] Could not transition to archived:`, err)
    }

    return NextResponse.json({
      ok: true,
      state: 'archiving',
      message:
        'Cabinet archival started. Containers will stop and peers.yml entries will be removed. Row data is preserved.',
    })
  } catch (err) {
    await client.query('ROLLBACK')
    console.error(`[api/cabinets/${id}/archive] POST error`, err)
    return NextResponse.json({ ok: false, message: 'Failed to archive cabinet' }, { status: 500 })
  } finally {
    client.release()
  }
}
