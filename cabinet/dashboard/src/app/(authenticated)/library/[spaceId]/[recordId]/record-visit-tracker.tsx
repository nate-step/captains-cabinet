'use client'

/**
 * RecordVisitTracker — Spec 037 A3 (recents)
 *
 * Tiny client island mounted inside the server RecordPage.
 * On mount, pushes the current record into localStorage so the command palette
 * can show "Recent records" in the empty state.
 *
 * No props validation needed — callers pass server-derived data.
 */

import { useEffect } from 'react'
import { pushRecentRecord } from '@/components/library/CommandPalette'

interface Props {
  id: string
  title: string
  spaceId: string
  spaceName: string
}

export default function RecordVisitTracker({ id, title, spaceId, spaceName }: Props) {
  useEffect(() => {
    pushRecentRecord({ id, title, spaceId, spaceName })
  }, [id, title, spaceId, spaceName])

  return null
}
