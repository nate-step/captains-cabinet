'use client'

/**
 * LibrarySidebarClient — Spec 037 A4
 *
 * Client island mounted over the server-rendered sidebar tree.
 * Responsibilities:
 *   1. Apply aria-current="page" to the current record link (DOM mutation).
 *   2. Toggle collapsed/expanded state on desktop, persisted to localStorage.
 *   3. Provide a mobile drawer toggle (opens/closes the full sidebar as a sheet).
 * The heavy data-fetching and structural HTML live in LibrarySidebar (server).
 */

import type { KeyboardEvent as ReactKeyboardEvent, ReactNode } from 'react'
import { usePathname } from 'next/navigation'
import { useEffect, useRef, useState, useCallback } from 'react'

// Spec 037 Q3: key is `library.sidebar.open`. Semantics: true = open (default).
const LS_KEY = 'library.sidebar.open'

function readOpen(): boolean {
  if (typeof window === 'undefined') return true
  try {
    const v = window.localStorage.getItem(LS_KEY)
    return v === null ? true : v === 'true'
  } catch {
    return true
  }
}

function writeOpen(value: boolean): void {
  try {
    window.localStorage.setItem(LS_KEY, String(value))
  } catch {
    // localStorage unavailable (Safari private mode etc.) — state persists in-memory only.
  }
}

// Applies aria-current="page" to the link matching pathname + adds active classes
// (append-only, never touches base color/hover classes so server-rendered styling
// for variants like "All Spaces" keeps its original text-zinc-500 tone). Also
// auto-opens the parent <details> so the highlighted link is visible in the tree.
export function SidebarActiveHighlight() {
  const pathname = usePathname()

  useEffect(() => {
    const links = document.querySelectorAll<HTMLAnchorElement>('[data-sidebar-record-link]')
    links.forEach((a) => {
      const isActive = a.getAttribute('href') === pathname
      if (isActive) {
        a.setAttribute('aria-current', 'page')
        a.classList.add('bg-zinc-800', 'text-white')
        const parentDetails = a.closest('details')
        if (parentDetails && !parentDetails.open) parentDetails.open = true
      } else {
        a.removeAttribute('aria-current')
        a.classList.remove('bg-zinc-800', 'text-white')
      }
    })
  }, [pathname])

  return null
}

// Desktop-only collapse/expand shell.
// On mobile the sidebar is hidden via CSS (md:block) — mobile uses LibraryDrawer.
interface SidebarShellProps {
  children: ReactNode
}

export function SidebarShell({ children }: SidebarShellProps) {
  const [open, setOpen] = useState(true)

  useEffect(() => {
    setOpen(readOpen())
  }, [])

  const toggle = useCallback(() => {
    setOpen((prev: boolean) => {
      const next = !prev
      writeOpen(next)
      return next
    })
  }, [])

  return (
    <div
      className={`relative flex flex-col transition-[width] duration-200 ${
        open ? 'w-56' : 'w-10'
      }`}
    >
      {/* Active highlight — zero DOM output, pure side-effect */}
      <SidebarActiveHighlight />

      {/* Collapse toggle row */}
      <div className="flex h-8 shrink-0 items-center justify-end px-1 pt-1">
        <button
          type="button"
          onClick={toggle}
          aria-label={open ? 'Collapse library sidebar' : 'Expand library sidebar'}
          aria-expanded={open}
          className="flex h-7 w-7 items-center justify-center rounded text-zinc-500 transition-colors hover:bg-zinc-800 hover:text-zinc-300"
        >
          {open ? (
            <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M18.75 19.5l-7.5-7.5 7.5-7.5m-6 15L5.25 12l7.5-7.5" />
            </svg>
          ) : (
            <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M11.25 4.5l7.5 7.5-7.5 7.5m-6-15l7.5 7.5-7.5 7.5" />
            </svg>
          )}
        </button>
      </div>

      {/* Tree content */}
      <div className={open ? 'block min-w-0 overflow-hidden' : 'hidden'}>
        {children}
      </div>

      {/* Collapsed rail — reopen affordance */}
      {!open && (
        <button
          type="button"
          onClick={toggle}
          aria-label="Expand library sidebar"
          title="Expand library navigation"
          className="mt-2 flex flex-col items-center px-1 text-zinc-600 hover:text-zinc-400"
        >
          <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
            <path strokeLinecap="round" strokeLinejoin="round" d="M12 6.042A8.967 8.967 0 0 0 6 3.75c-1.052 0-2.062.18-3 .512v14.25A8.987 8.987 0 0 1 6 18c2.305 0 4.408.867 6 2.292m0-14.25a8.966 8.966 0 0 1 6-2.292c1.052 0 2.062.18 3 .512v14.25A8.987 8.987 0 0 0 18 18a8.967 8.967 0 0 0-6 2.292m0-14.25v14.25" />
          </svg>
        </button>
      )}
    </div>
  )
}

// Mobile drawer — full-height sheet from the left, toggled by a button
// rendered at the top of the library content area on mobile.
interface LibraryDrawerProps {
  children: ReactNode
}

export function LibraryDrawer({ children }: LibraryDrawerProps) {
  const [open, setOpen] = useState(false)
  const pathname = usePathname()
  const triggerRef = useRef<HTMLButtonElement | null>(null)
  const panelRef = useRef<HTMLElement | null>(null)

  // Close drawer on navigation
  useEffect(() => {
    setOpen(false)
  }, [pathname])

  // AC14 a11y: Esc closes, focus moves into panel on open, restores to trigger on close.
  useEffect(() => {
    if (!open) return
    const prevActive = document.activeElement as HTMLElement | null
    const id = requestAnimationFrame(() => panelRef.current?.focus())
    const onKeyDown = (e: globalThis.KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        setOpen(false)
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => {
      cancelAnimationFrame(id)
      window.removeEventListener('keydown', onKeyDown)
      if (prevActive && typeof prevActive.focus === 'function') prevActive.focus()
    }
  }, [open])

  // Focus trap for Tab / Shift-Tab inside the drawer panel.
  const handleFocusTrap = useCallback((e: ReactKeyboardEvent<HTMLElement>) => {
    if (e.key !== 'Tab' || !panelRef.current) return
    const focusables = panelRef.current.querySelectorAll<HTMLElement>(
      'a[href], button, [tabindex]:not([tabindex="-1"])'
    )
    if (focusables.length === 0) return
    const first = focusables[0]
    const last = focusables[focusables.length - 1]
    const active = document.activeElement
    if (e.shiftKey && active === first) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && active === last) {
      e.preventDefault()
      first.focus()
    }
  }, [])

  return (
    <>
      {/* Hamburger — visible only on mobile */}
      <button
        ref={triggerRef}
        type="button"
        onClick={() => setOpen(true)}
        aria-label="Open library navigation"
        aria-expanded={open}
        aria-controls="library-drawer-panel"
        className="mb-4 flex items-center gap-2 rounded-lg border border-zinc-800 px-3 py-2 text-sm text-zinc-400 transition-colors hover:border-zinc-700 hover:text-zinc-200 md:hidden"
      >
        <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
          <path strokeLinecap="round" strokeLinejoin="round" d="M12 6.042A8.967 8.967 0 0 0 6 3.75c-1.052 0-2.062.18-3 .512v14.25A8.987 8.987 0 0 1 6 18c2.305 0 4.408.867 6 2.292m0-14.25a8.966 8.966 0 0 1 6-2.292c1.052 0 2.062.18 3 .512v14.25A8.987 8.987 0 0 0 18 18a8.967 8.967 0 0 0-6 2.292m0-14.25v14.25" />
        </svg>
        Library Nav
      </button>

      {/* Backdrop */}
      {open && (
        <div
          className="fixed inset-0 z-40 bg-black/50 md:hidden"
          aria-hidden="true"
          onClick={() => setOpen(false)}
        />
      )}

      {/* Drawer panel */}
      <aside
        ref={panelRef}
        id="library-drawer-panel"
        role="dialog"
        aria-modal={open || undefined}
        aria-labelledby="library-drawer-title"
        tabIndex={-1}
        onKeyDown={handleFocusTrap}
        className={`fixed left-0 top-0 z-50 flex h-full w-72 flex-col overflow-y-auto border-r border-zinc-800 bg-zinc-950 pt-14 transition-transform focus:outline-none md:hidden ${
          open ? 'translate-x-0' : '-translate-x-full'
        }`}
      >
        <div className="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
          <span id="library-drawer-title" className="text-sm font-semibold text-zinc-300">Library</span>
          <button
            type="button"
            onClick={() => setOpen(false)}
            aria-label="Close library navigation"
            className="text-zinc-500 hover:text-zinc-300"
          >
            <svg className="h-5 w-5" fill="none" viewBox="0 0 24 24" strokeWidth={1.5} stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
        <div className="flex-1 overflow-y-auto py-2">
          {/* Active highlight for mobile drawer links */}
          <SidebarActiveHighlight />
          {children}
        </div>
      </aside>
    </>
  )
}
