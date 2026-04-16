import Link from 'next/link'
import { listSpaces } from '@/lib/library'
import CreateSpaceForm from './create-space-form'

export const dynamic = 'force-dynamic'

function formatRelative(isoTs: string | null): string {
  if (!isoTs) return 'never'
  const diffMs = Date.now() - new Date(isoTs).getTime()
  const diffMin = Math.floor(diffMs / 60_000)
  if (diffMin < 1) return 'just now'
  if (diffMin < 60) return `${diffMin}m ago`
  const diffHr = Math.floor(diffMin / 60)
  if (diffHr < 24) return `${diffHr}h ago`
  const diffDay = Math.floor(diffHr / 24)
  return `${diffDay}d ago`
}

export default async function LibraryPage() {
  let spaces
  try {
    spaces = await listSpaces()
  } catch {
    spaces = null
  }

  return (
    <div className="flex flex-col gap-8">
      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Library</h1>
          <p className="mt-1 text-sm text-zinc-500">
            Structured knowledge spaces — editable by Captain and Officers
          </p>
        </div>
        <CreateSpaceForm />
      </div>

      {/* Error state */}
      {spaces === null && (
        <div className="rounded-xl border border-red-900/50 bg-red-950/20 p-6 text-center">
          <p className="text-sm text-red-400">
            Could not connect to the database. Check NEON_CONNECTION_STRING.
          </p>
        </div>
      )}

      {/* Empty state */}
      {spaces !== null && spaces.length === 0 && (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-12 text-center">
          <p className="text-zinc-500">No spaces yet.</p>
          <p className="mt-1 text-sm text-zinc-600">
            Create your first space using the button above.
          </p>
        </div>
      )}

      {/* Space cards grid */}
      {spaces && spaces.length > 0 && (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {spaces.map((space) => (
            <Link
              key={space.id}
              href={`/library/${space.id}`}
              className="group block rounded-xl border border-zinc-800 bg-zinc-900 p-6 transition-colors hover:border-zinc-700 hover:bg-zinc-800/50"
            >
              {/* Space name */}
              <div className="flex items-start justify-between gap-2">
                <h2 className="text-base font-semibold text-white group-hover:text-zinc-100">
                  {space.name}
                </h2>
                {space.starter_template && space.starter_template !== 'blank' && (
                  <span className="mt-0.5 shrink-0 rounded bg-zinc-800 px-2 py-0.5 text-xs text-zinc-500">
                    {space.starter_template}
                  </span>
                )}
              </div>

              {/* Description */}
              {space.description && (
                <p className="mt-2 text-sm text-zinc-500 line-clamp-2">
                  {space.description}
                </p>
              )}

              {/* Stats row */}
              <div className="mt-4 flex items-center gap-4 text-xs text-zinc-600">
                <span>
                  <span className="font-semibold text-zinc-400">{space.record_count}</span>{' '}
                  {space.record_count === 1 ? 'record' : 'records'}
                </span>
                <span className="text-zinc-700">·</span>
                <span>
                  updated{' '}
                  <span className="text-zinc-400">
                    {formatRelative(space.latest_update ?? space.updated_at)}
                  </span>
                </span>
              </div>

              {/* Owner chip */}
              {space.owner && (
                <div className="mt-3 text-xs text-zinc-700">
                  owner: <span className="text-zinc-500">{space.owner}</span>
                </div>
              )}
            </Link>
          ))}
        </div>
      )}
    </div>
  )
}
