/**
 * Card 4: YOUR LIBRARY — Spec 032 Consumer Mode.
 *
 * Shows search box (client component) + recent 3 library modifications.
 * Search hits /api/library/search (which exists — verified in route.ts).
 * Search is client-only for PR 2; no server roundtrip refinements.
 *
 * Server component (with client SearchBox inlined as a client boundary).
 */

import Link from 'next/link'
import { query } from '@/lib/db'
import LibrarySearchBox from './library-search-box'

interface RecentRecord extends Record<string, unknown> {
  id: string
  title: string
  space_id: string
  updated_at: string
}

async function getRecentLibraryItems(): Promise<RecentRecord[]> {
  // Gracefully handle missing NEON_CONNECTION_STRING (build-time / dev without DB)
  if (!process.env.NEON_CONNECTION_STRING) return []
  try {
    const rows = await query<RecentRecord>(
      `SELECT id::text, title, space_id::text, updated_at::text
       FROM library_records
       WHERE superseded_by IS NULL
       ORDER BY updated_at DESC
       LIMIT 3`
    )
    return rows
  } catch {
    return []
  }
}

function relativeTime(iso: string): string {
  const diffMs = Date.now() - new Date(iso).getTime()
  const mins = Math.round(diffMs / 60000)
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.round(diffMs / 3600000)
  if (hrs < 24) return `${hrs}h ago`
  return `${Math.round(hrs / 24)}d ago`
}

export default async function CardLibrary() {
  const recent = await getRecentLibraryItems()

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
      <div className="mb-4">
        <h2 className="text-xs font-semibold uppercase tracking-widest text-zinc-500">
          Your Library
        </h2>
      </div>

      {/* Search box — client boundary */}
      <LibrarySearchBox />

      {/* Recent items */}
      <div className="mt-4">
        <p className="mb-2 text-xs font-medium uppercase tracking-wide text-zinc-600">Recent</p>
        {recent.length === 0 ? (
          <p className="text-sm text-zinc-500">No library entries yet.</p>
        ) : (
          <ul className="space-y-1.5">
            {recent.map((item) => (
              <li key={item.id}>
                <Link
                  href={`/library/${item.space_id}/${item.id}`}
                  className="group flex items-start gap-1.5 text-sm text-zinc-400 transition-colors hover:text-zinc-200"
                >
                  <span className="mt-1 shrink-0 text-xs text-zinc-600">&middot;</span>
                  <span className="flex-1 truncate">{item.title}</span>
                  <span className="shrink-0 text-xs text-zinc-600">
                    {relativeTime(item.updated_at)}
                  </span>
                </Link>
              </li>
            ))}
          </ul>
        )}
      </div>

      {/* Browse link */}
      <div className="mt-3 border-t border-zinc-800 pt-3">
        <Link
          href="/library"
          className="inline-flex items-center gap-1 text-xs text-zinc-500 transition-colors hover:text-zinc-300"
        >
          Browse spaces &rarr;
        </Link>
      </div>
    </div>
  )
}
