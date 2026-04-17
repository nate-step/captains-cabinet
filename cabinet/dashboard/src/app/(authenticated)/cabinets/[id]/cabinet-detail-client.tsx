'use client'

/**
 * Spec 034 PR 5 — CabinetDetailClient
 *
 * Client component for the /cabinets/[id] detail page.
 * PR 5 replaces the 5s polling stub with a real EventSource SSE subscription.
 *
 * SSE behaviour (AC 5, AC 6):
 *  - On mount: opens EventSource to GET /api/cabinets/:id/provisioning-status
 *  - Last-Event-ID is tracked and sent on reconnect (EventSource does this natively)
 *  - Server emits keep-alive pings every 15s — EventSource ignores comment lines
 *  - Auto-close: server closes stream on active | archived | failed
 *  - "Refresh" button remains as a fallback if the stream is dropped
 *
 * On stream error: EventSource auto-reconnects with exponential backoff.
 * On disconnect, client re-fetches GET /api/cabinets/:id as a safety snapshot.
 *
 * Spec refs: AC 5 (SSE not polling), AC 6 (reconnect + Last-Event-ID),
 *            §SSE reconnection, cabinet-list.tsx TYPE consolidation (PR 5).
 */

import { useState, useEffect, useTransition, useCallback, useRef } from 'react'
import { useRouter } from 'next/navigation'
import { suspendCabinet, resumeCabinet } from '@/actions/cabinets'
import ArchiveConfirm from '@/components/cabinets/archive-confirm'
import { STATE_LABELS } from '@/lib/provisioning/labels'
import type { CabinetRow } from '@/lib/provisioning/types'

// States where the archive button must be disabled
const ARCHIVE_BLOCKED = new Set([
  'creating', 'adopting-bots', 'provisioning', 'starting', 'archiving', 'archived',
])

// Terminal states: SSE server closes the stream here; we stop reconnecting
const TERMINAL_STATES = new Set(['active', 'archived', 'failed'])

interface CabinetDetailClientProps {
  cabinet: CabinetRow
  baseUrl: string
}

export default function CabinetDetailClient({ cabinet: initialCabinet, baseUrl }: CabinetDetailClientProps) {
  const router = useRouter()
  const [cabinet, setCabinet] = useState<CabinetRow>(initialCabinet)
  const [isPending, startTransition] = useTransition()
  const [actionError, setActionError] = useState<string | null>(null)
  const [showArchive, setShowArchive] = useState(false)
  const [lastRefreshed, setLastRefreshed] = useState<Date | null>(null)
  const [streamStatus, setStreamStatus] = useState<'connecting' | 'live' | 'fallback'>('connecting')

  // Derive action availability from current state
  const isUnstable = ARCHIVE_BLOCKED.has(cabinet.state)
  const isArchived = cabinet.state === 'archived'
  const isActive = cabinet.state === 'active'
  const isSuspended = cabinet.state === 'suspended'
  const isFailed = cabinet.state === 'failed'
  const canSuspend = isActive && !isPending
  const canResume = isSuspended && !isPending
  const canArchive = (isActive || isSuspended || isFailed) && !isPending

  // Manual snapshot refresh (also used as SSE disconnect safety net)
  const fetchSnapshot = useCallback(async () => {
    try {
      const res = await fetch(`${baseUrl}/api/cabinets/${cabinet.cabinet_id}`, {
        cache: 'no-store',
      })
      if (res.ok) {
        const body = (await res.json()) as { ok: boolean; cabinet: CabinetRow }
        if (body.ok && body.cabinet) {
          setCabinet(body.cabinet)
          setLastRefreshed(new Date())
        }
      }
    } catch {
      // Swallow — manual refresh still available
    }
  }, [baseUrl, cabinet.cabinet_id])

  // SSE subscription via EventSource (PR 5)
  const esRef = useRef<EventSource | null>(null)

  useEffect(() => {
    const cabinetId = initialCabinet.cabinet_id
    const sseUrl = `${baseUrl}/api/cabinets/${cabinetId}/provisioning-status`

    // If already in a terminal state, no SSE needed
    if (TERMINAL_STATES.has(initialCabinet.state)) {
      setStreamStatus('fallback')
      return
    }

    let es: EventSource
    try {
      es = new EventSource(sseUrl)
      esRef.current = es
      setStreamStatus('connecting')

      es.onopen = () => {
        setStreamStatus('live')
      }

      es.onmessage = (evt) => {
        try {
          const data = JSON.parse(evt.data) as {
            type?: string
            state?: string
            state_after?: string
            state_entered_at?: string
            cabinet_id?: string
          }

          // Update cabinet state when a state transition arrives
          const newState = data.state_after || data.state
          if (newState && newState !== cabinet.state) {
            setCabinet((prev) => ({ ...prev, state: newState }))
            setLastRefreshed(new Date())
          }

          // Server signals stream done
          if (data.type === 'done') {
            setStreamStatus('fallback')
            es.close()
          }
        } catch { /* ignore parse errors */ }
      }

      es.onerror = () => {
        setStreamStatus('fallback')
        // EventSource auto-reconnects — we also re-fetch snapshot as safety net
        void fetchSnapshot()
      }
    } catch {
      // EventSource not available (unlikely in modern browsers)
      setStreamStatus('fallback')
    }

    return () => {
      if (esRef.current) {
        esRef.current.close()
        esRef.current = null
      }
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [baseUrl, initialCabinet.cabinet_id, initialCabinet.state])

  function handleManualRefresh() {
    void fetchSnapshot()
  }

  function handleSuspend() {
    setActionError(null)
    startTransition(async () => {
      const res = await suspendCabinet(cabinet.cabinet_id)
      if (!res.ok) setActionError(res.message || 'Suspend failed')
      else router.refresh()
    })
  }

  function handleResume() {
    setActionError(null)
    startTransition(async () => {
      const res = await resumeCabinet(cabinet.cabinet_id)
      if (!res.ok) setActionError(res.message || 'Resume failed')
      else router.refresh()
    })
  }

  const cfg = STATE_LABELS[cabinet.state] || { dot: 'bg-zinc-500', text: 'text-zinc-400', label: cabinet.state }

  const streamIndicator = streamStatus === 'live'
    ? <span className="text-xs text-green-600">Live</span>
    : streamStatus === 'connecting'
    ? <span className="text-xs text-amber-600">Connecting…</span>
    : <span className="text-xs text-zinc-600">Fallback mode</span>

  return (
    <div>
      {/* Current state display */}
      <div className="flex items-center justify-between flex-wrap gap-3">
        <div className="flex items-center gap-3">
          <span className={`inline-flex items-center gap-2 text-base font-medium ${cfg.text}`}>
            <span className={`h-3 w-3 rounded-full ${cfg.dot} flex-shrink-0 ${
              !isUnstable && !isArchived ? 'animate-pulse' : ''
            }`} />
            {cfg.label}
          </span>
          {lastRefreshed && (
            <span className="text-xs text-zinc-600">
              Updated {lastRefreshed.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}
            </span>
          )}
          {streamIndicator}
        </div>

        {/* Manual refresh button (SSE fallback) */}
        <button
          type="button"
          onClick={handleManualRefresh}
          className="inline-flex items-center gap-1.5 rounded-lg border border-zinc-700 bg-zinc-800 px-2.5 py-1.5 text-xs font-medium text-zinc-400 hover:border-zinc-600 hover:text-zinc-200 transition-colors min-h-[44px]"
        >
          <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0l3.181 3.183a8.25 8.25 0 0013.803-3.7M4.031 9.865a8.25 8.25 0 0113.803-3.7l3.181 3.182m0-4.991v4.99" />
          </svg>
          Refresh
        </button>
      </div>

      {/* Failed state: link to full provisioning log (AC 17) */}
      {isFailed && (
        <div className="mt-3">
          <a
            href={`/cabinets/${cabinet.cabinet_id}/log`}
            className="inline-flex items-center gap-1.5 text-xs text-red-400 hover:text-red-300 underline underline-offset-2"
          >
            View provisioning log
          </a>
        </div>
      )}

      {/* Action error */}
      {actionError && (
        <div className="mt-4 rounded-lg border border-red-800/50 bg-red-900/20 px-3 py-2">
          <p className="text-sm text-red-400">{actionError}</p>
        </div>
      )}

      {/* Action buttons */}
      {!isArchived && (
        <div className="mt-5 flex items-center gap-3 flex-wrap">
          {canSuspend && (
            <button
              onClick={handleSuspend}
              disabled={isPending}
              className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300 hover:border-zinc-600 hover:text-white transition-colors disabled:opacity-50 disabled:cursor-not-allowed min-h-[44px]"
            >
              {isPending ? 'Suspending…' : 'Suspend'}
            </button>
          )}

          {canResume && (
            <button
              onClick={handleResume}
              disabled={isPending}
              className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300 hover:border-zinc-600 hover:text-white transition-colors disabled:opacity-50 disabled:cursor-not-allowed min-h-[44px]"
            >
              {isPending ? 'Resuming…' : 'Resume'}
            </button>
          )}

          <button
            onClick={() => setShowArchive(true)}
            disabled={!canArchive || isUnstable}
            title={isUnstable ? `Cannot archive in '${cabinet.state}' state` : undefined}
            className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-2 text-sm font-medium text-red-400 hover:border-red-700 hover:text-red-300 transition-colors disabled:opacity-40 disabled:cursor-not-allowed min-h-[44px]"
          >
            Archive
          </button>
        </div>
      )}

      {/* Archive confirmation modal (PR 5: includes re-auth step) */}
      {showArchive && (
        <ArchiveConfirm
          cabinetName={cabinet.name}
          cabinetId={cabinet.cabinet_id}
          onClose={() => setShowArchive(false)}
          onSuccess={() => {
            setShowArchive(false)
            router.push('/cabinets')
          }}
        />
      )}
    </div>
  )
}
