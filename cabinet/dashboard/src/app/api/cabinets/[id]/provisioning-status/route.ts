/**
 * Spec 034 PR 5 — GET /api/cabinets/[id]/provisioning-status (real SSE)
 *
 * Replaces the PR 1 stub. Returns a real streaming Response with:
 *  - Replay of audit events since Last-Event-ID (reconnect support)
 *  - Live event forwarding via Redis Pub/Sub subscription
 *  - SSE keep-alive ping every 15s (prevents Vercel/CF 30s proxy timeout)
 *  - Auto-close on terminal states: active | archived | failed
 *  - Proper cleanup on client disconnect
 *
 * Event bus: Redis Pub/Sub on `cabinet:events:<id>`.
 * The audit.ts writeAuditEvent() function publishes there after every DB insert,
 * so all provisioning transitions reach SSE consumers in real-time.
 *
 * Reconnect (AC 6):
 *  Client sends Last-Event-ID header → server replays events from that ID.
 *  Client re-fetches GET /api/cabinets/:id on reconnect as a safety net snapshot.
 *
 * Why Redis over Postgres LISTEN:
 *  Redis SUBSCRIBE is lighter (no connection pool pressure), already in infra,
 *  and doesn't require a dedicated long-lived Postgres connection per SSE client.
 *
 * Spec refs: AC 5 (SSE not polling), AC 6 (keep-alive + reconnect), §SSE reconnection,
 *            §SSE keep-alive, §Event bus (Redis Pub/Sub).
 */

import { NextRequest, NextResponse } from 'next/server'
import { requireProvisioningAccess } from '@/lib/provisioning/guard'
import { query } from '@/lib/db'
import { getAuditEvents } from '@/lib/provisioning/audit'

export const dynamic = 'force-dynamic'

/** States that signal the stream should close after emitting. */
const TERMINAL_SSE_STATES = new Set(['active', 'archived', 'failed'])

/** Keep-alive ping interval (15s < Vercel/CF 30s proxy timeout). */
const KEEPALIVE_INTERVAL_MS = 15_000

export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const guard = await requireProvisioningAccess()
  if (guard.response) return guard.response

  const { id } = await params
  const lastEventIdHeader = req.headers.get('Last-Event-ID')
  const sinceEventId = lastEventIdHeader ? parseInt(lastEventIdHeader, 10) : undefined

  // Verify cabinet exists before opening the stream
  const rows = await query<{ state: string; state_entered_at: string }>(
    'SELECT state, state_entered_at FROM cabinets WHERE cabinet_id = $1',
    [id]
  ).catch(() => null)

  if (!rows || rows.length === 0) {
    return NextResponse.json({ ok: false, message: 'Cabinet not found' }, { status: 404 })
  }

  const { state: currentState, state_entered_at } = rows[0]

  // Fetch historical events for replay
  const replayEvents = await getAuditEvents(id, sinceEventId).catch(() => [])

  const stream = new ReadableStream({
    async start(controller) {
      // -------------------------------------------------------------------
      // Helpers
      // -------------------------------------------------------------------
      function emit(data: unknown, eventId?: number | null) {
        const json = JSON.stringify(data)
        const idLine = eventId != null ? `id: ${eventId}\n` : ''
        controller.enqueue(new TextEncoder().encode(`${idLine}data: ${json}\n\n`))
      }

      function ping() {
        // SSE comment ping — keeps connection alive through proxies
        controller.enqueue(new TextEncoder().encode(':\n\n'))
      }

      function close() {
        try { controller.close() } catch { /* already closed */ }
        cleanup()
      }

      // -------------------------------------------------------------------
      // Step 1: Emit initial snapshot
      // -------------------------------------------------------------------
      const lastReplayId = replayEvents.length > 0
        ? replayEvents[replayEvents.length - 1].event_id
        : null

      emit({
        cabinet_id: id,
        state: currentState,
        state_entered_at,
        event_count: replayEvents.length,
        last_event_id: lastReplayId,
        type: 'snapshot',
      }, lastReplayId)

      // Emit each replayed event individually so client can track last-seen ID
      for (const evt of replayEvents) {
        emit({
          cabinet_id: id,
          event_id: evt.event_id,
          event_type: evt.event_type,
          state_before: evt.state_before,
          state_after: evt.state_after,
          timestamp: evt.timestamp,
          error: evt.error,
          type: 'event',
        }, evt.event_id)
      }

      // If already in a terminal state, close immediately after replay
      if (TERMINAL_SSE_STATES.has(currentState)) {
        emit({ type: 'done', state: currentState, cabinet_id: id }, null)
        close()
        return
      }

      // -------------------------------------------------------------------
      // Step 2: Subscribe to Redis Pub/Sub for live events
      // -------------------------------------------------------------------
      let subClient: { subscribe: Function; unsubscribe: Function; disconnect?: Function; quit?: Function } | null = null
      let keepaliveTimer: ReturnType<typeof setInterval> | null = null
      let closed = false

      function cleanup() {
        if (closed) return
        closed = true
        if (keepaliveTimer) clearInterval(keepaliveTimer)
        if (subClient) {
          try {
            subClient.unsubscribe(`cabinet:events:${id}`)
            if (typeof subClient.quit === 'function') subClient.quit()
            else if (typeof subClient.disconnect === 'function') subClient.disconnect()
          } catch { /* ignore disconnect errors */ }
          subClient = null
        }
      }

      // Set up keep-alive pings
      keepaliveTimer = setInterval(() => {
        if (closed) return
        try { ping() } catch { cleanup() }
      }, KEEPALIVE_INTERVAL_MS)

      // Attempt Redis Pub/Sub subscription
      // Only supported when a real ioredis client is available (not mock)
      const REDIS_URL = process.env.REDIS_URL
      if (REDIS_URL) {
        try {
          const { default: Redis } = await import('ioredis')
          // Create a dedicated subscriber connection (ioredis requires separate connection for SUBSCRIBE)
          const sub = new Redis(REDIS_URL)
          subClient = sub

          // ioredis subscribe returns a promise when no callback is provided
          sub.subscribe(`cabinet:events:${id}`).catch((err: unknown) => {
            console.error(`[SSE/${id}] Redis subscribe error`, err)
            cleanup()
          })

          sub.on('message', (channel: string, message: string) => {
            if (closed) return
            try {
              const parsed = JSON.parse(message) as {
                cabinet_id: string
                event_type: string
                state_before: string | null
                state_after: string | null
                error: string | null
                timestamp: string
              }

              // Fetch the latest event_id from the DB to use as SSE event id
              // (Redis pub carries the payload but not the DB-assigned event_id)
              const stateAfter = parsed.state_after || ''
              emit({
                cabinet_id: id,
                event_type: parsed.event_type,
                state_before: parsed.state_before,
                state_after: stateAfter,
                error: parsed.error,
                timestamp: parsed.timestamp,
                type: 'event',
              }, null)

              // Auto-close on terminal states
              if (stateAfter && TERMINAL_SSE_STATES.has(stateAfter)) {
                emit({ type: 'done', state: stateAfter, cabinet_id: id }, null)
                close()
              }
            } catch (parseErr) {
              console.warn(`[SSE/${id}] Failed to parse Redis message`, parseErr)
            }
          })

          sub.on('error', (err: Error) => {
            console.warn(`[SSE/${id}] Redis sub error`, err)
            cleanup()
          })
        } catch (redisErr) {
          // Redis unavailable — fall through to polling fallback below
          console.warn(`[SSE/${id}] Redis Pub/Sub not available, falling back to polling`, redisErr)
          subClient = null
        }
      }

      // -------------------------------------------------------------------
      // Step 3: Polling fallback (no Redis or mock env)
      // Used in development (MOCK_DATA=true) and when Redis is unreachable.
      // Polls DB every 3s — still better than 5s client-side polling.
      // -------------------------------------------------------------------
      if (!subClient) {
        let lastPolledState = currentState

        const pollTimer = setInterval(async () => {
          if (closed) { clearInterval(pollTimer); return }
          try {
            const pollRows = await query<{ state: string; state_entered_at: string }>(
              'SELECT state, state_entered_at FROM cabinets WHERE cabinet_id = $1',
              [id]
            )
            if (pollRows.length === 0) { close(); return }
            const { state: polledState, state_entered_at: polledAt } = pollRows[0]
            if (polledState !== lastPolledState) {
              lastPolledState = polledState
              emit({
                cabinet_id: id,
                event_type: 'state_transition',
                state_after: polledState,
                state_entered_at: polledAt,
                type: 'event',
              }, null)
              if (TERMINAL_SSE_STATES.has(polledState)) {
                emit({ type: 'done', state: polledState, cabinet_id: id }, null)
                clearInterval(pollTimer)
                close()
              }
            }
          } catch { /* swallow poll errors */ }
        }, 3_000)

        // Keep pollTimer ref so cleanup() stops it
        // (keepaliveTimer ref already held above)
      }

      // AbortSignal fires when client disconnects (Next.js 14+)
      req.signal?.addEventListener('abort', () => {
        cleanup()
      })
    },
  })

  return new Response(stream, {
    headers: {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no', // disable nginx buffering
      'Transfer-Encoding': 'chunked',
    },
  })
}
