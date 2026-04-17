'use client'

/**
 * Spec 034 PR 2 — CabinetDetailClient
 *
 * Client component for the /cabinets/[id] detail page.
 * Provides:
 *   - Suspend / Resume / Archive action buttons
 *   - 5-second polling refresh of cabinet state (polling stub — SSE is PR 5)
 *   - Archive two-confirm modal via ArchiveConfirm
 *
 * Polling: useEffect sets a 5s interval that calls GET /api/cabinets/:id
 * and updates local state. A manual "Refresh" button is also exposed.
 * The interval is cleared on unmount.
 *
 * TODO (PR 5): Replace polling with SSE subscription to
 *   GET /api/cabinets/:id/provisioning-status (with Last-Event-ID reconnect).
 *
 * Spec refs: PR 2 scope "Live status is a placeholder — use 5s polling fallback",
 *            §State Machine ARCHIVE_BLOCKED_STATES, AC 9.
 */

import { useState, useEffect, useTransition, useCallback } from 'react'
import { useRouter } from 'next/navigation'
import { suspendCabinet, resumeCabinet } from '@/actions/cabinets'
import ArchiveConfirm from '@/components/cabinets/archive-confirm'
import type { CabinetRow } from '@/components/cabinets/cabinet-list'

const POLL_INTERVAL_MS = 5_000

// States where the archive button must be disabled
const ARCHIVE_BLOCKED = new Set([
  'creating', 'adopting-bots', 'provisioning', 'starting', 'archiving', 'archived',
])

interface CabinetDetailClientProps {
  cabinet: CabinetRow
  baseUrl: string
}

export default function CabinetDetailClient({ cabinet: initialCabinet, baseUrl }: CabinetDetailClientProps) {
  const router = useRouter()
  const [cabinet, setCabinet] = useState<CabinetRow>(initialCabinet)
  const [isPolling, setIsPolling] = useState(false)
  const [isPending, startTransition] = useTransition()
  const [actionError, setActionError] = useState<string | null>(null)
  const [showArchive, setShowArchive] = useState(false)
  const [lastRefreshed, setLastRefreshed] = useState<Date | null>(null)

  // Derive action availability from current state
  const isUnstable = ARCHIVE_BLOCKED.has(cabinet.state)
  const isArchived = cabinet.state === 'archived'
  const isActive = cabinet.state === 'active'
  const isSuspended = cabinet.state === 'suspended'
  const isFailed = cabinet.state === 'failed'
  const canSuspend = isActive && !isPending
  const canResume = isSuspended && !isPending
  const canArchive = (isActive || isSuspended || isFailed) && !isPending

  // Polling for live state (PR 2 stub — PR 5 replaces with SSE)
  // TODO (PR 5): Replace this interval with an EventSource subscription.
  const pollState = useCallback(async () => {
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
      // Swallow poll errors — manual refresh still available
    }
  }, [baseUrl, cabinet.cabinet_id])

  useEffect(() => {
    setIsPolling(true)
    const interval = setInterval(pollState, POLL_INTERVAL_MS)
    return () => {
      clearInterval(interval)
      setIsPolling(false)
    }
  }, [pollState])

  function handleManualRefresh() {
    void pollState()
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

  const STATE_LABELS: Record<string, { dot: string; text: string; label: string }> = {
    'creating':      { dot: 'bg-amber-400', text: 'text-amber-400', label: 'Creating' },
    'adopting-bots': { dot: 'bg-amber-400', text: 'text-amber-400', label: 'Adopting bots' },
    'provisioning':  { dot: 'bg-blue-400',  text: 'text-blue-400',  label: 'Provisioning' },
    'starting':      { dot: 'bg-blue-400',  text: 'text-blue-400',  label: 'Starting' },
    'active':        { dot: 'bg-green-400', text: 'text-green-400', label: 'Active' },
    'suspended':     { dot: 'bg-zinc-500',  text: 'text-zinc-400',  label: 'Suspended' },
    'failed':        { dot: 'bg-red-500',   text: 'text-red-400',   label: 'Failed' },
    'archiving':     { dot: 'bg-orange-400',text: 'text-orange-400',label: 'Archiving' },
    'archived':      { dot: 'bg-zinc-600',  text: 'text-zinc-500',  label: 'Archived' },
  }

  const cfg = STATE_LABELS[cabinet.state] || { dot: 'bg-zinc-500', text: 'text-zinc-400', label: cabinet.state }

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
        </div>

        {/* Manual refresh button */}
        <button
          type="button"
          onClick={handleManualRefresh}
          className="inline-flex items-center gap-1.5 rounded-lg border border-zinc-700 bg-zinc-800 px-2.5 py-1.5 text-xs font-medium text-zinc-400 hover:border-zinc-600 hover:text-zinc-200 transition-colors min-h-[44px]"
        >
          <svg className={`h-3.5 w-3.5 ${isPolling ? 'animate-spin' : ''}`} fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0l3.181 3.183a8.25 8.25 0 0013.803-3.7M4.031 9.865a8.25 8.25 0 0113.803-3.7l3.181 3.182m0-4.991v4.99" />
          </svg>
          Refresh
        </button>
      </div>

      {/* SSE placeholder note */}
      <p className="mt-2 text-xs text-zinc-700 italic">
        {/* TODO (PR 5): Replace 5s polling with real-time SSE stream. */}
        Polling every 5s. Real-time SSE will arrive in PR 5.
      </p>

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

      {/* Archive confirmation modal */}
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
