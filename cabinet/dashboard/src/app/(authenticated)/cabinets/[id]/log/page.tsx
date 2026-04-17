/**
 * Spec 034 PR 5 — /cabinets/[id]/log — Provisioning audit log
 *
 * Server-renders the full audit event stream for a Cabinet.
 * Linked from the failed state detail view (AC 17) and from every error state.
 *
 * Shows:
 *   - Full event stream (all cabinet_provisioning_events for this cabinet)
 *   - Error events highlighted (event_type = 'error' or state_after = 'failed')
 *   - State transition timeline
 *   - Payload (secrets already redacted by audit.ts writeAuditEvent)
 *
 * Auth: session-guarded — same as all authenticated routes.
 * Access: Captain-only (inherits from authenticated layout).
 *
 * Spec refs: AC 17 (log linked from error state), §Provisioning log (worker emits events).
 */

import Link from 'next/link'
import { notFound } from 'next/navigation'
import { headers } from 'next/headers'
import { getDashboardConfig } from '@/lib/config'
import { getAuditEvents } from '@/lib/provisioning/audit'
import { query } from '@/lib/db'
import { STATE_LABELS } from '@/lib/provisioning/labels'
import type { CabinetState } from '@/lib/provisioning/state-machine'

export const dynamic = 'force-dynamic'

function formatDate(iso: string): string {
  try {
    return new Intl.DateTimeFormat('en-US', {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
    }).format(new Date(iso))
  } catch {
    return iso
  }
}

function EventTypeBadge({ type }: { type: string }) {
  const colours: Record<string, string> = {
    state_transition: 'text-blue-400 bg-blue-900/30 border-blue-800/50',
    error: 'text-red-400 bg-red-900/30 border-red-800/50',
    adopt_bot: 'text-green-400 bg-green-900/30 border-green-800/50',
    orphan_bot: 'text-orange-400 bg-orange-900/30 border-orange-800/50',
    cancel: 'text-zinc-400 bg-zinc-800/50 border-zinc-700/50',
    boot_sweep: 'text-zinc-400 bg-zinc-800/50 border-zinc-700/50',
    lock_acquired: 'text-zinc-500 bg-zinc-800/30 border-zinc-700/30',
    lock_released: 'text-zinc-500 bg-zinc-800/30 border-zinc-700/30',
  }
  const cls = colours[type] || 'text-zinc-400 bg-zinc-800/50 border-zinc-700/50'
  return (
    <span className={`inline-block rounded border px-1.5 py-0.5 text-xs font-mono ${cls}`}>
      {type}
    </span>
  )
}

export default async function CabinetLogPage({
  params,
}: {
  params: Promise<{ id: string }>
}) {
  // Feature-flag gate
  const dashConfig = getDashboardConfig()
  const envEnabled = process.env.CABINETS_PROVISIONING_ENABLED === 'true'
  if (!dashConfig.consumerModeEnabled && !envEnabled) {
    return (
      <div className="rounded-xl border border-zinc-800 bg-zinc-900 px-6 py-12 text-center">
        <p className="text-sm text-zinc-400">Cabinet provisioning is not configured.</p>
      </div>
    )
  }

  const { id } = await params

  // Fetch cabinet name for breadcrumb
  const cabRows = await query<{ name: string; state: string }>(
    'SELECT name, state FROM cabinets WHERE cabinet_id = $1',
    [id]
  ).catch(() => [])

  if (cabRows.length === 0) notFound()

  const { name, state } = cabRows[0]

  // Fetch all audit events for this cabinet
  const events = await getAuditEvents(id).catch(() => [])

  const errorCount = events.filter(
    (e) => e.event_type === 'error' || e.state_after === 'failed'
  ).length

  const cfg = STATE_LABELS[state as CabinetState] || { dot: 'bg-zinc-500', text: 'text-zinc-400', label: state }

  return (
    <div className="flex flex-col gap-6">
      {/* Breadcrumb */}
      <div className="flex items-center gap-2 text-sm">
        <Link href="/cabinets" className="text-zinc-500 hover:text-zinc-300 transition-colors">
          Cabinets
        </Link>
        <span className="text-zinc-700">/</span>
        <Link href={`/cabinets/${id}`} className="text-zinc-500 hover:text-zinc-300 transition-colors">
          {name}
        </Link>
        <span className="text-zinc-700">/</span>
        <span className="font-medium text-zinc-300">Provisioning Log</span>
      </div>

      {/* Header */}
      <div className="flex items-start justify-between flex-wrap gap-3">
        <div>
          <h1 className="text-2xl font-bold text-white">Provisioning Log</h1>
          <p className="mt-1 text-sm text-zinc-500">
            <span className={`font-mono ${cfg.text}`}>{name}</span>
            {' '}·{' '}
            {events.length} event{events.length !== 1 ? 's' : ''}
            {errorCount > 0 && (
              <span className="ml-2 text-red-400">{errorCount} error{errorCount !== 1 ? 's' : ''}</span>
            )}
          </p>
        </div>
        <Link
          href={`/cabinets/${id}`}
          className="rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-xs font-medium text-zinc-300 hover:border-zinc-600 hover:text-white transition-colors"
        >
          Back to cabinet
        </Link>
      </div>

      {/* Event list */}
      {events.length === 0 ? (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 px-6 py-12 text-center">
          <p className="text-sm text-zinc-400">No provisioning events recorded yet.</p>
        </div>
      ) : (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 divide-y divide-zinc-800">
          {events.map((evt) => {
            const isError = evt.event_type === 'error' || evt.state_after === 'failed'
            return (
              <div
                key={evt.event_id}
                className={`p-4 ${isError ? 'bg-red-900/10' : ''}`}
              >
                <div className="flex items-start gap-3 flex-wrap">
                  {/* State dot */}
                  <div className="mt-1 flex-shrink-0">
                    {evt.state_after ? (
                      <span
                        className={`h-2 w-2 rounded-full block ${
                          STATE_LABELS[evt.state_after as CabinetState]?.dot || 'bg-zinc-500'
                        }`}
                      />
                    ) : (
                      <span className="h-2 w-2 rounded-full block bg-zinc-600" />
                    )}
                  </div>

                  {/* Content */}
                  <div className="min-w-0 flex-1">
                    <div className="flex items-center gap-2 flex-wrap">
                      <EventTypeBadge type={evt.event_type} />
                      {evt.event_type === 'state_transition' && evt.state_before && evt.state_after && (
                        <span className="text-xs text-zinc-400 font-mono">
                          {evt.state_before} → {evt.state_after}
                        </span>
                      )}
                      <span className="text-xs text-zinc-600">
                        #{evt.event_id} · {formatDate(evt.timestamp)} · via {evt.entry_point}
                      </span>
                    </div>

                    {/* Error message */}
                    {evt.error && (
                      <p className="mt-1.5 text-xs text-red-400 font-mono break-all">
                        {evt.error}
                      </p>
                    )}

                    {/* Payload (already redacted by audit.ts) */}
                    {evt.payload && Object.keys(evt.payload).length > 0 && (
                      <details className="mt-1.5">
                        <summary className="text-xs text-zinc-600 cursor-pointer hover:text-zinc-400">
                          Payload
                        </summary>
                        <pre className="mt-1 text-xs text-zinc-500 overflow-x-auto whitespace-pre-wrap break-all">
                          {JSON.stringify(evt.payload, null, 2)}
                        </pre>
                      </details>
                    )}
                  </div>
                </div>
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
