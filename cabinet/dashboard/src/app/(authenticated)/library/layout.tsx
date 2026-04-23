/**
 * Library layout — Spec 037 A4 (server component)
 *
 * Wraps all /library/* routes with the left sidebar navigation.
 * Single RSC fetch: listSpaces() + listRecordsForSidebar() per space in parallel.
 * No client-side waterfall — data flows synchronously into LibrarySidebar.
 *
 * Desktop: sticky sidebar column rendered by SidebarShell (collapsible, localStorage).
 * Mobile:  drawer sheet triggered by LibraryDrawer button above the content area.
 */

import type { ReactNode } from 'react'
import LibrarySidebar, { type SidebarSpaceData } from '@/components/library/LibrarySidebar'
import { listSpaces, listRecordsForSidebar, type SidebarRecord } from '@/lib/library'

const SIDEBAR_RECORD_LIMIT = 20

async function loadSidebarData(): Promise<SidebarSpaceData[]> {
  let spaces
  try {
    spaces = await listSpaces()
  } catch {
    return []
  }

  const perSpace = await Promise.all(
    spaces.map(async (space) => {
      let records: SidebarRecord[]
      try {
        records = await listRecordsForSidebar(space.id, { limit: SIDEBAR_RECORD_LIMIT })
      } catch {
        records = []
      }
      return {
        space,
        records,
        totalCount: typeof space.record_count === 'number' ? space.record_count : 0,
      }
    })
  )

  return perSpace
}

export default async function LibraryLayout({
  children,
}: {
  children: ReactNode
}) {
  const sidebarData = await loadSidebarData()

  return (
    <div className="flex min-h-0 gap-4">
      {/* Desktop sidebar — sticky column, independent scroll */}
      <aside
        className="hidden shrink-0 md:block"
        style={{
          position: 'sticky',
          top: '1rem',
          maxHeight: 'calc(100vh - 3.5rem)',
          overflowY: 'auto',
        }}
      >
        <LibrarySidebar spaces={sidebarData} />
      </aside>

      {/* Main content — mobile drawer trigger floats above page content */}
      <div className="min-w-0 flex-1">
        {/* Mobile-only drawer — renders button + sheet; invisible on md+ */}
        <LibrarySidebar spaces={sidebarData} mobile />
        {children}
      </div>
    </div>
  )
}
