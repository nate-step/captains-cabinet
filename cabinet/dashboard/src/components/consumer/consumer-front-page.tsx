'use client'

/**
 * ConsumerFrontPage — Spec 032 Consumer Mode client wrapper.
 *
 * Renders the 5-card grid when in Consumer mode.
 * Gate is at page.tsx level (consumerModeEnabled guard), so this component
 * only renders when both:
 *   1. consumerModeEnabled is true (feature flag)
 *   2. useDashboardMode() returns 'consumer'
 *
 * The feature-flag-off / Advanced-mode path never imports this component's
 * card children — structural inertness preserved (Spec 032 plan §feature-flag).
 *
 * NOTE: Cards are async Server Components imported dynamically here.
 * In Next.js App Router, importing Server Components from a Client Component
 * is allowed when the server children are passed as props (children pattern)
 * or via slot composition. We use the slot pattern: page.tsx renders the
 * cards as children of this wrapper after the mode check.
 */

import { type ReactNode } from 'react'

interface ConsumerFrontPageProps {
  /** Pre-rendered card slots from page.tsx (server components) */
  children: ReactNode
}

export default function ConsumerFrontPage({ children }: ConsumerFrontPageProps) {
  return (
    <div>
      {/* Page header */}
      <div className="mb-6">
        <h1 className="text-2xl font-bold text-white">Your Cabinet</h1>
        <p className="mt-1 text-sm text-zinc-500">
          At a glance &mdash; everything that matters right now.
          {/* PENDING CAPTAIN APPROVAL: header copy */}
        </p>
      </div>

      {/* 5-card grid: 1-col mobile, 2-col md, 3-col lg */}
      <div className="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3">
        {children}
      </div>
    </div>
  )
}
