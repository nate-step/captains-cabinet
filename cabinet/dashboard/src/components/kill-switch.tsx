'use client'

import { useState, useTransition } from 'react'
import { toggleKillSwitch } from '@/actions/killswitch'

interface KillSwitchProps {
  active: boolean
}

export default function KillSwitch({ active }: KillSwitchProps) {
  const [confirming, setConfirming] = useState(false)
  const [isPending, startTransition] = useTransition()

  function handleToggle() {
    if (!confirming) {
      setConfirming(true)
      return
    }
    startTransition(async () => {
      await toggleKillSwitch()
      setConfirming(false)
    })
  }

  function handleCancel() {
    setConfirming(false)
  }

  return (
    <div
      className={`rounded-xl border p-5 ${
        active
          ? 'border-red-500/50 bg-red-900/20'
          : 'border-zinc-800 bg-zinc-900'
      }`}
    >
      <div className="flex items-center justify-between">
        <div>
          <h3 className="text-sm font-semibold text-white">Kill Switch</h3>
          <p className="mt-1 text-xs text-zinc-500">
            {active
              ? 'ACTIVE -- All officer operations are halted'
              : 'Inactive -- Officers operating normally'}
          </p>
        </div>

        <div className="flex items-center gap-2">
          {confirming && (
            <button
              onClick={handleCancel}
              disabled={isPending}
              className="rounded-lg border border-zinc-700 px-3 py-1.5 text-xs font-medium text-zinc-400 transition-colors hover:bg-zinc-800"
            >
              Cancel
            </button>
          )}
          <button
            onClick={handleToggle}
            disabled={isPending}
            className={`rounded-lg px-4 py-1.5 text-xs font-bold transition-colors disabled:opacity-50 ${
              active
                ? confirming
                  ? 'bg-green-600 text-white hover:bg-green-500'
                  : 'bg-green-600/20 text-green-500 hover:bg-green-600/30'
                : confirming
                  ? 'bg-red-600 text-white hover:bg-red-500'
                  : 'bg-red-600/20 text-red-500 hover:bg-red-600/30'
            }`}
          >
            {isPending
              ? 'Processing...'
              : confirming
                ? active
                  ? 'Confirm Deactivate'
                  : 'Confirm Activate'
                : active
                  ? 'Deactivate'
                  : 'Activate'}
          </button>
        </div>
      </div>
    </div>
  )
}
