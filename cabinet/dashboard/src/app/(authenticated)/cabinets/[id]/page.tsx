/**
 * Spec 034 PR 2 — /cabinets/[id] — Cabinet detail view
 *
 * Server component. Fetches:
 *   - GET /api/cabinets/:id — cabinet state + officer slots + retry count
 *   - GET /api/cabinets/:id/audit — last 3 audit events
 *
 * Shows: current state badge, officer slots (if any), last 3 audit events.
 * Manage/Suspend/Archive actions are surfaced via CabinetDetailClient.
 *
 * Live status: 5-second polling via client component with a "Refresh" button.
 * SSE real-time subscription is PR 5. Polling stub is explicitly flagged.
 *
 * Spec refs: §1 "Management actions", §State Machine, PR 2 scope "Live status is a placeholder",
 *            AC 4 (parts), PR plan §PR 2 scope "detail page shows current state + last 3 audit events".
 */

import Link from 'next/link'
import { headers } from 'next/headers'
import { notFound } from 'next/navigation'
import { getDashboardConfig } from '@/lib/config'
import CabinetDetailClient from './cabinet-detail-client'
import { STATE_LABELS } from '@/lib/provisioning/labels'
import { getAuditEvents } from '@/lib/provisioning/audit'
import { query } from '@/lib/db'
import type { CabinetRow } from '@/lib/provisioning/types'

export const dynamic = 'force-dynamic'

export interface AuditEvent {
  event_id: number
  cabinet_id: string
  timestamp: string
  actor: string
  entry_point: string
  event_type: string
  state_before: string | null
  state_after: string | null
  payload: Record<string, unknown>
  error: string | null
}

async function fetchCabinetDetail(
  id: string,
  cookieHeader: string,
  baseUrl: string,
): Promise<{ ok: boolean; cabinet?: CabinetRow; message?: string }> {
  try {
    const res = await fetch(`${baseUrl}/api/cabinets/${id}`, {
      cache: 'no-store',
      headers: { cookie: cookieHeader },
    })
    if (res.status === 404) return { ok: false, message: '404' }
    if (!res.ok) {
      const body = (await res.json().catch(() => ({}))) as { message?: string }
      return { ok: false, message: body.message || `HTTP ${res.status}` }
    }
    const body = (await res.json()) as { ok: boolean; cabinet: CabinetRow }
    return { ok: true, cabinet: body.cabinet }
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : 'Fetch failed' }
  }
}

async function fetchAuditEvents(id: string): Promise<AuditEvent[]> {
  // PR 5: query audit events directly (server component — no HTTP hop needed)
  try {
    const events = await getAuditEvents(id)
    // Return last 3 for the summary panel; full log is at /cabinets/:id/log
    return events.slice(-3) as AuditEvent[]
  } catch {
    return []
  }
}

function formatDate(iso: string): string {
  try {
    return new Intl.DateTimeFormat('en-US', {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
    }).format(new Date(iso))
  } catch {
    return iso
  }
}

function StateBadge({ state }: { state: string }) {
  const cfg = STATE_LABELS[state] || { dot: 'bg-zinc-500', text: 'text-zinc-400', label: state }
  return (
    <span className={`inline-flex items-center gap-1.5 font-medium ${cfg.text}`}>
      <span className={`h-2.5 w-2.5 rounded-full ${cfg.dot} flex-shrink-0`} />
      {cfg.label}
    </span>
  )
}

export default async function CabinetDetailPage({
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
  const headersList = await headers()
  const cookieHeader = headersList.get('cookie') || ''
  const host = headersList.get('host') || 'localhost:3000'
  const protocol = process.env.NODE_ENV === 'production' ? 'https' : 'http'
  const baseUrl = process.env.NEXT_PUBLIC_BASE_URL || `${protocol}://${host}`

  const [cabinetResult, auditEvents] = await Promise.all([
    fetchCabinetDetail(id, cookieHeader, baseUrl),
    fetchAuditEvents(id),
  ])

  if (!cabinetResult.ok || cabinetResult.message === '404') {
    notFound()
  }

  const cabinet = cabinetResult.cabinet!
  const officerSlots = Array.isArray(cabinet.officer_slots) ? cabinet.officer_slots : []

  return (
    <div className="flex flex-col gap-6">
      {/* Breadcrumb */}
      <div className="flex items-center gap-2">
        <Link
          href="/cabinets"
          className="text-sm text-zinc-500 hover:text-zinc-300 transition-colors"
        >
          Cabinets
        </Link>
        <span className="text-zinc-700">/</span>
        <span className="text-sm font-medium text-zinc-300">{cabinet.name}</span>
      </div>

      {/* Title row */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex items-center gap-3 flex-wrap">
            <h1 className="text-2xl font-bold text-white">{cabinet.name}</h1>
            <StateBadge state={cabinet.state} />
          </div>
          <p className="mt-1 text-sm text-zinc-500 capitalize">
            {cabinet.preset} preset &middot; Capacity:{' '}
            <span className="font-mono">{cabinet.capacity}</span> &middot; Created{' '}
            {formatDate(cabinet.created_at)}
          </p>
        </div>
      </div>

      {/* Retry circuit-breaker warning */}
      {cabinet.state === 'failed' && cabinet.retry_count >= 3 && (
        <div className="rounded-xl border border-red-800/50 bg-red-900/20 px-5 py-4">
          <p className="text-sm text-red-400 font-medium">Retry limit reached ({cabinet.retry_count}/3)</p>
          <p className="mt-1 text-xs text-zinc-400">
            Automatic retry is disabled after 3 consecutive failures. Archive this cabinet and
            create a fresh one to start over.
          </p>
        </div>
      )}

      {/* Live status — PR 5: real SSE subscription */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-sm font-semibold uppercase tracking-widest text-zinc-500">
            Live Status
          </h2>
          {cabinet.state === 'failed' && (
            <Link
              href={`/cabinets/${id}/log`}
              className="text-xs text-red-400 hover:text-red-300 underline underline-offset-2"
            >
              View provisioning log
            </Link>
          )}
        </div>
        {/* CabinetDetailClient handles polling + actions */}
        <CabinetDetailClient
          cabinet={cabinet}
          baseUrl={baseUrl}
        />
      </div>

      {/* Officer slots */}
      {officerSlots.length > 0 && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
          <h2 className="text-sm font-semibold uppercase tracking-widest text-zinc-500 mb-4">
            Officers ({officerSlots.length})
          </h2>
          <div className="space-y-2">
            {officerSlots.map((slot, i) => (
              <div key={i} className="rounded-lg border border-zinc-800 bg-zinc-800/50 px-3 py-2">
                <pre className="text-xs text-zinc-400 overflow-x-auto whitespace-pre-wrap">
                  {JSON.stringify(slot, null, 2)}
                </pre>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Audit trail (last 3 events) */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-sm font-semibold uppercase tracking-widest text-zinc-500">
            Recent Events
          </h2>
          <Link
            href={`/cabinets/${id}/log`}
            className="text-xs text-zinc-500 hover:text-zinc-300 underline underline-offset-2"
          >
            View full log
          </Link>
        </div>
        {auditEvents.length === 0 ? (
          <p className="text-xs text-zinc-600">
            No provisioning events recorded yet.
          </p>
        ) : (
          <div className="space-y-3">
            {auditEvents.map((evt) => (
              <div key={evt.event_id} className="flex items-start gap-3">
                <div className={`mt-1 h-2 w-2 rounded-full flex-shrink-0 ${
                  evt.state_after ? (STATE_LABELS[evt.state_after]?.dot || 'bg-zinc-500') : 'bg-zinc-500'
                }`} />
                <div className="min-w-0 flex-1">
                  <p className="text-xs text-zinc-300">
                    {evt.event_type === 'state_transition'
                      ? `${evt.state_before || '—'} → ${evt.state_after || '—'}`
                      : evt.event_type}
                  </p>
                  <p className="mt-0.5 text-xs text-zinc-600">
                    {formatDate(evt.timestamp)} via {evt.entry_point}
                  </p>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}
