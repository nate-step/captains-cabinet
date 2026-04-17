/**
 * Spec 034 — GET /api/cabinets/[id]/provisioning-status (SSE stub)
 *
 * PR 1 scope: returns a stub SSE response with current state snapshot.
 * Real streaming (event replay, Last-Event-ID, keep-alive pings) is wired
 * in PR 5.
 *
 * Client hints:
 *  - Connect with EventSource (not fetch) for auto-reconnect
 *  - Pass Last-Event-ID header on reconnect (server will replay from that ID in PR 5)
 *  - On disconnect, re-fetch GET /api/cabinets/:id for current state as a safety net
 */

import { NextRequest, NextResponse } from 'next/server'
import { requireProvisioningAccess } from '@/lib/provisioning/guard'
import { query } from '@/lib/db'
import { getAuditEvents } from '@/lib/provisioning/audit'

export const dynamic = 'force-dynamic'

export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const guard = await requireProvisioningAccess()
  if (guard.response) return guard.response

  const { id } = await params
  const lastEventIdHeader = req.headers.get('Last-Event-ID')
  const sinceEventId = lastEventIdHeader ? parseInt(lastEventIdHeader, 10) : undefined

  try {
    // Fetch current cabinet state
    const rows = await query<{ state: string; state_entered_at: string }>(
      'SELECT state, state_entered_at FROM cabinets WHERE cabinet_id = $1',
      [id]
    )
    if (rows.length === 0) {
      return NextResponse.json({ ok: false, message: 'Cabinet not found' }, { status: 404 })
    }

    const { state, state_entered_at } = rows[0]

    // Fetch audit events for replay (used in PR 5 for full SSE stream)
    const events = await getAuditEvents(id, sinceEventId)

    // TODO (PR 5): Return a real ReadableStream with:
    //   - Replay of events since Last-Event-ID
    //   - Live event forwarding as state transitions happen
    //   - SSE keep-alive :\n\n pings every 15s to prevent 30s proxy timeout
    //
    // PR 1 stub: return current snapshot as a single SSE event then close

    const snapshot = {
      cabinet_id: id,
      state,
      state_entered_at,
      event_count: events.length,
      last_event_id: events.length > 0 ? events[events.length - 1].event_id : null,
    }

    const sseData = `id: ${snapshot.last_event_id ?? 0}\ndata: ${JSON.stringify(snapshot)}\n\n`

    return new NextResponse(sseData, {
      headers: {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-cache, no-transform',
        Connection: 'keep-alive',
        'X-Accel-Buffering': 'no', // disable nginx buffering
        // Stub note: real streaming in PR 5
        'X-Provisioning-SSE-Stub': 'true',
      },
    })
  } catch (err) {
    console.error(`[api/cabinets/${id}/provisioning-status] GET error`, err)
    return NextResponse.json(
      { ok: false, message: 'Failed to fetch provisioning status' },
      { status: 500 }
    )
  }
}
