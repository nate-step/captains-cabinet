'use client'

/**
 * StatusBadge — Spec 037 A5
 * Renders a color-coded badge for the 5 record statuses.
 * Optionally shows an advance button (author-only) when onAdvance is provided.
 */

import { useState } from 'react'
import type { RecordStatus } from '@/lib/library'

const STATUS_STYLES: Record<RecordStatus, string> = {
  draft: 'bg-zinc-800 text-zinc-400',
  in_review: 'bg-blue-950/40 text-blue-400 border border-blue-800/50',
  approved: 'bg-green-950/40 text-green-400 border border-green-800/50',
  implemented: 'bg-indigo-950/40 text-indigo-400 border border-indigo-800/50',
  superseded: 'bg-zinc-800/60 text-zinc-600 line-through',
}

const STATUS_LABELS: Record<RecordStatus, string> = {
  draft: 'Draft',
  in_review: 'In Review',
  approved: 'Approved',
  implemented: 'Implemented',
  superseded: 'Superseded',
}

interface Props {
  status: RecordStatus
  recordId?: string
  /** If provided, clicking the badge will call this with the desired next status */
  onAdvance?: (newStatus: RecordStatus) => void
  className?: string
}

// Legal next states — MUST mirror server-side STATUS_TRANSITIONS in lib/library.ts.
// Kept as a literal (not imported) because library.ts pulls in server-only `query`.
const NEXT_STATES: Record<RecordStatus, RecordStatus[]> = {
  draft: ['in_review', 'superseded'],
  in_review: ['approved', 'superseded'],
  approved: ['implemented', 'superseded'],
  implemented: ['superseded'],
  superseded: [],
}

export default function StatusBadge({ status, recordId, onAdvance, className = '' }: Props) {
  const [advancing, setAdvancing] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const nextStates = NEXT_STATES[status]

  async function handleAdvance(newStatus: RecordStatus) {
    if (!recordId) return
    setAdvancing(true)
    setError(null)
    try {
      const res = await fetch(`/api/library/records/${recordId}/status`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ status: newStatus }),
      })
      if (!res.ok) {
        const data = (await res.json()) as { error?: string; allowed_transitions?: RecordStatus[] }
        throw new Error(data.error ?? 'Transition failed')
      }
      onAdvance?.(newStatus)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error')
    } finally {
      setAdvancing(false)
    }
  }

  return (
    <span className={`inline-flex items-center gap-2 ${className}`}>
      <span
        className={`rounded px-2 py-0.5 text-xs font-medium ${STATUS_STYLES[status]}`}
        title={`Status: ${STATUS_LABELS[status]}`}
      >
        {STATUS_LABELS[status]}
      </span>

      {/* Transition buttons — author-only, Phase B: gate behind ownership check.
          Supersede styled distinct from forward advance (destructive retire). */}
      {onAdvance && !advancing && nextStates.map((target) => (
        <button
          key={target}
          type="button"
          onClick={() => handleAdvance(target)}
          className={
            target === 'superseded'
              ? 'rounded text-xs text-zinc-500 hover:text-red-400 transition-colors'
              : 'rounded text-xs text-zinc-600 hover:text-zinc-400 transition-colors'
          }
          title={target === 'superseded' ? 'Mark superseded' : `Advance to ${STATUS_LABELS[target]}`}
        >
          → {STATUS_LABELS[target]}
        </button>
      ))}
      {advancing && (
        <span className="text-xs text-zinc-600">Updating…</span>
      )}
      {error && (
        <span className="text-xs text-red-400">{error}</span>
      )}
    </span>
  )
}
