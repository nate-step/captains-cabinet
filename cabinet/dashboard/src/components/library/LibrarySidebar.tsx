/**
 * LibrarySidebar — Spec 037 A4 (server component)
 *
 * Renders the persistent left-navigation tree for all /library/* routes.
 * Data is fetched at the parent layout level and passed in as props — no
 * client-side waterfall. Two usage modes:
 *   - desktop: wrapped in SidebarShell (collapsible, sticky column)
 *   - mobile:  wrapped in LibraryDrawer (sheet that slides in from left)
 */

import Link from 'next/link'
import type { LibrarySpace, SidebarRecord } from '@/lib/library'
import { SidebarShell, LibraryDrawer } from './LibrarySidebarClient'

export interface SidebarSpaceData {
  space: LibrarySpace
  records: SidebarRecord[]
  totalCount: number
}

interface Props {
  spaces: SidebarSpaceData[]
  /** When true, wraps content in the mobile drawer shell instead of the desktop shell. */
  mobile?: boolean
}

function SidebarTree({ spaces }: { spaces: SidebarSpaceData[] }) {
  return (
    <nav aria-label="Library" className="flex flex-col gap-1 px-1 pb-4">
      {/* Library index link */}
      <Link
        href="/library"
        data-sidebar-record-link
        className="flex items-center gap-2 rounded-md px-2 py-1.5 text-xs font-semibold uppercase tracking-wider text-zinc-500 transition-colors hover:bg-zinc-800/50 hover:text-zinc-300"
      >
        All Spaces
      </Link>

      {spaces.length === 0 && (
        <p className="px-2 py-2 text-xs text-zinc-700">No spaces yet</p>
      )}

      {spaces.map(({ space, records, totalCount }) => {
        const extraCount = totalCount - records.length
        return (
          <details key={space.id} className="group">
            <summary className="flex cursor-pointer list-none items-center gap-1.5 rounded-md px-2 py-1.5 text-sm font-medium text-zinc-400 transition-colors hover:bg-zinc-800/50 hover:text-zinc-200 [&::-webkit-details-marker]:hidden">
              {/* Disclosure chevron */}
              <svg
                className="h-3 w-3 shrink-0 rotate-0 text-zinc-600 transition-transform group-open:rotate-90"
                fill="none"
                viewBox="0 0 24 24"
                strokeWidth={2.5}
                stroke="currentColor"
                aria-hidden="true"
              >
                <path strokeLinecap="round" strokeLinejoin="round" d="M8.25 4.5l7.5 7.5-7.5 7.5" />
              </svg>
              <span className="truncate">{space.name}</span>
              <span className="ml-auto shrink-0 text-xs text-zinc-700">{totalCount}</span>
            </summary>

            {/* Record list — visible when <details> is open */}
            <div className="ml-3 mt-0.5 flex flex-col gap-px border-l border-zinc-800 pl-2">
              {records.map((record) => (
                <Link
                  key={record.id}
                  href={`/library/${space.id}/${record.id}`}
                  data-sidebar-record-link
                  className="truncate rounded-md px-2 py-1 text-xs text-zinc-400 transition-colors hover:bg-zinc-800/50 hover:text-zinc-200"
                >
                  {record.title}
                </Link>
              ))}

              {extraCount > 0 && (
                <Link
                  href={`/library/${space.id}`}
                  className="rounded-md px-2 py-1 text-xs text-zinc-600 transition-colors hover:text-zinc-400"
                >
                  …{extraCount} more
                </Link>
              )}

              {records.length === 0 && (
                <p className="px-2 py-1 text-xs text-zinc-700">Empty</p>
              )}
            </div>
          </details>
        )
      })}
    </nav>
  )
}

export default function LibrarySidebar({ spaces, mobile = false }: Props) {
  if (mobile) {
    return (
      <LibraryDrawer>
        <SidebarTree spaces={spaces} />
      </LibraryDrawer>
    )
  }

  return (
    <SidebarShell>
      <SidebarTree spaces={spaces} />
    </SidebarShell>
  )
}
