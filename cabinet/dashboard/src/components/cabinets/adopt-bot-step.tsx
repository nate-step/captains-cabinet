'use client'

/**
 * Spec 034 PR 3 — AdoptBotStep
 *
 * Step 4 of the CabinetWizard. Renders N officer slots (one per preset officer),
 * each with:
 *   - A BotFather deep-link (tappable on mobile)
 *   - An inline SVG QR code (scannable on desktop — tertiary UX per spec §3)
 *   - A token paste input (PRIMARY UX per spec §3)
 *   - Status badge: pending / adopted / failed
 *   - Confirmation prompt before registering ("...XYZ — adopt as {officer}?")
 *
 * Two registration paths:
 *   1. Paste path: Captain pastes token → client-side regex → confirmation → POST adopt-bot
 *   2. Forward path: Manager bot receives forwarded message → calls adopt-bot-from-forward →
 *      returns last_four → dashboard shows confirmation → Captain confirms → adopt-bot called
 *      (PR 4 wires the manager bot; this component handles the dashboard polling side)
 *
 * Dashboard polls GET /api/cabinets/:id every 3s for up to 2 min while on step 4.
 * When all slots show adopted, "Next" button enables.
 *
 * Feature flag: This component is only rendered when CABINETS_PROVISIONING_ENABLED is
 * active (the wizard step is gated in cabinet-wizard.tsx).
 *
 * Spec refs: §3 "Adopt-a-bot flow", AC 3, PR 3 scope.
 */

import { useState, useEffect, useRef, useCallback } from 'react'
import { generateBotFatherLink, tokenLastFour, isValidToken } from '@/lib/botfather'
import { generateQrSvg } from '@/lib/qr-inline'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface OfficerSlotDef {
  /** Officer role slug e.g. 'cos', 'cto' */
  role: string
  /** Human-readable title e.g. 'Chief of Staff' */
  title: string
}

type SlotStatus = 'pending' | 'confirming' | 'adopting' | 'adopted' | 'failed'

interface SlotState {
  role: string
  title: string
  status: SlotStatus
  errorMessage: string | null
  /** Pending token value in the paste input (not yet confirmed) */
  pendingToken: string
  /** Last 4 chars of the pending token — shown in confirmation prompt */
  pendingLastFour: string
  /** Whether token input is visible */
  showInput: boolean
}

interface AdoptBotStepProps {
  /** Cabinet ID (from POST /api/cabinets response — may be null if wizard hasn't created cabinet yet) */
  cabinetId: string | null
  /** Cabinet name slug (for BotFather deep-link generation) */
  cabinetSlug: string
  /** Officer slots from the preset */
  officers: OfficerSlotDef[]
  /** Called when all slots are adopted — enables "Next" in wizard */
  onAllAdopted: () => void
  onBack: () => void
}

// ---------------------------------------------------------------------------
// Polling interval constants
// ---------------------------------------------------------------------------

const POLL_INTERVAL_MS = 3000
const POLL_DURATION_MS = 2 * 60 * 1000 // 2 minutes

// ---------------------------------------------------------------------------
// SlotCard — individual officer slot UI
// ---------------------------------------------------------------------------

interface SlotCardProps {
  slot: SlotState
  cabinetSlug: string
  cabinetId: string | null
  onTokenInput: (role: string, value: string) => void
  onConfirm: (role: string) => void
  onCancel: (role: string) => void
  onToggleInput: (role: string) => void
}

function SlotCard({
  slot,
  cabinetSlug,
  cabinetId,
  onTokenInput,
  onConfirm,
  onCancel,
  onToggleInput,
}: SlotCardProps) {
  const deepLink = generateBotFatherLink(cabinetSlug, slot.role)
  const qrSvg = generateQrSvg(deepLink, 128)
  const isAdopted = slot.status === 'adopted'
  const isFailed = slot.status === 'failed'
  const isConfirming = slot.status === 'confirming'
  const isAdopting = slot.status === 'adopting'
  const isPending = slot.status === 'pending'

  const tokenValid = isValidToken(slot.pendingToken)

  return (
    <div
      className={`rounded-xl border p-4 transition-colors ${
        isAdopted
          ? 'border-emerald-700/50 bg-emerald-900/10'
          : isFailed
          ? 'border-red-700/50 bg-red-900/10'
          : 'border-zinc-700 bg-zinc-800/50'
      }`}
    >
      {/* Header */}
      <div className="flex items-center justify-between mb-3">
        <div className="flex items-center gap-2.5">
          {/* Status indicator */}
          <span
            className={`inline-flex h-5 w-5 items-center justify-center rounded-full flex-shrink-0 ${
              isAdopted
                ? 'bg-emerald-600'
                : isFailed
                ? 'bg-red-600'
                : isAdopting
                ? 'bg-blue-600 animate-pulse'
                : 'border border-zinc-600 bg-zinc-700'
            }`}
          >
            {isAdopted && (
              <svg className="h-3 w-3 text-white" fill="none" viewBox="0 0 24 24" strokeWidth={3} stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" d="M4.5 12.75l6 6 9-13.5" />
              </svg>
            )}
            {isFailed && (
              <svg className="h-3 w-3 text-white" fill="none" viewBox="0 0 24 24" strokeWidth={3} stroke="currentColor">
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            )}
          </span>
          <div>
            <p className="text-sm font-medium text-white">{slot.title}</p>
            <p className="text-xs text-zinc-500 font-mono">{slot.role}</p>
          </div>
        </div>

        {/* Status badge */}
        <span
          className={`text-xs font-medium px-2 py-0.5 rounded-full ${
            isAdopted
              ? 'bg-emerald-900/50 text-emerald-400'
              : isFailed
              ? 'bg-red-900/50 text-red-400'
              : isAdopting
              ? 'bg-blue-900/50 text-blue-400'
              : isConfirming
              ? 'bg-amber-900/50 text-amber-400'
              : 'bg-zinc-700 text-zinc-400'
          }`}
        >
          {isAdopted ? 'Adopted' : isFailed ? 'Failed' : isAdopting ? 'Saving…' : isConfirming ? 'Confirm' : 'Pending'}
        </span>
      </div>

      {/* Adopted — done state */}
      {isAdopted && (
        <p className="text-xs text-emerald-400/80">Bot registered successfully.</p>
      )}

      {/* Failed state */}
      {isFailed && (
        <div className="mt-1 mb-2">
          <p className="text-xs text-red-400">{slot.errorMessage || 'Failed to register bot.'}</p>
          <button
            onClick={() => onToggleInput(slot.role)}
            className="mt-2 text-xs text-zinc-400 underline hover:text-white"
          >
            Try again
          </button>
        </div>
      )}

      {/* Pending / active state — show QR + link + paste input */}
      {(isPending || isFailed) && (
        <div className="mt-2 space-y-3">
          {/* BotFather link + QR */}
          <div className="flex gap-4 items-start">
            {/* QR code (desktop) */}
            <div
              className="flex-shrink-0 rounded-lg overflow-hidden border border-zinc-600 bg-white p-1"
              aria-label={`QR code for ${slot.title} bot — scan to open BotFather`}
              dangerouslySetInnerHTML={{ __html: qrSvg }}
            />
            {/* Link + instructions */}
            <div className="flex-1 min-w-0">
              <p className="text-xs text-zinc-400 mb-1.5">
                Tap to open BotFather and create a bot for{' '}
                <span className="font-medium text-white">{slot.title}</span>.
              </p>
              <a
                href={deepLink}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1.5 text-xs font-medium text-blue-400 hover:text-blue-300 underline underline-offset-2 transition-colors"
              >
                <svg className="h-3.5 w-3.5 flex-shrink-0" fill="currentColor" viewBox="0 0 24 24">
                  <path d="M12 0C5.373 0 0 5.373 0 12s5.373 12 12 12 12-5.373 12-12S18.627 0 12 0zm5.562 8.248l-2.032 9.571c-.144.658-.537.818-1.084.508l-3-2.21-1.447 1.394c-.16.16-.295.295-.605.295l.213-3.053 5.56-5.023c.242-.213-.054-.333-.373-.12L6.26 14.74l-2.952-.924c-.642-.202-.654-.642.136-.951l11.527-4.444c.535-.194 1.003.13.591 1.827z"/>
                </svg>
                Open BotFather
              </a>
              <p className="mt-2 text-xs text-zinc-600">
                After creating the bot, paste the token below.
              </p>
            </div>
          </div>

          {/* Token paste input */}
          <div>
            <label
              htmlFor={`token-${slot.role}`}
              className="block text-xs font-medium text-zinc-400 mb-1"
            >
              Paste BotFather token
            </label>
            <input
              id={`token-${slot.role}`}
              type="password"
              value={slot.pendingToken}
              onChange={(e) => onTokenInput(slot.role, e.target.value)}
              placeholder="1234567890:ABCDEFabcdef..."
              autoComplete="off"
              spellCheck={false}
              disabled={isAdopting}
              className={`w-full rounded-lg border px-3 py-2 text-sm font-mono text-white placeholder-zinc-600 bg-zinc-900 focus:outline-none focus:ring-1 transition-colors ${
                slot.pendingToken && !tokenValid
                  ? 'border-red-600 focus:border-red-500 focus:ring-red-500'
                  : 'border-zinc-600 focus:border-blue-500 focus:ring-blue-500'
              }`}
            />
            {slot.pendingToken && !tokenValid && (
              <p className="mt-1 text-xs text-red-400">
                Invalid token format. Expected: {'{8-12 digits}:{35 chars}'}
              </p>
            )}

            {/* Confirm / adopt button */}
            {tokenValid && !isConfirming && !isAdopting && (
              <button
                onClick={() => onConfirm(slot.role)}
                className="mt-2 w-full rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-500 transition-colors min-h-[40px]"
              >
                Adopt as {slot.title} →
              </button>
            )}
          </div>

          {/* Confirmation prompt — shown when tokenValid */}
          {isConfirming && (
            <div className="rounded-lg border border-amber-700/50 bg-amber-900/10 p-3">
              <p className="text-sm text-amber-300 font-medium mb-1">
                Confirm adoption
              </p>
              <p className="text-xs text-amber-300/70 mb-3">
                Token ending <span className="font-mono font-bold">...{slot.pendingLastFour}</span> — adopt as{' '}
                <span className="font-medium">{slot.title}</span>?
              </p>
              <div className="flex gap-2">
                <button
                  onClick={() => onConfirm(slot.role)}
                  className="flex-1 rounded-lg bg-amber-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-amber-500 transition-colors min-h-[36px]"
                >
                  Yes, adopt
                </button>
                <button
                  onClick={() => onCancel(slot.role)}
                  className="flex-1 rounded-lg border border-zinc-600 px-3 py-1.5 text-xs font-medium text-zinc-300 hover:border-zinc-500 hover:text-white transition-colors min-h-[36px]"
                >
                  Cancel
                </button>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// AdoptBotStep — main component
// ---------------------------------------------------------------------------

export default function AdoptBotStep({
  cabinetId,
  cabinetSlug,
  officers,
  onAllAdopted,
  onBack,
}: AdoptBotStepProps) {
  const [slots, setSlots] = useState<SlotState[]>(() =>
    officers.map((o) => ({
      role: o.role,
      title: o.title,
      status: 'pending' as SlotStatus,
      errorMessage: null,
      pendingToken: '',
      pendingLastFour: '',
      showInput: true,
    }))
  )

  // Track polling state
  const pollTimerRef = useRef<ReturnType<typeof setInterval> | null>(null)
  const pollStartRef = useRef<number>(Date.now())
  const allAdoptedCalledRef = useRef(false)

  // Update slot by role
  const updateSlot = useCallback((role: string, update: Partial<SlotState>) => {
    setSlots((prev) =>
      prev.map((s) => (s.role === role ? { ...s, ...update } : s))
    )
  }, [])

  // Check if all slots are adopted
  const allAdopted = slots.every((s) => s.status === 'adopted')

  // Fire onAllAdopted once when all adopted
  useEffect(() => {
    if (allAdopted && !allAdoptedCalledRef.current) {
      allAdoptedCalledRef.current = true
      onAllAdopted()
    }
  }, [allAdopted, onAllAdopted])

  // Poll GET /api/cabinets/:id every 3s to detect forward-path adoptions
  useEffect(() => {
    if (!cabinetId || allAdopted) return

    const poll = async () => {
      // Stop polling after 2 min
      if (Date.now() - pollStartRef.current > POLL_DURATION_MS) {
        if (pollTimerRef.current) clearInterval(pollTimerRef.current)
        return
      }
      try {
        const res = await fetch(`/api/cabinets/${cabinetId}`)
        if (!res.ok) return
        const body = (await res.json()) as {
          ok: boolean
          cabinet: {
            officer_slots: Array<{ role: string; bot_token: string | null; adopted_at: string | null }>
          }
        }
        if (!body.ok || !body.cabinet?.officer_slots) return

        const remoteSlots = Array.isArray(body.cabinet.officer_slots)
          ? body.cabinet.officer_slots
          : []

        setSlots((prev) =>
          prev.map((s) => {
            const remote = remoteSlots.find((r) => r.role === s.role)
            if (remote?.bot_token && s.status !== 'adopted') {
              return { ...s, status: 'adopted', errorMessage: null }
            }
            return s
          })
        )
      } catch {
        // Polling errors are non-fatal — just wait for next interval
      }
    }

    pollTimerRef.current = setInterval(poll, POLL_INTERVAL_MS)
    // Initial poll immediately
    poll()

    return () => {
      if (pollTimerRef.current) clearInterval(pollTimerRef.current)
    }
  }, [cabinetId, allAdopted])

  // ---- Token input handler ----
  const handleTokenInput = useCallback((role: string, value: string) => {
    const trimmed = value.trim()
    const lastFour = trimmed ? tokenLastFour(trimmed) : ''
    updateSlot(role, {
      pendingToken: trimmed,
      pendingLastFour: lastFour,
      // Reset to pending if they're editing after a failed attempt
      status: 'pending',
      errorMessage: null,
    })
  }, [updateSlot])

  // ---- API call: adopt bot (must be defined before handleConfirm) ----
  const adoptBot = useCallback(async (role: string, token: string) => {
    if (!cabinetId) {
      updateSlot(role, {
        status: 'failed',
        errorMessage: 'Cabinet not yet created — complete previous steps first.',
      })
      return
    }

    try {
      const res = await fetch(`/api/cabinets/${cabinetId}/adopt-bot`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ officer: role, bot_token: token }),
      })
      const body = (await res.json()) as {
        ok: boolean
        message?: string
        orphan_warning?: string
      }

      if (!body.ok) {
        updateSlot(role, {
          status: 'failed',
          errorMessage: body.message || `Error ${res.status}`,
        })
        return
      }

      updateSlot(role, { status: 'adopted', errorMessage: null, pendingToken: '' })

      // Surface orphan warning (old bot replaced) — non-blocking
      if (body.orphan_warning) {
        console.warn(`[adopt-bot] ${body.orphan_warning}`)
        // TODO PR 4: surface this as an inline banner per spec §3 latest-wins semantics
      }
    } catch (err) {
      updateSlot(role, {
        status: 'failed',
        errorMessage: err instanceof Error ? err.message : 'Network error — try again.',
      })
    }
  }, [cabinetId, updateSlot])

  // ---- Confirm handler — two-phase: first call shows confirmation prompt, second fires API ----
  const handleConfirm = useCallback((role: string) => {
    setSlots((prev) => {
      const slot = prev.find((s) => s.role === role)
      if (!slot) return prev

      if (slot.status !== 'confirming') {
        // Phase 1: show confirmation prompt
        return prev.map((s) =>
          s.role === role
            ? { ...s, status: 'confirming' as SlotStatus, pendingLastFour: tokenLastFour(s.pendingToken) }
            : s
        )
      }

      // Phase 2: Captain confirmed — kick off API call, mark as adopting
      const tokenToAdopt = slot.pendingToken
      // Use setTimeout to schedule async work outside of setState to avoid React warning
      setTimeout(() => void adoptBot(role, tokenToAdopt), 0)
      return prev.map((s) =>
        s.role === role ? { ...s, status: 'adopting' as SlotStatus } : s
      )
    })
  }, [adoptBot])

  // ---- Cancel confirmation ----
  const handleCancel = useCallback((role: string) => {
    updateSlot(role, { status: 'pending' })
  }, [updateSlot])

  // ---- Toggle input visibility ----
  const handleToggleInput = useCallback((role: string) => {
    updateSlot(role, { status: 'pending', errorMessage: null })
  }, [updateSlot])

  // ---- Derived state ----
  const adoptedCount = slots.filter((s) => s.status === 'adopted').length
  const total = slots.length

  return (
    <div>
      <h2 className="text-lg font-semibold text-white mb-1">Adopt Telegram bots</h2>
      <p className="text-sm text-zinc-400 mb-1">
        Each officer needs its own Telegram bot. Click <strong className="text-zinc-300">Open BotFather</strong> for each slot,
        create a bot, then paste the token here.
      </p>
      <p className="text-xs text-zinc-500 mb-5">
        {adoptedCount} of {total} adopted.
        {!cabinetId && (
          <span className="ml-1 text-amber-500">Cabinet not yet created — tokens will be registered when the cabinet exists.</span>
        )}
      </p>

      {/* Slot cards */}
      <div className="space-y-3">
        {slots.map((slot) => (
          <SlotCard
            key={slot.role}
            slot={slot}
            cabinetSlug={cabinetSlug}
            cabinetId={cabinetId}
            onTokenInput={handleTokenInput}
            onConfirm={handleConfirm}
            onCancel={handleCancel}
            onToggleInput={handleToggleInput}
          />
        ))}
      </div>

      {/* Forward path hint */}
      <div className="mt-4 rounded-lg border border-zinc-700/50 bg-zinc-800/30 px-3 py-2.5">
        <p className="text-xs text-zinc-500 leading-relaxed">
          <span className="font-medium text-zinc-400">Prefer mobile?</span>{' '}
          Forward the message BotFather sends you (the one with the token) to your Cabinet manager
          bot. It will register the token automatically and this page will update.
        </p>
      </div>

      {/* Navigation */}
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
          disabled={!allAdopted}
          onClick={onAllAdopted}
          className="rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-medium text-white hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed transition-colors min-h-[44px]"
        >
          {allAdopted ? 'Next: Confirm →' : `Waiting for ${total - adoptedCount} more…`}
        </button>
      </div>
    </div>
  )
}
