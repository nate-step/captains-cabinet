'use client'

/**
 * TasksClientRefresh — live-refresh the /tasks server component on changes.
 *
 * Primary: SSE stream at /api/tasks/stream (Redis Pub/Sub channel
 *   `cabinet:tasks:updated` — published by tasks.ts mutation helpers).
 * Fallback: 3s polling refresh if SSE fails or EventSource is unavailable.
 *
 * Also exposes a small status dot in the header (green = live SSE,
 * amber = poll fallback, red = offline) so the Captain can tell at a glance
 * whether the board is real-time.
 */

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'

type ConnectionState = 'connecting' | 'live' | 'polling' | 'offline'

export default function TasksClientRefresh() {
  const router = useRouter()
  const [state, setState] = useState<ConnectionState>('connecting')

  useEffect(() => {
    let pollTimer: ReturnType<typeof setInterval> | null = null
    let es: EventSource | null = null

    function startPolling() {
      if (pollTimer) return
      setState('polling')
      pollTimer = setInterval(() => router.refresh(), 3000)
    }
    function stopPolling() {
      if (pollTimer) {
        clearInterval(pollTimer)
        pollTimer = null
      }
    }

    if (typeof EventSource === 'undefined') {
      startPolling()
      return () => stopPolling()
    }

    try {
      es = new EventSource('/api/tasks/stream')
      es.onopen = () => {
        setState('live')
        stopPolling()
      }
      es.addEventListener('tasks:updated', () => {
        router.refresh()
      })
      es.onerror = () => {
        setState('offline')
        es?.close()
        es = null
        startPolling()
      }
    } catch {
      startPolling()
    }

    return () => {
      stopPolling()
      es?.close()
    }
  }, [router])

  const color =
    state === 'live'
      ? 'bg-green-500'
      : state === 'polling'
        ? 'bg-amber-500'
        : state === 'offline'
          ? 'bg-red-500'
          : 'bg-zinc-500'
  const label =
    state === 'live'
      ? 'Live'
      : state === 'polling'
        ? 'Polling'
        : state === 'offline'
          ? 'Offline'
          : 'Connecting…'

  return (
    <div className="flex items-center gap-2 text-xs text-zinc-500">
      <span className={`inline-block h-2 w-2 rounded-full ${color}`} aria-hidden />
      <span>{label}</span>
    </div>
  )
}
