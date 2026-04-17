'use client'

/**
 * Spec 034 PR 2 — CabinetList
 *
 * Renders the list of cabinets with state badges and manage/suspend/archive
 * action buttons. Handles the archive two-confirm modal inline.
 *
 * Feature-flag: parent page never renders this component when the flag is off.
 * State badge colours match the spec state machine table.
 * Archive/Suspend buttons disabled in non-stable states (per spec AC 9 + COO 034.5).
 */

import Link from 'next/link'
import { useState, useTransition } from 'react'
import { suspendCabinet, resumeCabinet } from '@/actions/cabinets'
import ArchiveConfirm from './archive-confirm'
import { STATE_LABELS } from '@/lib/provisioning/labels'
import type { CabinetRow } from '@/lib/provisioning/types'

// Re-export CabinetRow for backward compat (other files still import from here)
export type { CabinetRow }

// States where suspend/archive actions must be disabled (non-stable)
const UNSTABLE_STATES = new Set([
  'creating',
  'adopting-bots',
  'provisioning',
  'starting',
  'archiving',
  'archived',
])

function StateBadge({ state }: { state: string }) {
  const cfg = STATE_LABELS[state] || { label: state, dot: 'bg-zinc-500', text: 'text-zinc-400' }
  return (
    <span className={`inline-flex items-center gap-1.5 text-xs font-medium ${cfg.text}`}>
      <span className={`h-2 w-2 rounded-full ${cfg.dot} flex-shrink-0`} aria-hidden="true" />
      {cfg.label}
    </span>
  )
}

function OfficerCount({ slots }: { slots: unknown }): React.ReactNode {
  if (!Array.isArray(slots) || slots.length === 0) return null
  return <span className="text-xs text-zinc-500">{slots.length} officer{slots.length !== 1 ? 's' : ''}</span>
}

function formatDate(iso: string): string {
  try {
    return new Intl.DateTimeFormat('en-US', { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(iso))
  } catch {
    return iso
  }
}

interface CabinetCardProps {
  cabinet: CabinetRow
  onAction: () => void
}

function CabinetCard({ cabinet, onAction }: CabinetCardProps) {
  const [isPending, startTransition] = useTransition()
  const [showArchive, setShowArchive] = useState(false)
  const [actionError, setActionError] = useState<string | null>(null)

  const isUnstable = UNSTABLE_STATES.has(cabinet.state)
  const isArchived = cabinet.state === 'archived'
  const isSuspended = cabinet.state === 'suspended'
  const isActive = cabinet.state === 'active'
  const isFailed = cabinet.state === 'failed'
  const canSuspend = isActive && !isPending
  const canResume = isSuspended && !isPending
  const canArchive = (isActive || isSuspended || isFailed) && !isPending

  function handleSuspend() {
    setActionError(null)
    startTransition(async () => {
      const res = await suspendCabinet(cabinet.cabinet_id)
      if (!res.ok) setActionError(res.message || 'Suspend failed')
      else onAction()
    })
  }

  function handleResume() {
    setActionError(null)
    startTransition(async () => {
      const res = await resumeCabinet(cabinet.cabinet_id)
      if (!res.ok) setActionError(res.message || 'Resume failed')
      else onAction()
    })
  }

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
      {/* Header row */}
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2 flex-wrap">
            <h3 className="text-base font-semibold text-white truncate">{cabinet.name}</h3>
            <StateBadge state={cabinet.state} />
          </div>
          <div className="mt-1 flex items-center gap-3 flex-wrap">
            <span className="text-xs text-zinc-500 capitalize">{cabinet.preset} preset</span>
            <OfficerCount slots={cabinet.officer_slots} />
            <span className="text-xs text-zinc-600">since {formatDate(cabinet.created_at)}</span>
          </div>
        </div>

        {/* Manage → detail link */}
        {!isArchived && (
          <Link
            href={`/cabinets/${cabinet.cabinet_id}`}
            className="flex-shrink-0 rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-xs font-medium text-zinc-300 transition-colors hover:border-zinc-600 hover:text-white"
          >
            {isUnstable ? 'Status →' : 'Manage →'}
          </Link>
        )}
      </div>

      {/* Retry circuit breaker warning */}
      {isFailed && cabinet.retry_count >= 3 && (
        <div className="mt-3 rounded-lg border border-red-800/50 bg-red-900/20 px-3 py-2">
          <p className="text-xs text-red-400">
            Provisioning failed 3+ times. Retry is disabled — archive and recreate to start fresh.
          </p>
        </div>
      )}

      {/* Action error */}
      {actionError && (
        <div className="mt-3 rounded-lg border border-red-800/50 bg-red-900/20 px-3 py-2">
          <p className="text-xs text-red-400">{actionError}</p>
        </div>
      )}

      {/* Action buttons */}
      {!isArchived && (
        <div className="mt-4 flex items-center gap-2 flex-wrap">
          {canSuspend && (
            <button
              onClick={handleSuspend}
              disabled={isPending}
              className="rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-xs font-medium text-zinc-400 transition-colors hover:border-zinc-600 hover:text-zinc-200 disabled:opacity-50 disabled:cursor-not-allowed min-h-[44px] md:min-h-0"
            >
              {isPending ? 'Suspending…' : 'Suspend'}
            </button>
          )}

          {canResume && (
            <button
              onClick={handleResume}
              disabled={isPending}
              className="rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-xs font-medium text-zinc-400 transition-colors hover:border-zinc-600 hover:text-zinc-200 disabled:opacity-50 disabled:cursor-not-allowed min-h-[44px] md:min-h-0"
            >
              {isPending ? 'Resuming…' : 'Resume'}
            </button>
          )}

          <button
            onClick={() => setShowArchive(true)}
            disabled={!canArchive || isUnstable}
            title={isUnstable ? `Cannot archive in '${cabinet.state}' state` : undefined}
            className="rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-xs font-medium text-red-400 transition-colors hover:border-red-700 hover:text-red-300 disabled:opacity-40 disabled:cursor-not-allowed min-h-[44px] md:min-h-0"
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
            onAction()
          }}
        />
      )}
    </div>
  )
}

interface CabinetListProps {
  cabinets: CabinetRow[]
  onAction: () => void
}

export default function CabinetList({ cabinets, onAction }: CabinetListProps) {
  if (cabinets.length === 0) {
    return (
      <div className="rounded-xl border border-zinc-800 bg-zinc-900 px-6 py-12 text-center">
        <p className="text-sm text-zinc-400">No cabinets yet.</p>
        <p className="mt-1 text-xs text-zinc-600">
          Create your first cabinet to provision a new set of officers.
        </p>
      </div>
    )
  }

  return (
    <div className="space-y-4">
      {cabinets.map((cabinet) => (
        <CabinetCard key={cabinet.cabinet_id} cabinet={cabinet} onAction={onAction} />
      ))}
    </div>
  )
}
