import Link from 'next/link'
import { getBacklinks, type BacklinkEntry } from '@/lib/wikilinks'

// Spec 045 Phase 1 — server component rendered below the record content
// section. Loads backlinks for the current record id directly from the DB
// (already under SSR data-loading on this route; one extra query is cheap).
//
// "No backlinks yet" surface is intentional — many records have zero
// inbound links until the linking pattern compounds across the corpus.
// Captain msg 1996 ratified the build; the empty state is the honest
// answer until density grows.

interface Props {
  recordId: string
}

export default async function BacklinksPanel({ recordId }: Props) {
  let backlinks: BacklinkEntry[] = []
  try {
    backlinks = await getBacklinks(recordId)
  } catch (err) {
    console.warn('[library] BacklinksPanel — getBacklinks failed', err)
    return null // fail-closed: don't render anything if the query errored
  }

  if (backlinks.length === 0) {
    return (
      <section aria-label="Backlinks" className="rounded-xl border border-zinc-800 bg-zinc-900/30 px-5 py-4">
        <h2 className="text-sm font-medium text-zinc-400">Linked from</h2>
        <p className="mt-2 text-xs text-zinc-600">No backlinks yet.</p>
      </section>
    )
  }

  // Group by source space for cleaner reading.
  const grouped = new Map<string, { spaceName: string; entries: BacklinkEntry[] }>()
  for (const b of backlinks) {
    const key = b.source_space_id
    const bucket = grouped.get(key) ?? { spaceName: b.source_space_name, entries: [] }
    bucket.entries.push(b)
    grouped.set(key, bucket)
  }

  return (
    <section aria-label="Backlinks" className="rounded-xl border border-zinc-800 bg-zinc-900/30 px-5 py-4">
      <h2 className="mb-3 text-sm font-medium text-zinc-400">
        Linked from <span className="text-xs text-zinc-600">({backlinks.length})</span>
      </h2>
      <div className="flex flex-col gap-4">
        {[...grouped.entries()].map(([spaceId, { spaceName, entries }]) => (
          <div key={spaceId}>
            <div className="mb-1 text-xs uppercase tracking-wide text-zinc-600">{spaceName}</div>
            <ul className="flex flex-col gap-2">
              {entries.map((b, i) => (
                <li key={`${b.source_record_id}:${b.link_position}:${i}`} className="text-sm">
                  <Link
                    href={`/library/${b.source_space_id}/${b.source_record_id}`}
                    className="text-zinc-300 hover:text-zinc-100 transition-colors"
                  >
                    {b.source_title}
                  </Link>
                  {b.link_context && (
                    <p className="mt-0.5 line-clamp-1 text-xs text-zinc-600">{b.link_context}</p>
                  )}
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>
    </section>
  )
}
