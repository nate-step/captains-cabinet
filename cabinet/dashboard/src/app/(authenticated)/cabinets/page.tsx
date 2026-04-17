/**
 * Spec 034 PR 2 — /cabinets top-level list view (server component)
 *
 * Fetches GET /api/cabinets and renders CabinetList.
 *
 * Feature-flag gate: when CABINETS_PROVISIONING_ENABLED !== 'true' AND
 * consumer_mode_enabled is false, renders "Not configured" with no child
 * tree — fully inert. The nav link is hidden at the nav level separately
 * (NavWithMode filters /cabinets when the flag is off).
 *
 * Spec refs: §1 "/cabinets route", AC 1, PR 2 scope.
 */

import Link from 'next/link'
import { headers } from 'next/headers'
import CabinetListClient from './cabinet-list-client'
import { getDashboardConfig } from '@/lib/config'
import type { CabinetRow } from '@/components/cabinets/cabinet-list'

export const dynamic = 'force-dynamic'

async function fetchCabinets(): Promise<{ ok: boolean; cabinets?: CabinetRow[]; message?: string }> {
  const headersList = await headers()
  const host = headersList.get('host') || 'localhost:3000'
  const protocol = process.env.NODE_ENV === 'production' ? 'https' : 'http'
  const baseUrl = process.env.NEXT_PUBLIC_BASE_URL || `${protocol}://${host}`

  try {
    const res = await fetch(`${baseUrl}/api/cabinets`, {
      cache: 'no-store',
      headers: {
        cookie: headersList.get('cookie') || '',
      },
    })
    if (!res.ok) {
      const body = (await res.json().catch(() => ({}))) as { message?: string }
      return { ok: false, message: body.message || `HTTP ${res.status}` }
    }
    return (await res.json()) as { ok: boolean; cabinets: CabinetRow[] }
  } catch (err) {
    return { ok: false, message: err instanceof Error ? err.message : 'Failed to load cabinets' }
  }
}

function NotConfigured() {
  return (
    <div className="flex flex-col gap-6">
      <div>
        <h1 className="text-2xl font-bold text-white">Cabinets</h1>
        <p className="mt-1 text-sm text-zinc-500">Manage your Cabinet instances</p>
      </div>
      <div className="rounded-xl border border-zinc-800 bg-zinc-900 px-6 py-12 text-center">
        <p className="text-sm text-zinc-400">Cabinet provisioning is not configured.</p>
        <p className="mt-1 text-xs text-zinc-600">
          Set{' '}
          <span className="font-mono">CABINETS_PROVISIONING_ENABLED=true</span> to enable.
        </p>
      </div>
    </div>
  )
}

export default async function CabinetsPage() {
  // Feature-flag gate — full structural inertness when off
  const dashConfig = getDashboardConfig()
  const envEnabled = process.env.CABINETS_PROVISIONING_ENABLED === 'true'
  if (!dashConfig.consumerModeEnabled && !envEnabled) {
    return <NotConfigured />
  }

  const result = await fetchCabinets()

  return (
    <div className="flex flex-col gap-6">
      {/* Page header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Cabinets</h1>
          <p className="mt-1 text-sm text-zinc-500">
            Manage your Cabinet instances — provision, suspend, or archive.
          </p>
        </div>
        <Link
          href="/cabinets/new"
          className="inline-flex items-center gap-2 rounded-lg bg-blue-600 px-4 py-2.5 text-sm font-semibold text-white hover:bg-blue-500 transition-colors self-start sm:self-auto min-h-[44px]"
        >
          <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 4.5v15m7.5-7.5h-15" />
          </svg>
          New Cabinet
        </Link>
      </div>

      {/* Fetch error */}
      {!result.ok && (
        <div className="rounded-xl border border-red-800/50 bg-red-900/20 px-5 py-4">
          <p className="text-sm text-red-400">
            {result.message === 'Unauthorized'
              ? 'Session expired — please refresh the page.'
              : result.message || 'Failed to load cabinets.'}
          </p>
        </div>
      )}

      {/* Cabinet list — delegates interactivity to client component */}
      {result.ok && (
        <CabinetListClient initialCabinets={result.cabinets || []} />
      )}
    </div>
  )
}
