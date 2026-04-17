'use client'

/**
 * Spec 034 PR 3 — CabinetWizard (step 4 wired)
 *
 * 5-step cabinet creation wizard:
 *   1. Preset picker
 *   2. Cabinet name (slug input)
 *   3. Capacity (inherited from preset, editable)
 *   4. Adopt-a-bot — QR + paste + forward-path (wired in PR 3)
 *   5. Consent — posts to POST /api/cabinets and redirects to /cabinets/[id]
 *
 * State: local React useState — resets when the Captain navigates away before consent
 * (unmount destroys component state naturally).
 *
 * Feature flag: Step 4 renders AdoptBotStep only when CABINETS_PROVISIONING_ENABLED
 * is active (guard is in requireProvisioningAccess on the API side; the wizard itself
 * only renders when the /cabinets page is accessible, which requires the flag).
 *
 * Spec refs: §1 "New Cabinet" flow, AC 1-3, PR 3 scope.
 */

import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import PresetPicker from './preset-picker'
import AdoptBotStep from './adopt-bot-step'
import type { PresetInfo, OfficerSlot } from '@/actions/cabinets'

// Slug validation: matches the API's SLUG_RE
const SLUG_RE = /^[a-z0-9][a-z0-9-]{1,47}$/

// Step definitions
const STEPS = [
  { id: 1, label: 'Preset' },
  { id: 2, label: 'Name' },
  { id: 3, label: 'Capacity' },
  { id: 4, label: 'Adopt bots' },
  { id: 5, label: 'Confirm' },
] as const

type Step = (typeof STEPS)[number]['id']

interface WizardState {
  preset: string | null
  name: string
  capacity: string
  /**
   * Cabinet ID returned by POST /api/cabinets (created before adopt-bots step so
   * the adopt-bot API can register tokens against an actual cabinet_id).
   *
   * PR 3 note: The wizard currently creates the cabinet at the Consent step (step 5).
   * Step 4 needs a cabinetId to call adopt-bot. Two options:
   *   A) Create cabinet early (step 3→4 transition) — requires cabinet to be in
   *      'adopting-bots' state before consent, matching the spec state machine.
   *   B) Allow adopt-bot to be called without a cabinetId — stub tokens locally,
   *      flush at consent time.
   *
   * We implement Option A: cabinet is created on step 3→4 transition (POST /api/cabinets
   * called with state 'adopting-bots'), and consent step just transitions to 'provisioning'.
   * This matches spec §3 and the state-machine table.
   *
   * If creation fails, step 4 shows AdoptBotStep with cabinetId=null and a banner
   * explaining the cabinet couldn't be created yet — the Captain can still adopt bots
   * but they'll be registered when retrying creation.
   */
  cabinetId: string | null
}

interface CabinetWizardProps {
  presets: PresetInfo[]
  /** Officers for each preset (loaded server-side and passed as prop) */
  officersByPreset: Record<string, OfficerSlot[]>
}

// ---- Step progress indicator ----

function StepIndicator({ current }: { current: Step }) {
  return (
    <nav aria-label="Progress" className="mb-8">
      <ol className="flex items-center gap-0">
        {STEPS.map((step, i) => {
          const done = step.id < current
          const active = step.id === current
          return (
            <li key={step.id} className="flex items-center flex-1">
              <div className="flex items-center gap-1.5">
                <span
                  className={`inline-flex h-6 w-6 items-center justify-center rounded-full text-xs font-semibold flex-shrink-0 ${
                    done
                      ? 'bg-blue-600 text-white'
                      : active
                      ? 'border-2 border-blue-600 text-blue-400'
                      : 'border border-zinc-700 text-zinc-600'
                  }`}
                >
                  {done ? (
                    <svg className="h-3.5 w-3.5" fill="none" viewBox="0 0 24 24" strokeWidth={2.5} stroke="currentColor">
                      <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
                    </svg>
                  ) : (
                    step.id
                  )}
                </span>
                <span className={`hidden sm:block text-xs ${active ? 'text-white font-medium' : done ? 'text-zinc-400' : 'text-zinc-600'}`}>
                  {step.label}
                </span>
              </div>
              {i < STEPS.length - 1 && (
                <div className={`flex-1 h-px mx-2 ${done ? 'bg-blue-600' : 'bg-zinc-800'}`} />
              )}
            </li>
          )
        })}
      </ol>
    </nav>
  )
}

// ---- Individual step components ----

function Step1Preset({
  presets,
  state,
  setState,
  onNext,
}: {
  presets: PresetInfo[]
  state: WizardState
  setState: (s: WizardState) => void
  onNext: () => void
}) {
  return (
    <div>
      <h2 className="text-lg font-semibold text-white mb-1">Choose a preset</h2>
      <p className="text-sm text-zinc-400 mb-6">
        Presets define the officers, terminology, and autonomy level for your new cabinet.
      </p>

      <PresetPicker
        presets={presets}
        selected={state.preset}
        onSelect={(slug) => {
          // Default capacity = preset slug
          setState({ ...state, preset: slug, capacity: state.capacity || slug })
        }}
      />

      <div className="mt-6 flex justify-end">
        <button
          type="button"
          disabled={!state.preset}
          onClick={onNext}
          className="rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed transition-colors min-h-[44px]"
        >
          Next: Name →
        </button>
      </div>
    </div>
  )
}

function Step2Name({
  state,
  setState,
  onNext,
  onBack,
}: {
  state: WizardState
  setState: (s: WizardState) => void
  onNext: () => void
  onBack: () => void
}) {
  const isValid = SLUG_RE.test(state.name)
  const showError = state.name.length > 0 && !isValid

  return (
    <div>
      <h2 className="text-lg font-semibold text-white mb-1">Name your cabinet</h2>
      <p className="text-sm text-zinc-400 mb-6">
        Pick a short slug — lowercase letters, numbers, and hyphens. This identifies your cabinet
        across the system.
      </p>

      <label htmlFor="cabinet-name" className="block text-sm font-medium text-zinc-300 mb-1.5">
        Cabinet name
      </label>
      <input
        id="cabinet-name"
        type="text"
        value={state.name}
        onChange={(e) => setState({ ...state, name: e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, '') })}
        autoFocus
        autoComplete="off"
        spellCheck={false}
        placeholder="e.g. personal, work-2, team-ops"
        className={`w-full rounded-lg border px-3 py-2.5 text-sm text-white placeholder-zinc-600 bg-zinc-800 focus:outline-none focus:ring-1 transition-colors ${
          showError
            ? 'border-red-500 focus:border-red-500 focus:ring-red-500'
            : 'border-zinc-700 focus:border-blue-500 focus:ring-blue-500'
        }`}
      />
      {showError && (
        <p className="mt-1.5 text-xs text-red-400">
          Must be lowercase alphanumeric + hyphens, 2–48 characters, starting with a letter or digit.
        </p>
      )}

      <div className="mt-6 flex justify-between">
        <button
          type="button"
          onClick={onBack}
          className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300 hover:border-zinc-600 hover:text-white transition-colors min-h-[44px]"
        >
          ← Back
        </button>
        <button
          type="button"
          disabled={!isValid}
          onClick={onNext}
          className="rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed transition-colors min-h-[44px]"
        >
          Next: Capacity →
        </button>
      </div>
    </div>
  )
}

function Step3Capacity({
  presets,
  state,
  setState,
  onNext,
  onBack,
}: {
  presets: PresetInfo[]
  state: WizardState
  setState: (s: WizardState) => void
  onNext: () => void
  onBack: () => void
}) {
  const selectedPreset = presets.find((p) => p.slug === state.preset)
  const isValid = state.capacity.length > 0

  return (
    <div>
      <h2 className="text-lg font-semibold text-white mb-1">Set capacity</h2>
      <p className="text-sm text-zinc-400 mb-6">
        Capacity controls which data rows are allocated to this cabinet. Defaults to the preset
        slug — adjust only if you have a specific routing requirement.
      </p>

      <label htmlFor="cabinet-capacity" className="block text-sm font-medium text-zinc-300 mb-1.5">
        Capacity identifier
      </label>
      <input
        id="cabinet-capacity"
        type="text"
        value={state.capacity}
        onChange={(e) => setState({ ...state, capacity: e.target.value.trim() })}
        autoComplete="off"
        spellCheck={false}
        className="w-full rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-2.5 text-sm text-white placeholder-zinc-600 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
      />

      {selectedPreset && (
        <p className="mt-2 text-xs text-zinc-500">
          Default for{' '}
          <span className="capitalize font-medium text-zinc-400">{selectedPreset.name}</span> preset:{' '}
          <span className="font-mono">{selectedPreset.slug}</span>
        </p>
      )}

      <div className="mt-6 flex justify-between">
        <button
          type="button"
          onClick={onBack}
          className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300 hover:border-zinc-600 hover:text-white transition-colors min-h-[44px]"
        >
          ← Back
        </button>
        <button
          type="button"
          disabled={!isValid}
          onClick={onNext}
          className="rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed transition-colors min-h-[44px]"
        >
          Next: Adopt bots →
        </button>
      </div>
    </div>
  )
}

// Step 4 is handled by the imported AdoptBotStep component (PR 3).
// See adopt-bot-step.tsx for implementation.

function Step5Consent({
  presets,
  state,
  onBack,
  onSubmit,
  isSubmitting,
  submitError,
}: {
  presets: PresetInfo[]
  state: WizardState
  onBack: () => void
  onSubmit: () => void
  isSubmitting: boolean
  submitError: string | null
}) {
  const selectedPreset = presets.find((p) => p.slug === state.preset)

  return (
    <div>
      <h2 className="text-lg font-semibold text-white mb-1">Confirm and create</h2>
      <p className="text-sm text-zinc-400 mb-6">
        Review your configuration before creating the cabinet.
      </p>

      <div className="rounded-xl border border-zinc-700 bg-zinc-800/50 p-5 space-y-3">
        <div className="flex justify-between text-sm">
          <span className="text-zinc-500">Cabinet name</span>
          <span className="font-mono font-medium text-white">{state.name}</span>
        </div>
        <div className="border-t border-zinc-700/50" />
        <div className="flex justify-between text-sm">
          <span className="text-zinc-500">Preset</span>
          <span className="font-medium text-white capitalize">{selectedPreset?.name || state.preset}</span>
        </div>
        <div className="border-t border-zinc-700/50" />
        <div className="flex justify-between text-sm">
          <span className="text-zinc-500">Officers</span>
          <span className="text-zinc-300">{selectedPreset ? `${selectedPreset.officerCount} officers` : '—'}</span>
        </div>
        <div className="border-t border-zinc-700/50" />
        <div className="flex justify-between text-sm">
          <span className="text-zinc-500">Capacity</span>
          <span className="font-mono text-zinc-300">{state.capacity}</span>
        </div>
      </div>

      <div className="mt-4 rounded-xl border border-blue-900/50 bg-blue-900/10 px-4 py-3">
        <p className="text-xs text-blue-300 leading-relaxed">
          Creating{' '}
          <span className="font-semibold font-mono">{state.name}</span> will provision officer
          containers, run the capacity migration, and wire peer connections. This typically takes
          under 3 minutes.
        </p>
      </div>

      {submitError && (
        <div className="mt-3 rounded-lg border border-red-800/50 bg-red-900/20 px-3 py-2">
          <p className="text-sm text-red-400">{submitError}</p>
        </div>
      )}

      <div className="mt-6 flex justify-between">
        <button
          type="button"
          onClick={onBack}
          disabled={isSubmitting}
          className="rounded-lg border border-zinc-700 bg-zinc-800 px-4 py-2 text-sm font-medium text-zinc-300 hover:border-zinc-600 hover:text-white transition-colors disabled:opacity-50 min-h-[44px]"
        >
          ← Back
        </button>
        <button
          type="button"
          onClick={onSubmit}
          disabled={isSubmitting}
          className="rounded-lg bg-blue-600 px-6 py-2.5 text-sm font-semibold text-white hover:bg-blue-500 disabled:opacity-50 disabled:cursor-not-allowed transition-colors min-h-[44px]"
        >
          {isSubmitting ? 'Creating…' : `Create Cabinet`}
        </button>
      </div>
    </div>
  )
}

// ---- Main wizard ----

export default function CabinetWizard({ presets, officersByPreset }: CabinetWizardProps) {
  const router = useRouter()
  const [step, setStep] = useState<Step>(1)
  const [state, setState] = useState<WizardState>({
    preset: null,
    name: '',
    capacity: '',
    cabinetId: null,
  })
  const [isSubmitting, startTransition] = useTransition()
  const [submitError, setSubmitError] = useState<string | null>(null)
  const [allBotsAdopted, setAllBotsAdopted] = useState(false)
  const [step4Error, setStep4Error] = useState<string | null>(null)

  function back() {
    setStep((s) => Math.max(1, s - 1) as Step)
  }

  /**
   * Advance from step 3 → step 4.
   * Creates the cabinet immediately (state: adopting-bots) so the adopt-bot
   * API has a cabinet_id to work against. This matches the spec state machine.
   */
  function advanceToStep4() {
    setStep4Error(null)
    startTransition(async () => {
      try {
        const res = await fetch('/api/cabinets', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            name: state.name,
            preset: state.preset,
            capacity: state.capacity,
          }),
        })
        const body = (await res.json()) as { ok: boolean; cabinet_id?: string; message?: string }
        if (!body.ok) {
          // Non-fatal: advance to step 4 with cabinetId=null; AdoptBotStep shows banner
          setStep4Error(body.message || `Error ${res.status}`)
          setState((s) => ({ ...s, cabinetId: null }))
        } else {
          setState((s) => ({ ...s, cabinetId: body.cabinet_id ?? null }))
        }
      } catch {
        // Non-fatal: continue to step 4 without cabinetId
        setState((s) => ({ ...s, cabinetId: null }))
      }
      setStep(4)
    })
  }

  /**
   * Advance from step 4 → step 5 (all bots adopted).
   * Called by AdoptBotStep when all slots are adopted.
   */
  function handleAllBotsAdopted() {
    setAllBotsAdopted(true)
    setStep(5)
  }

  /**
   * Consent step submit — cabinet already created in step 3→4 transition.
   * If cabinetId exists, just redirect to the cabinet detail page.
   * The provisioning worker transitions state from adopting-bots → provisioning.
   */
  function handleSubmit() {
    setSubmitError(null)
    startTransition(async () => {
      try {
        if (state.cabinetId) {
          // Cabinet already created — redirect to detail page
          router.push(`/cabinets/${state.cabinetId}`)
          return
        }
        // Fallback: cabinet creation failed in step 3→4; retry here
        const res = await fetch('/api/cabinets', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            name: state.name,
            preset: state.preset,
            capacity: state.capacity,
          }),
        })
        const body = (await res.json()) as { ok: boolean; cabinet_id?: string; message?: string }
        if (!body.ok) {
          setSubmitError(body.message || `Error ${res.status}`)
          return
        }
        router.push(`/cabinets/${body.cabinet_id}`)
      } catch (err) {
        setSubmitError(err instanceof Error ? err.message : 'Network error')
      }
    })
  }

  // Officers for the selected preset
  const officers = state.preset ? (officersByPreset[state.preset] ?? []) : []

  return (
    <div>
      <StepIndicator current={step} />

      {step === 1 && (
        <Step1Preset presets={presets} state={state} setState={setState} onNext={() => setStep(2)} />
      )}
      {step === 2 && (
        <Step2Name state={state} setState={setState} onNext={() => setStep(3)} onBack={back} />
      )}
      {step === 3 && (
        <Step3Capacity
          presets={presets}
          state={state}
          setState={setState}
          onNext={advanceToStep4}
          onBack={back}
        />
      )}
      {step === 4 && (
        <>
          {step4Error && (
            <div className="mb-4 rounded-lg border border-amber-700/50 bg-amber-900/10 px-3 py-2">
              <p className="text-xs text-amber-400">
                Could not create the cabinet yet ({step4Error}). You can still adopt bots — tokens
                will be registered once the cabinet is created.
              </p>
            </div>
          )}
          <AdoptBotStep
            cabinetId={state.cabinetId}
            cabinetSlug={state.name}
            officers={officers.length > 0 ? officers : [{ role: state.preset || 'officer', title: 'Officer' }]}
            onAllAdopted={handleAllBotsAdopted}
            onBack={back}
          />
        </>
      )}
      {step === 5 && (
        <Step5Consent
          presets={presets}
          state={state}
          onBack={back}
          onSubmit={handleSubmit}
          isSubmitting={isSubmitting}
          submitError={submitError}
        />
      )}
    </div>
  )
}
