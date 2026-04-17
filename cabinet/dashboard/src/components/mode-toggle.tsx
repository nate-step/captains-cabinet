'use client'

import { useEffect } from 'react'
import { useDashboardMode } from '@/hooks/use-dashboard-mode'

/**
 * Dashboard mode toggle — Spec 032 v3.
 *
 * Always visible (CRO pressure-test: Home Assistant's toggle was buried in
 * profile settings and 14% of users never found it). Labeled with the current
 * state so the toggle also functions as the second visual indicator for mode
 * (CRO: NN/G research requires at least two indicators for mode errors).
 *
 * Keyboard shortcut Cmd/Ctrl+Shift+A flips the mode globally. Ignored while
 * the focused element is an editable input to avoid eating user keystrokes.
 */
export default function ModeToggle() {
  const [mode, setMode] = useDashboardMode()

  useEffect(() => {
    function handleKeydown(e: KeyboardEvent) {
      // e.code is layout-stable (physical key); e.key covers the common
      // QWERTY case. Checking both matches Dvorak/Colemak remappers too.
      const isA = e.code === 'KeyA' || e.key.toLowerCase() === 'a'
      const isToggleShortcut = (e.metaKey || e.ctrlKey) && e.shiftKey && isA
      if (!isToggleShortcut) return
      // Skip all editable surfaces: input, textarea, select, contenteditable.
      const target = e.target as HTMLElement | null
      const tag = target?.tagName
      if (target && (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || target.isContentEditable)) {
        return
      }
      e.preventDefault()
      setMode(mode === 'consumer' ? 'advanced' : 'consumer')
    }
    window.addEventListener('keydown', handleKeydown)
    return () => window.removeEventListener('keydown', handleKeydown)
  }, [mode, setMode])

  const nextLabel = mode === 'consumer' ? 'Advanced view →' : '← Consumer view'
  const currentLabel = mode === 'consumer' ? 'Consumer view' : 'Advanced view'

  return (
    <button
      type="button"
      onClick={() => setMode(mode === 'consumer' ? 'advanced' : 'consumer')}
      className="flex w-full items-center justify-between rounded-lg border border-zinc-800 bg-zinc-900/50 px-3 py-2 text-left text-sm font-medium text-zinc-300 transition-colors hover:border-zinc-700 hover:bg-zinc-800/50"
      title="Switch mode (Cmd/Ctrl+Shift+A)"
      aria-label={`Currently ${currentLabel}. Click to switch.`}
    >
      <span className="truncate">{currentLabel}</span>
      <span className="ml-3 shrink-0 text-xs text-zinc-500">{nextLabel}</span>
    </button>
  )
}
