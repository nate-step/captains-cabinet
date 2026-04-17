/**
 * Spec 034 — POST /api/cabinets/[id]/adopt-bot
 *
 * Register a bot token for an officer slot. Idempotent per (cabinet, officer) pair.
 * Token-mismatch semantics: latest-wins. Second call with a different token
 * overwrites the first (old bot becomes orphan, flagged to Captain via audit event).
 *
 * PR 1 scope: records the token in officer_slots JSONB. Does NOT generate QR codes
 * or start BotFather flows (PR 3). Validates token format with regex.
 */

import { NextRequest, NextResponse } from 'next/server'
import { requireProvisioningAccess } from '@/lib/provisioning/guard'
import { writeAuditEvent } from '@/lib/provisioning/audit'
import { startProvisioningRun } from '@/lib/provisioning/worker'
import { canTransition } from '@/lib/provisioning/state-machine'
import { query, getDbPool } from '@/lib/db'

export const dynamic = 'force-dynamic'

/** Telegram bot token format: 8-12 digits : 35 alphanumeric+underscore+hyphen */
const BOT_TOKEN_RE = /^[0-9]{8,12}:[a-zA-Z0-9_-]{35}$/

interface AdoptBotBody {
  /** Officer role slug e.g. 'cos', 'cto' */
  officer: string
  /** Bot token from BotFather */
  bot_token: string
}

export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const guard = await requireProvisioningAccess()
  if (guard.response) return guard.response

  const { user } = guard
  const { id } = await params

  let body: AdoptBotBody
  try {
    body = (await req.json()) as AdoptBotBody
  } catch {
    return NextResponse.json({ ok: false, message: 'Invalid JSON body' }, { status: 400 })
  }

  // Validate inputs
  if (!body.officer?.trim()) {
    return NextResponse.json({ ok: false, message: 'officer is required' }, { status: 400 })
  }
  if (!body.bot_token?.trim()) {
    return NextResponse.json({ ok: false, message: 'bot_token is required' }, { status: 400 })
  }
  if (!BOT_TOKEN_RE.test(body.bot_token.trim())) {
    return NextResponse.json(
      {
        ok: false,
        message:
          'bot_token format is invalid. Expected: {8-12 digits}:{35 alphanumeric/underscore/hyphen}',
      },
      { status: 400 }
    )
  }

  const officer = body.officer.trim()
  const bot_token = body.bot_token.trim()

  const pool = getDbPool()
  const client = await pool.connect()
  try {
    await client.query('BEGIN')

    const result = await client.query<{
      state: string
      officer_slots: Array<{ role: string; bot_token: string | null; adopted_at: string | null }>
    }>(
      'SELECT state, officer_slots FROM cabinets WHERE cabinet_id = $1 FOR UPDATE',
      [id]
    )

    if (result.rows.length === 0) {
      await client.query('ROLLBACK')
      return NextResponse.json({ ok: false, message: 'Cabinet not found' }, { status: 404 })
    }

    const { state, officer_slots } = result.rows[0]

    // Only allow bot adoption in adopting-bots state
    if (state !== 'adopting-bots') {
      await client.query('ROLLBACK')
      return NextResponse.json(
        {
          ok: false,
          message: `Bot adoption is only allowed in 'adopting-bots' state. Current state: '${state}'`,
        },
        { status: 409 }
      )
    }

    // Find existing slot for this officer
    const slots: Array<{ role: string; bot_token: string | null; adopted_at: string | null }> =
      Array.isArray(officer_slots) ? officer_slots : []

    const existingIndex = slots.findIndex((s) => s.role === officer)
    let orphanToken: string | null = null

    if (existingIndex >= 0) {
      const existing = slots[existingIndex]
      if (existing.bot_token && existing.bot_token !== bot_token) {
        // Latest-wins: flag old token as orphan
        orphanToken = existing.bot_token
      }
      // Update in-place
      slots[existingIndex] = {
        role: officer,
        bot_token,
        adopted_at: new Date().toISOString(),
      }
    } else {
      // New slot
      slots.push({ role: officer, bot_token, adopted_at: new Date().toISOString() })
    }

    // Persist updated officer_slots
    await client.query(
      'UPDATE cabinets SET officer_slots = $1 WHERE cabinet_id = $2',
      [JSON.stringify(slots), id]
    )

    await client.query('COMMIT')

    // Audit: bot adopted
    await writeAuditEvent({
      cabinet_id: id,
      actor: user.token,
      entry_point: 'dashboard',
      event_type: 'adopt_bot',
      payload: {
        officer,
        // bot_token is redacted automatically by redactPayload (key contains 'token')
        bot_token,
        slot_count: slots.length,
      },
    })

    // If there was an orphaned token, flag it
    if (orphanToken) {
      await writeAuditEvent({
        cabinet_id: id,
        actor: user.token,
        entry_point: 'dashboard',
        event_type: 'orphan_bot',
        payload: {
          officer,
          // orphan_token is redacted by key name
          orphan_token: orphanToken,
          message: `Old bot for officer '${officer}' is now orphaned — delete it in BotFather`,
        },
      })
    }

    // TODO (PR 3): Determine expected slot count from preset definition.
    // For now we check if all expected roles have tokens.
    // If all slots are filled → kick off provisioning run.
    const allFilled = slots.length > 0 && slots.every((s) => s.bot_token !== null)
    if (allFilled) {
      // TODO (PR 3): Replace with actual preset officer count check
      startProvisioningRun(id, user.token)
    }

    const response: Record<string, unknown> = {
      ok: true,
      officer,
      slot_count: slots.length,
      all_bots_adopted: allFilled,
    }
    if (orphanToken) {
      response.orphan_warning = `You created a new bot for '${officer}' — delete the old one in BotFather`
    }

    return NextResponse.json(response)
  } catch (err) {
    await client.query('ROLLBACK')
    console.error(`[api/cabinets/${id}/adopt-bot] POST error`, err)
    return NextResponse.json({ ok: false, message: 'Failed to adopt bot' }, { status: 500 })
  } finally {
    client.release()
  }
}
