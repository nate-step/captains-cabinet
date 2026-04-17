/**
 * Spec 034 — POST /api/cabinets/[id]/cancel
 *
 * Cancel a Cabinet that is in `adopting-bots` state.
 * Only valid in `adopting-bots`. Returns 409 in any other state.
 *
 * Triggers cleanup of partially-registered tokens + flags orphaned bots
 * to Captain for manual BotFather deletion (per CoS L2).
 *
 * Not callable in `provisioning` or later — fail forward, archive after.
 */

import { NextRequest, NextResponse } from 'next/server'
import { requireProvisioningAccess } from '@/lib/provisioning/guard'
import { writeAuditEvent } from '@/lib/provisioning/audit'
import { query, getDbPool } from '@/lib/db'
import redis from '@/lib/redis'

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

    const result = await client.query<{
      captain_id: string
      state: string
      officer_slots: Array<{ role: string; bot_token: string | null; adopted_at: string | null }>
    }>(
      'SELECT captain_id, state, officer_slots FROM cabinets WHERE cabinet_id = $1 FOR UPDATE',
      [id]
    )

    if (result.rows.length === 0) {
      await client.query('ROLLBACK')
      return NextResponse.json({ ok: false, message: 'Cabinet not found' }, { status: 404 })
    }

    const { captain_id, state, officer_slots } = result.rows[0]

    if (state !== 'adopting-bots') {
      await client.query('ROLLBACK')
      return NextResponse.json(
        {
          ok: false,
          message: `Cancel is only valid in 'adopting-bots' state. Current state: '${state}'. Use archive after provisioning starts.`,
        },
        { status: 409 }
      )
    }

    // Collect any partially adopted tokens that will become orphans
    const slots: Array<{ role: string; bot_token: string | null; adopted_at: string | null }> =
      Array.isArray(officer_slots) ? officer_slots : []
    const adoptedSlots = slots.filter((s) => s.bot_token !== null)

    // Transition to failed (cancel goes through failed per state machine)
    // The spec shows 'cancelled' conceptually — we map it to 'failed' since
    // the state machine allows adopting-bots → failed
    await client.query(
      `UPDATE cabinets SET state = 'failed', state_entered_at = now() WHERE cabinet_id = $1`,
      [id]
    )

    await client.query('COMMIT')

    // Audit: cancel event
    await writeAuditEvent({
      cabinet_id: id,
      actor: user.token,
      entry_point: 'dashboard',
      event_type: 'cancel',
      state_before: 'adopting-bots',
      state_after: 'failed',
      payload: {
        reason: 'captain-cancelled',
        partially_adopted_count: adoptedSlots.length,
      },
    })

    // Flag each orphaned bot
    for (const slot of adoptedSlots) {
      await writeAuditEvent({
        cabinet_id: id,
        actor: user.token,
        entry_point: 'dashboard',
        event_type: 'orphan_bot',
        payload: {
          officer: slot.role,
          orphan_token: slot.bot_token, // redacted by audit.ts
          message: `Bot for officer '${slot.role}' is orphaned — delete it in BotFather`,
        },
      })
    }

    // Release provisioning lock so Captain can create a new Cabinet
    const lockKey = `cabinet:provisioning-lock:${captain_id}`
    try {
      await redis.del(lockKey)
    } catch (err) {
      console.warn(`[api/cabinets/${id}/cancel] Could not release lock:`, err)
    }

    return NextResponse.json({
      ok: true,
      message: 'Cabinet cancelled and moved to failed state',
      orphaned_bots: adoptedSlots.map((s) => s.role),
    })
  } catch (err) {
    await client.query('ROLLBACK')
    console.error(`[api/cabinets/${id}/cancel] POST error`, err)
    return NextResponse.json({ ok: false, message: 'Failed to cancel cabinet' }, { status: 500 })
  } finally {
    client.release()
  }
}
