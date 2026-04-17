/**
 * Spec 034 — POST /api/cabinets/[id]/resume
 *
 * Restart a suspended Cabinet. Transitions suspended → starting.
 * The starting state waits for first-boot heartbeat (PR 4 wires the actual
 * docker compose up + heartbeat listener).
 */

import { NextRequest, NextResponse } from 'next/server'
import { requireProvisioningAccess } from '@/lib/provisioning/guard'
import { writeTransitionEvent } from '@/lib/provisioning/audit'
import { canTransition } from '@/lib/provisioning/state-machine'
import { query, getDbPool } from '@/lib/db'

export const dynamic = 'force-dynamic'

export async function POST(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const guard = await requireProvisioningAccess()
  if (guard.response) return guard.response

  const { user } = guard
  const { id } = await params

  const pool = getDbPool()
  const client = await pool.connect()
  try {
    await client.query('BEGIN')

    const result = await client.query<{ state: string }>(
      'SELECT state FROM cabinets WHERE cabinet_id = $1 FOR UPDATE',
      [id]
    )

    if (result.rows.length === 0) {
      await client.query('ROLLBACK')
      return NextResponse.json({ ok: false, message: 'Cabinet not found' }, { status: 404 })
    }

    const { state } = result.rows[0]
    const check = canTransition(state as never, 'starting')

    if (!check.ok) {
      await client.query('ROLLBACK')
      return NextResponse.json(
        { ok: false, message: `Cannot resume: ${check.reason}` },
        { status: 409 }
      )
    }

    await client.query(
      `UPDATE cabinets SET state = 'starting', state_entered_at = now() WHERE cabinet_id = $1`,
      [id]
    )

    await client.query('COMMIT')

    await writeTransitionEvent({
      cabinet_id: id,
      actor: user.token,
      entry_point: 'dashboard',
      from: state as never,
      to: 'starting',
    })

    // TODO (PR 4): docker compose start for this Cabinet's containers.
    //   On first heartbeat → transition starting → active.

    return NextResponse.json({ ok: true, state: 'starting' })
  } catch (err) {
    await client.query('ROLLBACK')
    console.error(`[api/cabinets/${id}/resume] POST error`, err)
    return NextResponse.json({ ok: false, message: 'Failed to resume cabinet' }, { status: 500 })
  } finally {
    client.release()
  }
}
