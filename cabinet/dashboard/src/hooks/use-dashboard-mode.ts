'use client'

import { useCallback, useEffect, useState } from 'react'

/**
 * Dashboard mode — Spec 032.
 *
 * Consumer is the default for non-developer founders (4 cards, natural language).
 * Advanced is the current admin dashboard (raw counters, full nav).
 *
 * Permanence rule (CRO v3): once a user toggles to Advanced, they stay there
 * until they manually toggle back. No re-defaulting on upgrades, cache clear,
 * version bump, or session boundary. We NEVER overwrite the stored value to
 * 'consumer' programmatically — only user action changes it.
 *
 * Home Assistant shipped a similar toggle and ~86% of users ended up in
 * Advanced mode permanently. We document that in the spec; the permanence
 * rule intentionally preserves that outcome when the user wants it.
 */

export type DashboardMode = 'consumer' | 'advanced'

const STORAGE_KEY = 'cabinet:dashboard:mode'
const MODE_CHANGE_EVENT = 'cabinet:dashboard:mode-change'

function readMode(): DashboardMode {
  if (typeof window === 'undefined') return 'consumer'
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY)
    if (raw === 'advanced' || raw === 'consumer') return raw
  } catch {
    // localStorage unavailable (private browsing edge case) — fall through.
  }
  return 'consumer'
}

function writeMode(mode: DashboardMode): void {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(STORAGE_KEY, mode)
    // Same-tab components re-render via the custom event (localStorage's
    // native 'storage' event only fires cross-tab).
    window.dispatchEvent(new CustomEvent(MODE_CHANGE_EVENT, { detail: mode }))
  } catch {
    // noop
  }
}

/**
 * Read and set the dashboard mode with SSR-safe hydration.
 *
 * On first render (server-side + first client tick), returns 'consumer'. After
 * the effect fires, re-reads localStorage and re-renders if the stored value
 * is 'advanced'. This produces a brief flash of Consumer for users who prefer
 * Advanced; documented tradeoff — the alternative (cookie-backed SSR) is
 * bigger scope and forces the hook onto the server boundary.
 */
export function useDashboardMode(): [DashboardMode, (m: DashboardMode) => void] {
  const [mode, setLocalMode] = useState<DashboardMode>('consumer')

  useEffect(() => {
    setLocalMode(readMode())

    const onChange = (e: Event) => {
      if (e instanceof CustomEvent && (e.detail === 'consumer' || e.detail === 'advanced')) {
        setLocalMode(e.detail)
      }
    }
    const onStorage = (e: StorageEvent) => {
      if (e.key === STORAGE_KEY) setLocalMode(readMode())
    }

    window.addEventListener(MODE_CHANGE_EVENT, onChange)
    window.addEventListener('storage', onStorage)
    return () => {
      window.removeEventListener(MODE_CHANGE_EVENT, onChange)
      window.removeEventListener('storage', onStorage)
    }
  }, [])

  const setMode = useCallback((next: DashboardMode) => {
    writeMode(next)
    setLocalMode(next)
  }, [])

  return [mode, setMode]
}
