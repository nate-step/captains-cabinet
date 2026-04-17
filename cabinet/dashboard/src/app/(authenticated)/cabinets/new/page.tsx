/**
 * Spec 034 PR 2 — /cabinets/new — Cabinet creation wizard
 *
 * Server component that loads presets, then hands off to CabinetWizard
 * (client component) for the multi-step interactive flow.
 *
 * Feature-flag gate: same pattern as /cabinets — renders "Not configured"
 * when CABINETS_PROVISIONING_ENABLED is off.
 *
 * Spec refs: §1 "New Cabinet flow", AC 2, PR 2 scope.
 */

import Link from 'next/link'
import { getDashboardConfig } from '@/lib/config'
import { getPresets } from '@/actions/cabinets'
import CabinetWizard from '@/components/cabinets/cabinet-wizard'

export const dynamic = 'force-dynamic'

export default async function NewCabinetPage() {
  // Feature-flag gate
  const dashConfig = getDashboardConfig()
  const envEnabled = process.env.CABINETS_PROVISIONING_ENABLED === 'true'
  if (!dashConfig.consumerModeEnabled && !envEnabled) {
    return (
      <div className="flex flex-col gap-6">
        <div>
          <h1 className="text-2xl font-bold text-white">New Cabinet</h1>
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

  // Load presets on the server (reads filesystem)
  const presets = await getPresets()

  return (
    <div className="flex flex-col gap-6">
      {/* Header */}
      <div className="flex items-center gap-3">
        <Link
          href="/cabinets"
          className="inline-flex items-center gap-1 text-sm text-zinc-500 hover:text-zinc-300 transition-colors"
        >
          <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M10.5 19.5L3 12m0 0l7.5-7.5M3 12h18" />
          </svg>
          Cabinets
        </Link>
        <span className="text-zinc-700">/</span>
        <h1 className="text-lg font-semibold text-white">New Cabinet</h1>
      </div>

      {/* Wizard shell */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-6 sm:p-8">
        <CabinetWizard presets={presets} />
      </div>
    </div>
  )
}
