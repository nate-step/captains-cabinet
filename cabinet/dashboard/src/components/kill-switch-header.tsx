'use client'

/**
 * KillSwitchHeader — Spec 032 §5 persistent kill switch.
 *
 * Always mounted in the layout header area (both Consumer and Advanced modes).
 * Spec §5: "Persistent header button on desktop (always-visible red '⏸ Stop All' pill)"
 * "NOT in hamburger" — this lives in the mobile top chrome too.
 *
 * Consumer mode: one-tap shows confirmation step (Spec 032 OPPORTUNITY absorbed per CRO).
 * Advanced mode: same one-tap + confirm behavior (consistent across modes).
 *
 * Fires the existing cabinet:killswitch Redis key via toggleKillSwitch server action.
 */

import { useState, useTransition } from 'react'
import { toggleKillSwitch } from '@/actions/killswitch'

interface KillSwitchHeaderProps {
  active: boolean
}

export default function KillSwitchHeader({ active }: KillSwitchHeaderProps) {
  const [confirming, setConfirming] = useState(false)
  const [isPending, startTransition] = useTransition()
  const [localActive, setLocalActive] = useState(active)

  function handleClick() {
    if (!confirming) {
      setConfirming(true)
      return
    }
    startTransition(async () => {
      await toggleKillSwitch()
      setLocalActive((prev) => !prev)
      setConfirming(false)
    })
  }

  function handleCancel() {
    setConfirming(false)
  }

  if (confirming) {
    return (
      <div className="flex items-center gap-2">
        <span className="hidden text-xs text-zinc-400 sm:block">
          {localActive ? 'Resume officers?' : 'Stop all officers?'}
        </span>
        <button
          onClick={handleCancel}
          disabled={isPending}
          className="min-h-[44px] rounded-lg border border-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-400 transition-colors hover:bg-zinc-800 disabled:opacity-50"
          aria-label="Cancel"
        >
          Cancel
        </button>
        <button
          onClick={handleClick}
          disabled={isPending}
          className={`min-h-[44px] rounded-lg px-4 py-1.5 text-xs font-bold transition-colors disabled:opacity-50 ${
            localActive
              ? 'bg-green-600 text-white hover:bg-green-500'
              : 'bg-red-600 text-white hover:bg-red-500'
          }`}
          aria-label={localActive ? 'Confirm resume' : 'Confirm stop all officers'}
        >
          {isPending
            ? '...'
            : localActive
              ? 'Confirm Resume'
              : 'Confirm Stop'}
        </button>
      </div>
    )
  }

  return (
    <button
      onClick={handleClick}
      disabled={isPending}
      className={`inline-flex min-h-[44px] items-center gap-1.5 rounded-full px-4 py-1.5 text-xs font-bold transition-colors disabled:opacity-50 ${
        localActive
          ? 'bg-green-600/20 text-green-400 hover:bg-green-600/30'
          : 'bg-red-600/20 text-red-400 hover:bg-red-600/30'
      }`}
      title={localActive ? 'Kill switch is active — officers halted. Click to resume.' : 'Stop all officers'}
      aria-label={localActive ? 'Kill switch active — click to resume officers' : 'Stop all officers'}
    >
      <span aria-hidden="true">{localActive ? '▶' : '⏸'}</span>
      <span>{localActive ? 'Resume' : 'Stop All'}</span>
    </button>
  )
}
