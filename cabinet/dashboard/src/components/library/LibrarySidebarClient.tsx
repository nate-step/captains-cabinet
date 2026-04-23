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

import type { ReactNode } from 'react'
import { usePathname } from 'next/navigation'
import { useEffect, useState, useCallback } from 'react'

const LS_KEY = 'library.sidebar.collapsed'

function readCollapsed(): boolean {
  if (typeof window === 'undefined') return false
  try {
    return window.localStorage.getItem(LS_KEY) === 'true'
  } catch {
    return false
  }
}

function writeCollapsed(value: boolean): void {
  try {
    window.localStorage.setItem(LS_KEY, String(value))
  } catch {
    // Ignore storage errors
  }
}

// Applies aria-current="page" and active classes to the link matching pathname.
// DOM-patching approach keeps the parent server component and avoids prop-drilling
// usePathname() through a client boundary into a deeply nested link.
export function SidebarActiveHighlight() {
  const pathname = usePathname()

  useEffect(() => {
    const links = document.querySelectorAll<HTMLAnchorElement>('[data-sidebar-record-link]')
    links.forEach((a) => {
      const isActive = a.getAttribute('href') === pathname
      if (isActive) {
        a.setAttribute('aria-current', 'page')
        a.classList.add('bg-zinc-800', 'text-white')
        a.classList.remove('text-zinc-400', 'hover:bg-zinc-800/50', 'hover:text-zinc-200')
      } else {
        a.removeAttribute('aria-current')
        a.classList.remove('bg-zinc-800', 'text-white')
        a.classList.add('text-zinc-400', 'hover:bg-zinc-800/50', 'hover:text-zinc-200')
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
  const [collapsed, setCollapsed] = useState(false)

  useEffect(() => {
    setCollapsed(readCollapsed())
  }, [])

  const toggle = useCallback(() => {
    setCollapsed((prev: boolean) => {
      const next = !prev
      writeCollapsed(next)
      return next
    })
  }, [])

  return (
    <div
      className={`relative flex flex-col transition-[width] duration-200 ${
        collapsed ? 'w-10' : 'w-56'
      }`}
    >
      {/* Active highlight — zero DOM output, pure side-effect */}
      <SidebarActiveHighlight />

      {/* Collapse toggle row */}
      <div className="flex h-8 shrink-0 items-center justify-end px-1 pt-1">
        <button
          type="button"
          onClick={toggle}
          aria-label={collapsed ? 'Expand library sidebar' : 'Collapse library sidebar'}
          className="flex h-7 w-7 items-center justify-center rounded text-zinc-500 transition-colors hover:bg-zinc-800 hover:text-zinc-300"
        >
          {collapsed ? (
            <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M11.25 4.5l7.5 7.5-7.5 7.5m-6-15l7.5 7.5-7.5 7.5" />
            </svg>
          ) : (
            <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
              <path strokeLinecap="round" strokeLinejoin="round" d="M18.75 19.5l-7.5-7.5 7.5-7.5m-6 15L5.25 12l7.5-7.5" />
            </svg>
          )}
        </button>
      </div>

      {/* Tree content */}
      <div className={collapsed ? 'hidden' : 'block min-w-0 overflow-hidden'}>
        {children}
      </div>

      {/* Collapsed rail — reopen affordance */}
      {collapsed && (
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

  // Close drawer on navigation
  useEffect(() => {
    setOpen(false)
  }, [pathname])

  return (
    <>
      {/* Hamburger — visible only on mobile */}
      <button
        type="button"
        onClick={() => setOpen(true)}
        aria-label="Open library navigation"
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
        className={`fixed left-0 top-0 z-50 flex h-full w-72 flex-col overflow-y-auto border-r border-zinc-800 bg-zinc-950 pt-14 transition-transform md:hidden ${
          open ? 'translate-x-0' : '-translate-x-full'
        }`}
        aria-label="Library navigation drawer"
      >
        <div className="flex items-center justify-between border-b border-zinc-800 px-4 py-3">
          <span className="text-sm font-semibold text-zinc-300">Library</span>
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
