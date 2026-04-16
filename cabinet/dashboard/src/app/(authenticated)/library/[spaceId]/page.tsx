import Link from 'next/link'
import { notFound } from 'next/navigation'
import { getSpace, listRecords } from '@/lib/library'
import CreateRecordForm from './create-record-form'
import SearchBox from './search-box'

export const dynamic = 'force-dynamic'

function formatRelative(isoTs: string | null): string {
  if (!isoTs) return '—'
  const diffMs = Date.now() - new Date(isoTs).getTime()
  const diffMin = Math.floor(diffMs / 60_000)
  if (diffMin < 1) return 'just now'
  if (diffMin < 60) return `${diffMin}m ago`
  const diffHr = Math.floor(diffMin / 60)
  if (diffHr < 24) return `${diffHr}h ago`
  const diffDay = Math.floor(diffHr / 24)
  return `${diffDay}d ago`
}

function formatTs(isoTs: string): string {
  return new Date(isoTs).toLocaleDateString('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
  })
}

interface Props {
  params: Promise<{ spaceId: string }>
  searchParams: Promise<{ page?: string; labels?: string }>
}

export default async function SpacePage({ params, searchParams }: Props) {
  const { spaceId } = await params
  const { page: pageStr, labels: labelsParam } = await searchParams
  const page = Math.max(1, Number(pageStr ?? '1'))
  const limit = 25
  const offset = (page - 1) * limit
  const filterLabels = labelsParam
    ? labelsParam.split(',').map((l) => l.trim()).filter(Boolean)
    : undefined

  const [space, records] = await Promise.all([
    getSpace(spaceId),
    listRecords(spaceId, { limit, offset, labels: filterLabels }),
  ])

  if (!space) notFound()

  const hasMore = records.length === limit

  return (
    <div className="flex flex-col gap-8">
      {/* Breadcrumb */}
      <div className="flex items-center gap-2 text-sm text-zinc-600">
        <Link href="/library" className="hover:text-zinc-400 transition-colors">Library</Link>
        <span>/</span>
        <span className="text-zinc-400">{space.name}</span>
      </div>

      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">{space.name}</h1>
          {space.description && (
            <p className="mt-1 text-sm text-zinc-500 max-w-xl">{space.description}</p>
          )}
          <div className="mt-2 flex items-center gap-3 text-xs text-zinc-600">
            <span>
              <span className="font-semibold text-zinc-400">{space.record_count}</span>{' '}
              {space.record_count === 1 ? 'record' : 'records'}
            </span>
            {space.owner && (
              <>
                <span className="text-zinc-700">·</span>
                <span>owner: <span className="text-zinc-500">{space.owner}</span></span>
              </>
            )}
            {space.starter_template && space.starter_template !== 'blank' && (
              <>
                <span className="text-zinc-700">·</span>
                <span className="rounded bg-zinc-800 px-2 py-0.5 text-zinc-500">
                  {space.starter_template}
                </span>
              </>
            )}
          </div>
        </div>
        <CreateRecordForm spaceId={spaceId} />
      </div>

      {/* Schema hint */}
      {space.schema_json && Object.keys(space.schema_json).length > 0 && (
        <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 px-4 py-3">
          <p className="text-xs font-medium text-zinc-500 mb-1">Schema</p>
          <pre className="text-xs text-zinc-400 overflow-x-auto">
            {JSON.stringify(space.schema_json, null, 2)}
          </pre>
        </div>
      )}

      {/* Search */}
      <SearchBox spaceId={spaceId} />

      {/* Records list */}
      <div>
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-sm font-medium text-zinc-400">
            Records
            {filterLabels && filterLabels.length > 0 && (
              <span className="ml-2 text-zinc-600">
                filtered by: {filterLabels.join(', ')}
              </span>
            )}
          </h2>
        </div>

        {records.length === 0 ? (
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-12 text-center">
            <p className="text-zinc-500">
              {filterLabels ? 'No records match this filter.' : 'No records yet.'}
            </p>
            <p className="mt-1 text-sm text-zinc-600">
              {!filterLabels && 'Create your first record using the button above.'}
            </p>
          </div>
        ) : (
          <div className="flex flex-col divide-y divide-zinc-800 rounded-xl border border-zinc-800 bg-zinc-900 overflow-hidden">
            {records.map((record) => (
              <Link
                key={record.id}
                href={`/library/${spaceId}/${record.id}`}
                className="group flex flex-col gap-1.5 px-5 py-4 hover:bg-zinc-800/50 transition-colors sm:flex-row sm:items-start sm:justify-between"
              >
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium text-white group-hover:text-zinc-100 truncate">
                    {record.title}
                  </p>
                  {record.preview && (
                    <p className="mt-0.5 text-xs text-zinc-600 truncate">{record.preview}</p>
                  )}
                  {record.labels && record.labels.length > 0 && (
                    <div className="mt-1.5 flex flex-wrap gap-1">
                      {record.labels.map((label) => (
                        <span
                          key={label}
                          className="rounded bg-zinc-800 px-2 py-0.5 text-xs text-zinc-500"
                        >
                          {label}
                        </span>
                      ))}
                    </div>
                  )}
                </div>
                <div className="flex shrink-0 items-center gap-3 text-xs text-zinc-600 sm:flex-col sm:items-end sm:gap-1">
                  <span className="text-zinc-500">{formatTs(record.created_at)}</span>
                  <span>{formatRelative(record.updated_at)}</span>
                  {record.created_by_officer && (
                    <span className="text-zinc-700">{record.created_by_officer}</span>
                  )}
                  <span className="rounded bg-zinc-800/50 px-1.5 py-0.5 text-zinc-700">
                    v{record.version}
                  </span>
                </div>
              </Link>
            ))}
          </div>
        )}

        {/* Pagination */}
        {(page > 1 || hasMore) && (
          <div className="mt-4 flex items-center justify-between">
            {page > 1 ? (
              <Link
                href={`/library/${spaceId}?page=${page - 1}${labelsParam ? `&labels=${labelsParam}` : ''}`}
                className="rounded-lg border border-zinc-700 px-3 py-1.5 text-sm text-zinc-400 hover:bg-zinc-800 transition-colors"
              >
                Previous
              </Link>
            ) : <div />}
            <span className="text-xs text-zinc-600">Page {page}</span>
            {hasMore ? (
              <Link
                href={`/library/${spaceId}?page=${page + 1}${labelsParam ? `&labels=${labelsParam}` : ''}`}
                className="rounded-lg border border-zinc-700 px-3 py-1.5 text-sm text-zinc-400 hover:bg-zinc-800 transition-colors"
              >
                Next
              </Link>
            ) : <div />}
          </div>
        )}
      </div>
    </div>
  )
}
