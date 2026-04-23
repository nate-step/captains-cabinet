'use client'

/**
 * CommandPalette — Spec 037 A3
 *
 * Global Cmd-K / Ctrl-K keyboard shortcut opens a modal overlay for fast record
 * navigation across all library spaces. Cmd-Shift-O is an alternate opener
 * (quick-switcher affordance per Q1 decision).
 *
 * Empty state: recent records from localStorage.
 * Query starting with `>`: reserved command namespace (Phase B) — shows placeholder.
 * Otherwise: title-prefix typeahead (fast) + semantic search (ranked below), deduped.
 *
 * a11y: focus trapped inside modal, restored on close, aria-live result count.
 * Keyboard nav: ↑↓ move, Enter opens, Shift-Enter opens new tab, Esc closes.
 */

import { useEffect, useRef, useState, useCallback, type KeyboardEvent as ReactKeyboardEvent } from 'react'
import { useRouter } from 'next/navigation'
import {
  Command,
  CommandInput,
  CommandList,
  CommandItem,
  CommandEmpty,
  CommandGroup,
} from 'cmdk'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface RecentRecord {
  id: string
  title: string
  spaceId: string
  spaceName: string
}

interface SearchResult {
  record_id: string
  space_id: string
  space_name?: string
  title: string
  preview?: string
  similarity?: number
}

interface TypeaheadResult {
  id: string
  title: string
  spaceId: string
  spaceName: string
  labels?: string[]
}

interface PaletteItem {
  id: string
  title: string
  spaceId: string
  spaceName: string
  preview?: string
  source: 'recent' | 'prefix' | 'semantic'
}

// ---------------------------------------------------------------------------
// localStorage helpers (encapsulated — not exported broadly)
// ---------------------------------------------------------------------------

const LS_KEY = 'library.recent.records'
const MAX_RECENTS = 10

function getRecentRecords(): RecentRecord[] {
  if (typeof window === 'undefined') return []
  try {
    const raw = window.localStorage.getItem(LS_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw) as unknown
    if (!Array.isArray(parsed)) return []
    return parsed.filter(
      (item): item is RecentRecord =>
        typeof item === 'object' &&
        item !== null &&
        typeof (item as RecentRecord).id === 'string' &&
        typeof (item as RecentRecord).title === 'string' &&
        typeof (item as RecentRecord).spaceId === 'string' &&
        typeof (item as RecentRecord).spaceName === 'string'
    )
  } catch {
    return []
  }
}

export function pushRecentRecord(rec: RecentRecord): void {
  if (typeof window === 'undefined') return
  try {
    const existing = getRecentRecords().filter((r) => r.id !== rec.id)
    const updated = [rec, ...existing].slice(0, MAX_RECENTS)
    window.localStorage.setItem(LS_KEY, JSON.stringify(updated))
  } catch {
    // localStorage unavailable — silently ignore
  }
}

// ---------------------------------------------------------------------------
// Debounce hook
// ---------------------------------------------------------------------------

function useDebounced<T>(value: T, delay: number): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const t = setTimeout(() => setDebounced(value), delay)
    return () => clearTimeout(t)
  }, [value, delay])
  return debounced
}

// ---------------------------------------------------------------------------
// CommandPalette component
// ---------------------------------------------------------------------------

export default function CommandPalette() {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [items, setItems] = useState<PaletteItem[]>([])
  const [loading, setLoading] = useState(false)
  const [recents, setRecents] = useState<RecentRecord[]>([])
  const debouncedQuery = useDebounced(query, 150)
  const router = useRouter()
  // Track previously focused element to restore focus on close
  const prevFocusRef = useRef<Element | null>(null)
  // Track shift key for Shift-Enter
  const shiftRef = useRef(false)
  // Dialog root — focus-trap boundary (cmdk 1.1 doesn't implement one)
  const dialogRef = useRef<HTMLDivElement | null>(null)

  // Focus-trap: wrap Tab/Shift-Tab within the dialog so the palette stays modal
  // without pulling in @radix-ui/react-focus-trap. a11y spec requires Tab to
  // not escape an open modal (aria-modal alone only hints to AT).
  function handleFocusTrap(e: ReactKeyboardEvent<HTMLDivElement>) {
    if (e.key !== 'Tab') return
    const root = dialogRef.current
    if (!root) return
    const focusables = root.querySelectorAll<HTMLElement>(
      'a[href], button:not([disabled]), textarea:not([disabled]), input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'
    )
    if (focusables.length === 0) return
    const first = focusables[0]
    const last = focusables[focusables.length - 1]
    const active = document.activeElement as HTMLElement | null
    if (e.shiftKey && active === first) {
      e.preventDefault()
      last.focus()
    } else if (!e.shiftKey && active === last) {
      e.preventDefault()
      first.focus()
    }
  }

  // Load recents from localStorage on open
  useEffect(() => {
    if (open) {
      setRecents(getRecentRecords())
    }
  }, [open])

  // Global keyboard listener: Cmd-K / Ctrl-K open; Cmd-Shift-O alternate open;
  // Esc closes when open (palette is in DOM — capture before cmdk sees it).
  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      // Esc closes palette — check this before the mod guard
      if (e.key === 'Escape') {
        if (open) {
          e.preventDefault()
          setOpen(false)
        }
        return
      }

      const mod = e.metaKey || e.ctrlKey
      if (!mod) return

      // Cmd-K or Cmd-Shift-O
      if (e.key === 'k' && !e.shiftKey) {
        e.preventDefault()
        setOpen((prev) => !prev)
        return
      }
      if (e.key === 'o' && e.shiftKey) {
        e.preventDefault()
        setOpen((prev) => !prev)
        return
      }
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [open])

  // Save/restore focus
  useEffect(() => {
    if (open) {
      prevFocusRef.current = document.activeElement
    } else {
      // Restore after animation frame so DOM has settled
      const el = prevFocusRef.current
      if (el instanceof HTMLElement) {
        requestAnimationFrame(() => el.focus())
      }
      // Reset state on close
      setQuery('')
      setItems([])
      setLoading(false)
    }
  }, [open])

  // Track shift key state
  useEffect(() => {
    function onKeyDown(e: KeyboardEvent) {
      if (e.key === 'Shift') shiftRef.current = true
    }
    function onKeyUp(e: KeyboardEvent) {
      if (e.key === 'Shift') shiftRef.current = false
    }
    window.addEventListener('keydown', onKeyDown)
    window.addEventListener('keyup', onKeyUp)
    return () => {
      window.removeEventListener('keydown', onKeyDown)
      window.removeEventListener('keyup', onKeyUp)
    }
  }, [])

  // Fetch results when debounced query changes
  useEffect(() => {
    const q = debouncedQuery.trim()
    if (!q || q.startsWith('>')) {
      setItems([])
      return
    }

    let cancelled = false
    setItems([])
    setLoading(true)

    async function fetchResults() {
      try {
        // Fire both in parallel
        const [prefixRes, semanticRes] = await Promise.allSettled([
          fetch(`/api/library/records/typeahead?q=${encodeURIComponent(q)}&limit=5`).then(
            (r) => r.json() as Promise<{ results: TypeaheadResult[] }>
          ),
          fetch('/api/library/search', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query: q, limit: 8 }),
          }).then((r) => r.json() as Promise<{ results: SearchResult[] }>),
        ])

        if (cancelled) return

        const seen = new Set<string>()
        const merged: PaletteItem[] = []

        // Prefix results first (fast, deterministic)
        if (prefixRes.status === 'fulfilled' && Array.isArray(prefixRes.value.results)) {
          for (const r of prefixRes.value.results) {
            if (!seen.has(r.id)) {
              seen.add(r.id)
              merged.push({
                id: r.id,
                title: r.title,
                spaceId: r.spaceId,
                spaceName: r.spaceName,
                source: 'prefix',
              })
            }
          }
        }

        // Semantic results below
        if (semanticRes.status === 'fulfilled' && Array.isArray(semanticRes.value.results)) {
          for (const r of semanticRes.value.results) {
            if (!seen.has(r.record_id)) {
              seen.add(r.record_id)
              merged.push({
                id: r.record_id,
                title: r.title,
                spaceId: r.space_id,
                spaceName: r.space_name ?? '',
                preview: r.preview,
                source: 'semantic',
              })
            }
          }
        }

        setItems(merged)
      } catch {
        // Network error — leave items empty
        if (!cancelled) setItems([])
      } finally {
        if (!cancelled) setLoading(false)
      }
    }

    void fetchResults()
    return () => {
      cancelled = true
    }
  }, [debouncedQuery])

  const openRecord = useCallback(
    (item: PaletteItem, newTab: boolean) => {
      const url = `/library/${item.spaceId}/${item.id}`
      if (newTab) {
        window.open(url, '_blank', 'noopener,noreferrer')
      } else {
        router.push(url)
      }
      setOpen(false)
    },
    [router]
  )

  // Determine display mode
  const q = query.trim()
  const isCommandMode = q.startsWith('>')
  const hasQuery = q.length > 0 && !isCommandMode

  // Result count for aria-live
  const resultCount = hasQuery ? items.length : recents.length

  if (!open) return null

  return (
    <>
      {/* Backdrop */}
      <div
        className="fixed inset-0 z-[70] bg-black/60 backdrop-blur-sm"
        aria-hidden="true"
        onClick={() => setOpen(false)}
      />

      {/* Palette card */}
      <div
        ref={dialogRef}
        role="dialog"
        aria-label="Command palette — search library records"
        aria-modal="true"
        onKeyDown={handleFocusTrap}
        className="fixed inset-x-0 top-[15vh] z-[71] mx-auto w-full max-w-xl px-4"
      >
        <Command
          className="overflow-hidden rounded-2xl border border-zinc-700/60 bg-zinc-900 shadow-2xl ring-1 ring-black/10"
          // Disable built-in cmdk filtering — we handle search ourselves
          shouldFilter={false}
          loop
        >
          {/* Input */}
          <div className="flex items-center border-b border-zinc-800 px-4">
            <span className="mr-3 shrink-0 text-zinc-500" aria-hidden="true">
              ⌘
            </span>
            <CommandInput
              // role="combobox", aria-expanded, aria-controls are managed
              // internally by cmdk — passing them here is harmless (overridden)
              // but we keep them for spec traceability (A3 a11y requirements).
              role="combobox"
              aria-autocomplete="list"
              aria-expanded={open}
              placeholder="Search records… (> for commands)"
              value={query}
              onValueChange={setQuery}
              className="flex-1 bg-transparent py-4 text-sm text-white placeholder-zinc-500 outline-none"
              autoFocus
            />
            {loading && (
              <span className="ml-2 text-xs text-zinc-600" aria-hidden="true">
                …
              </span>
            )}
            <kbd
              className="ml-3 hidden rounded border border-zinc-700 px-1.5 py-0.5 text-xs text-zinc-600 sm:block"
              aria-label="Press Escape to close"
            >
              esc
            </kbd>
          </div>

          {/* Aria-live region: announces result count to screen readers */}
          <span
            aria-live="polite"
            aria-atomic="true"
            className="sr-only"
          >
            {hasQuery && !loading
              ? `${resultCount} result${resultCount === 1 ? '' : 's'}`
              : ''}
          </span>

          {/* Results — cmdk manages id/role/aria-activedescendant internally */}
          <CommandList
            className="max-h-[60vh] overflow-y-auto py-2"
            aria-label="Search results"
          >
            {/* Command namespace reserved */}
            {isCommandMode && (
              <CommandItem
                disabled
                value="__commands_placeholder__"
                className="mx-2 flex cursor-not-allowed items-center gap-3 rounded-lg px-3 py-2.5 opacity-40"
              >
                <span className="text-xs font-mono text-zinc-400">&gt;</span>
                <span className="text-sm text-zinc-400">Commands coming soon</span>
              </CommandItem>
            )}

            {/* Recent records (empty query) */}
            {!hasQuery && !isCommandMode && recents.length > 0 && (
              <CommandGroup
                heading={
                  <span className="px-3 py-1.5 text-xs font-medium uppercase tracking-wide text-zinc-600">
                    Recent
                  </span>
                }
              >
                {recents.map((rec) => (
                  <PaletteRow
                    key={rec.id}
                    item={{ ...rec, source: 'recent' }}
                    onSelect={(newTab) => openRecord({ ...rec, source: 'recent' }, newTab)}
                    shiftRef={shiftRef}
                  />
                ))}
              </CommandGroup>
            )}

            {/* Empty state: no query, no recents */}
            {!hasQuery && !isCommandMode && recents.length === 0 && (
              <CommandEmpty>
                <p className="py-6 text-center text-sm text-zinc-600">
                  Type to search across all spaces
                </p>
              </CommandEmpty>
            )}

            {/* Search results */}
            {hasQuery && !loading && items.length > 0 && (
              <CommandGroup>
                {items.map((item) => (
                  <PaletteRow
                    key={item.id}
                    item={item}
                    onSelect={(newTab) => openRecord(item, newTab)}
                    shiftRef={shiftRef}
                  />
                ))}
              </CommandGroup>
            )}

            {/* No results */}
            {hasQuery && !loading && items.length === 0 && (
              <CommandEmpty>
                <p className="py-6 text-center text-sm text-zinc-600">
                  No records found for &ldquo;{q}&rdquo;
                </p>
              </CommandEmpty>
            )}

            {/* Loading state */}
            {hasQuery && loading && (
              <CommandEmpty>
                <p className="py-6 text-center text-sm text-zinc-600">Searching…</p>
              </CommandEmpty>
            )}
          </CommandList>

          {/* Footer hint */}
          <div className="flex items-center gap-4 border-t border-zinc-800 px-4 py-2.5 text-xs text-zinc-600">
            <span><kbd className="rounded border border-zinc-700 px-1 py-0.5 text-zinc-600">↵</kbd> open</span>
            <span><kbd className="rounded border border-zinc-700 px-1 py-0.5 text-zinc-600">⇧↵</kbd> new tab</span>
            <span><kbd className="rounded border border-zinc-700 px-1 py-0.5 text-zinc-600">↑↓</kbd> navigate</span>
            <span className="ml-auto"><kbd className="rounded border border-zinc-700 px-1 py-0.5 text-zinc-600">esc</kbd> close</span>
          </div>
        </Command>
      </div>
    </>
  )
}

// ---------------------------------------------------------------------------
// PaletteRow — individual result item
// ---------------------------------------------------------------------------

interface PaletteRowProps {
  item: PaletteItem
  onSelect: (newTab: boolean) => void
  shiftRef: React.MutableRefObject<boolean>
}

function PaletteRow({ item, onSelect, shiftRef }: PaletteRowProps) {
  return (
    <CommandItem
      value={`${item.id}-${item.title}`}
      onSelect={() => onSelect(shiftRef.current)}
      className="mx-2 flex cursor-pointer flex-col gap-0.5 rounded-lg px-3 py-2.5 text-left
        data-[selected=true]:bg-zinc-800 data-[selected=true]:outline-none
        hover:bg-zinc-800/60"
      aria-selected={undefined} // cmdk manages this
    >
      <div className="flex items-center gap-2 min-w-0">
        {item.spaceName && (
          <span className="shrink-0 text-xs text-zinc-500">{item.spaceName}</span>
        )}
        {item.spaceName && (
          <span className="text-zinc-700" aria-hidden="true">/</span>
        )}
        <span className="truncate text-sm font-medium text-white">{item.title}</span>
        {item.source === 'semantic' && (
          <span className="ml-auto shrink-0 text-xs text-zinc-700">~</span>
        )}
      </div>
      {item.preview && (
        <p className="truncate text-xs text-zinc-600 pl-0">{item.preview}</p>
      )}
    </CommandItem>
  )
}
