'use client'

/**
 * WikilinkHovercard — Spec 037 Q2
 *
 * Wraps a rendered-content container and intercepts hover/focus events on
 * `.wikilink-resolved` anchors to show a preview card.
 *
 * Card content: record title + status badge + first ~200 chars of plain-text
 * content (fetched lazily from /api/library/records/:id/preview).
 *
 * Timing: 200ms delay on hover-in, 100ms on hover-out (feels snappy without
 * popping on every accidental mouse-over).
 *
 * Keyboard: focus on a resolved wikilink → card appears; Esc dismisses.
 *
 * Positioning: below the link, nudged left/right to stay within viewport.
 * No Radix dependency — hand-rolled to keep the bundle lean.
 *
 * Q4 note: `.wikilink-unresolved` and `.wikilink-section-missing` get their
 * dashed/dim appearance from globals.css and a Cmd-click handler here.
 */

import type { CSSProperties, ReactNode } from 'react'
import { useCallback, useEffect, useRef, useState } from 'react'
import type { RecordStatus } from '@/lib/library'

// ----------------------------------------------------------------
// Types
// ----------------------------------------------------------------

interface PreviewData {
  id: string
  title: string
  status: RecordStatus
  preview: string
}

interface HovercardState {
  recordId: string
  anchor: DOMRect
  data: PreviewData | null
  loading: boolean
  error: boolean
}

// ----------------------------------------------------------------
// Status badge colors — Q5 Spec 037 pinned palette (same tokens as
// StatusBadge.tsx, duplicated here to avoid importing a 'use client'
// component inside another client component needlessly).
// ----------------------------------------------------------------
const STATUS_STYLES: Record<RecordStatus, string> = {
  draft: 'bg-zinc-700 text-zinc-300',
  in_review: 'bg-blue-900/60 text-blue-300 border border-blue-700/50',
  approved: 'bg-green-900/60 text-green-300 border border-green-700/50',
  implemented: 'bg-indigo-900/60 text-indigo-300 border border-indigo-700/50',
  superseded: 'bg-zinc-800/60 text-zinc-500 line-through',
}

const STATUS_LABELS: Record<RecordStatus, string> = {
  draft: 'Draft',
  in_review: 'In Review',
  approved: 'Approved',
  implemented: 'Implemented',
  superseded: 'Superseded',
}

// ----------------------------------------------------------------
// Component
// ----------------------------------------------------------------

interface Props {
  children: ReactNode
  /** Optional CSS class(es) forwarded to the container div */
  className?: string
}

export default function WikilinkHovercard({ children, className }: Props) {
  const containerRef = useRef<HTMLDivElement>(null)
  const [card, setCard] = useState<HovercardState | null>(null)
  const showTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const hideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  // Track in-flight fetches to avoid race conditions when user hovers multiple links
  const fetchAbortRef = useRef<AbortController | null>(null)

  // ----------------------------------------------------------------
  // Hovercard show/hide helpers
  // ----------------------------------------------------------------

  const cancelShow = useCallback(() => {
    if (showTimerRef.current) {
      clearTimeout(showTimerRef.current)
      showTimerRef.current = null
    }
  }, [])

  const cancelHide = useCallback(() => {
    if (hideTimerRef.current) {
      clearTimeout(hideTimerRef.current)
      hideTimerRef.current = null
    }
  }, [])

  const hide = useCallback(() => {
    cancelShow()
    fetchAbortRef.current?.abort()
    setCard(null)
  }, [cancelShow])

  const scheduleHide = useCallback(() => {
    cancelHide()
    hideTimerRef.current = setTimeout(hide, 100)
  }, [cancelHide, hide])

  const fetchPreview = useCallback(async (recordId: string, anchor: DOMRect) => {
    // Abort any previous in-flight fetch
    fetchAbortRef.current?.abort()
    const abortCtrl = new AbortController()
    fetchAbortRef.current = abortCtrl

    setCard({ recordId, anchor, data: null, loading: true, error: false })

    try {
      const res = await fetch(`/api/library/records/${recordId}/preview`, {
        signal: abortCtrl.signal,
      })
      if (!res.ok) throw new Error('preview failed')
      const data = (await res.json()) as PreviewData
      setCard((prev) => {
        if (!prev || prev.recordId !== recordId) return prev
        return { ...prev, data, loading: false }
      })
    } catch (err) {
      if ((err as { name?: string }).name === 'AbortError') return
      setCard((prev) => {
        if (!prev || prev.recordId !== recordId) return prev
        return { ...prev, loading: false, error: true }
      })
    }
  }, [])

  const scheduleShow = useCallback(
    (recordId: string, anchor: DOMRect) => {
      cancelHide()
      cancelShow()
      showTimerRef.current = setTimeout(() => {
        fetchPreview(recordId, anchor)
      }, 200)
    },
    [cancelHide, cancelShow, fetchPreview]
  )

  // ----------------------------------------------------------------
  // Event delegation — mouseenter/mouseleave + focus/blur on anchors
  // ----------------------------------------------------------------

  useEffect(() => {
    const container = containerRef.current
    if (!container) return

    function getWikilinkAnchor(target: EventTarget | null): HTMLAnchorElement | null {
      if (!(target instanceof Element)) return null
      const anchor = target.closest('a.wikilink-resolved')
      return anchor instanceof HTMLAnchorElement ? anchor : null
    }

    function getRecordId(anchor: HTMLAnchorElement): string | null {
      // href is /library/<spaceId>/<recordId>[#section]
      const url = new URL(anchor.href, window.location.origin)
      const parts = url.pathname.split('/').filter(Boolean)
      // parts: ['library', spaceId, recordId]
      return parts.length >= 3 ? parts[2] : null
    }

    function onMouseEnter(e: MouseEvent) {
      const anchor = getWikilinkAnchor(e.target)
      if (!anchor) return
      const recordId = getRecordId(anchor)
      if (!recordId) return
      scheduleShow(recordId, anchor.getBoundingClientRect())
    }

    function onMouseLeave(e: MouseEvent) {
      const anchor = getWikilinkAnchor(e.target)
      if (!anchor) return
      // Don't hide if moving INTO the card itself
      const related = e.relatedTarget instanceof Element ? e.relatedTarget : null
      if (related?.closest('[data-wikilink-card]')) return
      scheduleHide()
    }

    function onFocusIn(e: FocusEvent) {
      const anchor = getWikilinkAnchor(e.target)
      if (!anchor) return
      const recordId = getRecordId(anchor)
      if (!recordId) return
      // Immediate show on keyboard focus (no delay — keyboard users are deliberate)
      cancelShow()
      fetchPreview(recordId, anchor.getBoundingClientRect())
    }

    function onFocusOut(e: FocusEvent) {
      const anchor = getWikilinkAnchor(e.target)
      if (!anchor) return
      const related = e.relatedTarget instanceof Element ? e.relatedTarget : null
      if (related?.closest('[data-wikilink-card]')) return
      scheduleHide()
    }

    // Q4: Cmd-click (or Ctrl-click on non-Mac) on unresolved links → navigate to create
    function onClick(e: MouseEvent) {
      const target = e.target instanceof Element ? e.target : null
      const anchor = target?.closest('a.wikilink-unresolved')
      if (!(anchor instanceof HTMLAnchorElement)) return

      // Only intercept Cmd/Ctrl click — plain click navigates normally per spec Q4
      if (!(e.metaKey || e.ctrlKey)) return
      e.preventDefault()
      // The href already contains /library/new?title=... from wikilinks.ts
      window.location.href = anchor.href
    }

    container.addEventListener('mouseenter', onMouseEnter, true)
    container.addEventListener('mouseleave', onMouseLeave, true)
    container.addEventListener('focusin', onFocusIn, true)
    container.addEventListener('focusout', onFocusOut, true)
    container.addEventListener('click', onClick, true)

    return () => {
      container.removeEventListener('mouseenter', onMouseEnter, true)
      container.removeEventListener('mouseleave', onMouseLeave, true)
      container.removeEventListener('focusin', onFocusIn, true)
      container.removeEventListener('focusout', onFocusOut, true)
      container.removeEventListener('click', onClick, true)
    }
  }, [scheduleShow, scheduleHide, cancelShow, fetchPreview])

  // ----------------------------------------------------------------
  // Esc dismisses the card (from anywhere in the document)
  // ----------------------------------------------------------------

  useEffect(() => {
    if (!card) return

    function onKeyDown(e: KeyboardEvent) {
      if (e.key === 'Escape') {
        hide()
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [card, hide])

  // ----------------------------------------------------------------
  // Cleanup timers on unmount
  // ----------------------------------------------------------------

  useEffect(() => {
    return () => {
      cancelShow()
      cancelHide()
      fetchAbortRef.current?.abort()
    }
  }, [cancelShow, cancelHide])

  // ----------------------------------------------------------------
  // Card positioning — below the anchor, viewport-clamped
  // ----------------------------------------------------------------

  function getCardStyle(anchor: DOMRect): CSSProperties {
    const cardWidth = 300
    const gapY = 6 // px gap between anchor bottom and card top

    // Vertical: below the anchor (fixed positioning relative to viewport)
    const top = anchor.bottom + gapY + window.scrollY

    // Horizontal: left-aligned to anchor, but clamp so card doesn't overflow right edge
    let left = anchor.left + window.scrollX
    const overflowRight = left + cardWidth - (window.innerWidth - 12)
    if (overflowRight > 0) left -= overflowRight

    return {
      position: 'absolute',
      top,
      left: Math.max(8, left),
      width: cardWidth,
      zIndex: 50,
    }
  }

  // ----------------------------------------------------------------
  // Render
  // ----------------------------------------------------------------

  return (
    <div ref={containerRef} className={className}>
      {children}

      {card && (
        <div
          style={getCardStyle(card.anchor)}
          data-wikilink-card
          onMouseEnter={cancelHide}
          onMouseLeave={scheduleHide}
          role="tooltip"
          aria-live="polite"
          className="rounded-lg border border-zinc-700 bg-zinc-900 shadow-xl p-3 text-sm pointer-events-auto"
        >
          {card.loading && (
            <p className="text-xs text-zinc-600">Loading…</p>
          )}

          {card.error && (
            <p className="text-xs text-red-400">Could not load preview.</p>
          )}

          {card.data && (
            <div className="flex flex-col gap-2">
              {/* Title + status badge */}
              <div className="flex items-start justify-between gap-2">
                <p className="font-medium text-white leading-snug truncate flex-1">
                  {card.data.title}
                </p>
                <span
                  className={`shrink-0 rounded px-1.5 py-0.5 text-xs font-medium ${STATUS_STYLES[card.data.status]}`}
                >
                  {STATUS_LABELS[card.data.status]}
                </span>
              </div>

              {/* Content preview */}
              {card.data.preview && (
                <p className="text-xs text-zinc-400 leading-relaxed line-clamp-4">
                  {card.data.preview}
                </p>
              )}

              {/* Empty content hint */}
              {!card.data.preview && (
                <p className="text-xs italic text-zinc-600">No content yet.</p>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  )
}
