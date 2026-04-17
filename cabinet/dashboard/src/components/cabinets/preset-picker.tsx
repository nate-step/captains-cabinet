'use client'

/**
 * Spec 034 PR 2 — PresetPicker
 *
 * Step 1 of the cabinet creation wizard. Displays available presets
 * as cards. Each card shows: name, description, officer count, autonomy level.
 *
 * Data: passed from parent (wizard) which calls getPresets() server action.
 * Handles empty list (no valid presets found) and single-item gracefully.
 */

import type { PresetInfo } from '@/actions/cabinets'

const AUTONOMY_LABELS: Record<string, string> = {
  execution_high:   'High autonomy',
  execution_medium: 'Balanced autonomy',
  execution_low:    'Supervised',
  consent_gated:    'Consent-gated',
}

interface PresetPickerProps {
  presets: PresetInfo[]
  selected: string | null
  onSelect: (slug: string) => void
}

export default function PresetPicker({ presets, selected, onSelect }: PresetPickerProps) {
  if (presets.length === 0) {
    return (
      <div className="rounded-xl border border-zinc-800 bg-zinc-900/50 px-6 py-10 text-center">
        <p className="text-sm text-zinc-400">No presets found.</p>
        <p className="mt-1 text-xs text-zinc-600">
          Create a preset by copying{' '}
          <span className="font-mono">presets/_template/</span> and editing{' '}
          <span className="font-mono">preset.yml</span>.
        </p>
      </div>
    )
  }

  return (
    <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
      {presets.map((preset) => {
        const isSelected = selected === preset.slug
        return (
          <button
            key={preset.slug}
            type="button"
            onClick={() => onSelect(preset.slug)}
            className={`rounded-xl border p-4 text-left transition-all focus:outline-none focus-visible:ring-2 focus-visible:ring-blue-500 min-h-[44px] ${
              isSelected
                ? 'border-blue-600 bg-blue-900/20 ring-1 ring-blue-600'
                : 'border-zinc-700 bg-zinc-800/50 hover:border-zinc-600 hover:bg-zinc-800'
            }`}
          >
            <div className="flex items-center justify-between gap-2">
              <span className="text-sm font-semibold text-white capitalize">{preset.name}</span>
              {isSelected && (
                <svg className="h-4 w-4 text-blue-400 flex-shrink-0" fill="none" viewBox="0 0 24 24" strokeWidth={2.5} stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
                </svg>
              )}
            </div>

            {preset.description && (
              <p className="mt-1.5 text-xs leading-relaxed text-zinc-400 line-clamp-3">
                {preset.description}
              </p>
            )}

            <div className="mt-3 flex items-center gap-3 flex-wrap">
              <span className="inline-flex items-center gap-1 text-xs text-zinc-500">
                <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
                  <path strokeLinecap="round" strokeLinejoin="round" d="M15 19.128a9.38 9.38 0 002.625.372 9.337 9.337 0 004.121-.952 4.125 4.125 0 00-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 018.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0111.964-3.07M12 6.375a3.375 3.375 0 11-6.75 0 3.375 3.375 0 016.75 0zm8.25 2.25a2.625 2.625 0 11-5.25 0 2.625 2.625 0 015.25 0z" />
                </svg>
                {preset.officerCount} officer{preset.officerCount !== 1 ? 's' : ''}
              </span>

              <span className="text-xs text-zinc-600">
                {AUTONOMY_LABELS[preset.autonomyLevel] || preset.autonomyLevel}
              </span>
            </div>
          </button>
        )
      })}
    </div>
  )
}
