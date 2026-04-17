'use client'

import { EditableField } from '@/components/editable-field'
import { updateProductConfig } from '@/actions/config'
import type { GlobalConfig } from '@/lib/config'

/**
 * Settings Consumer subset (Spec 032 §5).
 *
 * Visible in Consumer mode only:
 *  - Captain name (editable)
 *  - Timezone (read-only for now; editing timezone belongs to a platform.yml
 *    server action that doesn't exist yet — filed as tech-debt below)
 *  - Officer list (read-only; editing moves to Advanced)
 *
 * The kill switch lives in the persistent header from PR 2 — not duplicated
 * here. The Consumer view deliberately omits: MCP config, hook config,
 * per-officer bot usernames, preset switching, voice, image-gen, embeddings.
 *
 * Monthly budget: also belongs in Consumer per spec, but the platform.yml
 * spending_limits block has no existing server-action writer. Adding one
 * is out of scope for PR 4 — filed as tech-debt.
 */
export default function SettingsConsumer({
  config,
  officerRoles,
  timezone,
}: {
  config: GlobalConfig
  officerRoles: string[]
  timezone: string
}) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      <div>
        <h1 className="text-2xl font-bold text-white">Settings</h1>
        <p className="mt-1 text-sm text-zinc-500">
          The essentials. Switch to Advanced for full configuration.
        </p>
      </div>

      {/* Captain */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
        <h2 className="text-lg font-semibold text-white">Captain</h2>
        <div className="mt-4 space-y-4">
          <EditableField
            label="Name"
            value={config.product.captain_name}
            onSave={(v) => updateProductConfig('captain_name', v)}
          />
          <div className="flex items-center justify-between">
            <span className="text-sm font-medium text-zinc-300">Timezone</span>
            <span className="text-sm text-zinc-500">{timezone}</span>
          </div>
        </div>
      </div>

      {/* Officers — read-only roster */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
        <h2 className="text-lg font-semibold text-white">Officers</h2>
        <p className="mt-1 text-xs text-zinc-500">
          Switch to Advanced to edit per-officer configuration.
        </p>
        <div className="mt-4 flex flex-wrap gap-2">
          {officerRoles.length === 0 ? (
            <span className="text-sm text-zinc-500">No officers configured.</span>
          ) : (
            officerRoles.map((role) => (
              <span
                key={role}
                className="rounded-full border border-zinc-700 bg-zinc-800/50 px-3 py-1 text-xs font-medium uppercase text-zinc-300"
              >
                {role}
              </span>
            ))
          )}
        </div>
      </div>

      {/* Pointer to Advanced */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900/50 text-sm text-zinc-400" style={{ padding: '16px 24px' }}>
        Need MCP, hooks, voice, embeddings, or preset switching? Switch to
        Advanced view using the toggle in the sidebar.
      </div>
    </div>
  )
}
