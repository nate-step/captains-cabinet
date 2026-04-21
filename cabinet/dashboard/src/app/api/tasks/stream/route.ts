/**
 * GET /api/tasks/stream — SSE stream for live task updates.
 *
 * Reuses the Spec 034 provisioning-status SSE pattern:
 * - Redis Pub/Sub on `cabinet:tasks:updated`
 * - 15s keep-alive pings (< Vercel/CF 30s timeout)
 * - Polling fallback (3s) when Redis unavailable
 * - Client disconnect cleanup
 *
 * Spec 038 §4.6.
 */

import { NextRequest, NextResponse } from 'next/server'

export const dynamic = 'force-dynamic'

const KEEPALIVE_INTERVAL_MS = 15_000
const POLL_INTERVAL_MS = 3_000

export async function GET(req: NextRequest) {
  // Verify auth cookie exists (same check as layout.tsx uses)
  const { cookies } = await import('next/headers')
  const cookieStore = await cookies()
  const sessionToken = cookieStore.get('cabinet_session')?.value
  if (!sessionToken) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }

  const stream = new ReadableStream({
    async start(controller) {
      let closed = false
      let keepaliveTimer: ReturnType<typeof setInterval> | null = null
      let pollTimer: ReturnType<typeof setInterval> | null = null
      let subClient: {
        subscribe: (channel: string) => Promise<unknown>
        unsubscribe: (channel: string) => void
        on: (event: string, handler: (...args: unknown[]) => void) => void
        quit?: () => Promise<unknown>
        disconnect?: () => void
      } | null = null

      // Named SSE events so `EventSource.addEventListener('tasks:updated', ...)`
      // fires on the client. Anonymous `data:` frames only trigger `onmessage`.
      function emit(eventName: string, data: unknown) {
        if (closed) return
        try {
          controller.enqueue(
            new TextEncoder().encode(
              `event: ${eventName}\ndata: ${JSON.stringify(data)}\n\n`
            )
          )
        } catch {
          cleanup()
        }
      }

      function ping() {
        if (closed) return
        try {
          controller.enqueue(new TextEncoder().encode(':\n\n'))
        } catch {
          cleanup()
        }
      }

      function cleanup() {
        if (closed) return
        closed = true
        if (keepaliveTimer) clearInterval(keepaliveTimer)
        if (pollTimer) clearInterval(pollTimer)
        if (subClient) {
          try {
            subClient.unsubscribe('cabinet:tasks:updated')
            if (typeof subClient.quit === 'function') subClient.quit()
            else if (typeof subClient.disconnect === 'function') subClient.disconnect()
          } catch { /* ignore */ }
          subClient = null
        }
        try { controller.close() } catch { /* already closed */ }
      }

      // Initial connected frame so the client's onopen / default handler fires.
      emit('connected', { timestamp: new Date().toISOString() })

      // Keep-alive
      keepaliveTimer = setInterval(() => {
        if (closed) return
        try { ping() } catch { cleanup() }
      }, KEEPALIVE_INTERVAL_MS)

      // Redis Pub/Sub (primary path)
      const REDIS_URL = process.env.REDIS_URL
      if (REDIS_URL) {
        try {
          const { default: Redis } = await import('ioredis')
          const sub = new Redis(REDIS_URL)
          subClient = sub

          sub.subscribe('cabinet:tasks:updated').catch((err: unknown) => {
            console.warn('[tasks/stream] Redis subscribe error', err)
            cleanup()
          })

          sub.on('message', (_channel: unknown, message: unknown) => {
            if (closed) return
            try {
              const parsed = typeof message === 'string'
                ? JSON.parse(message) as { officer_slug: string; timestamp: string }
                : null
              emit('tasks:updated', { ...(parsed ?? {}), timestamp: new Date().toISOString() })
            } catch {
              emit('tasks:updated', { timestamp: new Date().toISOString() })
            }
          })

          sub.on('error', (err: Error) => {
            console.warn('[tasks/stream] Redis sub error', err)
            cleanup()
          })
        } catch (err) {
          console.warn('[tasks/stream] Redis Pub/Sub unavailable, using polling fallback', err)
          subClient = null
        }
      }

      // Polling fallback (dev or Redis unavailable). pollTimer lives in the
      // outer scope so cleanup() can clear it on client disconnect — without
      // that, the interval leaks once the request aborts.
      if (!subClient) {
        pollTimer = setInterval(() => {
          if (closed) return
          emit('tasks:updated', { timestamp: new Date().toISOString(), source: 'poll' })
        }, POLL_INTERVAL_MS)
      }

      // Cleanup on client disconnect
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
      'X-Accel-Buffering': 'no',
    },
  })
}
