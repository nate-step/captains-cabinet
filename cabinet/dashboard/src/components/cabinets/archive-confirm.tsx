'use client'

/**
 * Spec 034 PR 2 — ArchiveConfirm
 *
 * Two-confirm modal for cabinet archival:
 *   1. Type the cabinet name exactly
 *   2. Click the "Archive" button (enabled only when name matches)
 *
 * Re-auth wrapper: PR 5 stub — placeholder comment below marks the location
 * where passkey/password confirmation will be injected.
 *
 * Spec refs: AC 9, COO 034.7 (re-auth), §Management actions (archive semantics),
 *            §Delete is reframed as Archive (COO 034.1 — rows preserved).
 */

import { useState, useTransition } from 'react'
import { archiveCabinet } from '@/actions/cabinets'

interface ArchiveConfirmProps {
  cabinetName: string
  cabinetId: string
  onClose: () => void
  onSuccess: () => void
}

export default function ArchiveConfirm({ cabinetName, cabinetId, onClose, onSuccess }: ArchiveConfirmProps) {
  const [typedName, setTypedName] = useState('')
  const [isPending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)

  const nameMatches = typedName === cabinetName

  function handleArchive() {
    if (!nameMatches) return
    setError(null)

    // TODO (PR 5): Insert re-auth wrapper here (passkey / password confirmation).
    // COO 034.7 requires Captain re-authentication before archive proceeds.
    // PR 5 will add a <ReAuthGate> component that wraps this confirm step,
    // requiring the Captain to re-enter their passkey before the action fires.

    startTransition(async () => {
      const res = await archiveCabinet(cabinetId)
      if (!res.ok) {
        setError(res.message || 'Archive failed')
      } else {
        onSuccess()
      }
    })
  }

  function handleBackdropClick(e: React.MouseEvent<HTMLDivElement>) {
    if (e.target === e.currentTarget) onClose()
  }

  return (
    /* Modal backdrop */
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4"
      onClick={handleBackdropClick}
      role="dialog"
      aria-modal="true"
      aria-labelledby="archive-confirm-title"
    >
      <div className="w-full max-w-md rounded-xl border border-red-800/50 bg-zinc-900 p-6 shadow-xl">
        <h2 id="archive-confirm-title" className="text-lg font-semibold text-white">
          Archive Cabinet
        </h2>

        <p className="mt-3 text-sm text-zinc-300">
          This will stop containers and remove{' '}
          <span className="font-mono font-medium text-white">{cabinetName}</span> from your active
          cabinets. Your data (experience records, audit events) is preserved under this
          cabinet&rsquo;s ID — nothing is deleted.
        </p>

        <p className="mt-2 text-xs text-zinc-500">
          To restore a archived cabinet, re-provision it. Permanent data deletion requires
          CLI + re-auth + 24h cooling-off (not exposed in the dashboard).
        </p>

        <div className="mt-5">
          <label htmlFor="archive-name-input" className="block text-sm font-medium text-zinc-300">
            Type{' '}
            <span className="font-mono font-semibold text-white">{cabinetName}</span>{' '}
            to confirm:
          </label>
          <input
            id="archive-name-input"
            type="text"
            value={typedName}
            onChange={(e) => setTypedName(e.target.value)}
            autoFocus
            autoComplete="off"
            spellCheck={false}
            disabled={isPending}
            className="mt-2 w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2.5 text-sm text-white placeholder-zinc-600 focus:border-red-500 focus:outline-none focus:ring-1 focus:ring-red-500 disabled:opacity-50"
            placeholder={cabinetName}
          />
        </div>

        {error && (
          <p className="mt-3 text-sm text-red-400">{error}</p>
        )}

        {/* PR 5 placeholder: re-auth note */}
        <p className="mt-3 text-xs text-zinc-600">
          {/* TODO (PR 5): Re-authentication required here — passkey / password step before archive executes. */}
          Re-authentication will be required in a future update (PR 5) before archive can proceed.
        </p>

        <div className="mt-5 flex gap-3 justify-end">
          <button
            type="button"
            onClick={onClose}
            disabled={isPending}
            className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300 hover:border-zinc-600 hover:text-white transition-colors disabled:opacity-50 min-h-[44px]"
          >
            Cancel
          </button>
          <button
            type="button"
            onClick={handleArchive}
            disabled={!nameMatches || isPending}
            className="rounded-lg border border-red-700 bg-red-900/50 px-4 py-2 text-sm font-medium text-red-300 hover:bg-red-800/50 hover:text-red-200 transition-colors disabled:opacity-40 disabled:cursor-not-allowed min-h-[44px]"
          >
            {isPending ? 'Archiving…' : 'Archive Cabinet'}
          </button>
        </div>
      </div>
    </div>
  )
}
