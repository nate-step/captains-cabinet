'use client'

/**
 * OfficerColumnsGated — renders officer columns only in Advanced dashboard mode.
 *
 * Per Spec 038 AC #16: "Consumer-mode viewers see only the Captain column."
 * Dashboard mode lives in localStorage (client-only, see use-dashboard-mode.ts),
 * so we have to gate render on the client. During SSR / first paint, nothing
 * is rendered — matches the permanence rule's default ('consumer' on first
 * visit). Users who've toggled to Advanced get the columns after hydration.
 */

import { useDashboardMode } from '@/hooks/use-dashboard-mode'

export default function OfficerColumnsGated({
  children,
}: {
  children: React.ReactNode
}) {
  const [mode] = useDashboardMode()
  if (mode !== 'advanced') return null
  return <>{children}</>
}
