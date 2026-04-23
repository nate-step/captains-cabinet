import Link from 'next/link'
import { notFound } from 'next/navigation'
import { getRecord, getSpace, getRecordHistory } from '@/lib/library'
import RecordEditor from './record-editor'
import RecordVisitTracker from './record-visit-tracker'
import RenderedContent from '@/components/library/RenderedContent'
import StatusBadge from '@/components/library/StatusBadge'
import type { SchemaJson } from './schema-fields'

export const dynamic = 'force-dynamic'

function formatTs(isoTs: string): string {
  return new Date(isoTs).toLocaleString('en-US', {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

interface Props {
  params: Promise<{ spaceId: string; recordId: string }>
}

export default async function RecordPage({ params }: Props) {
  const { spaceId, recordId } = await params

  const [record, space, history] = await Promise.all([
    getRecord(recordId),
    getSpace(spaceId),
    getRecordHistory(recordId),
  ])

  if (!record || !space) notFound()

  return (
    <div className="flex flex-col gap-6">
      {/* Track visit for command palette recents — client island, renders nothing */}
      <RecordVisitTracker
        id={recordId}
        title={record.title}
        spaceId={spaceId}
        spaceName={space.name}
      />

      {/* Breadcrumb */}
      <div className="flex items-center gap-2 text-sm text-zinc-600">
        <Link href="/library" className="hover:text-zinc-400 transition-colors">Library</Link>
        <span>/</span>
        <Link href={`/library/${spaceId}`} className="hover:text-zinc-400 transition-colors">
          {space.name}
        </Link>
        <span>/</span>
        <span className="text-zinc-400 truncate max-w-[200px]">{record.title}</span>
      </div>

      {/* Metadata bar */}
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-zinc-600">
        {/* A5 status badge — Q5 palette applied in StatusBadge component */}
        <StatusBadge status={record.status} recordId={recordId} />
        <span>
          <span className="text-zinc-500">version</span>{' '}
          <span className="font-semibold text-zinc-400">v{record.version}</span>
        </span>
        {record.created_by_officer && (
          <span>
            <span className="text-zinc-500">by</span>{' '}
            <span className="text-zinc-400">{record.created_by_officer}</span>
          </span>
        )}
        <span>
          <span className="text-zinc-500">created</span>{' '}
          <span className="text-zinc-400">{formatTs(record.created_at)}</span>
        </span>
        <span>
          <span className="text-zinc-500">updated</span>{' '}
          <span className="text-zinc-400">{formatTs(record.updated_at)}</span>
        </span>
        {record.superseded_by !== null && record.superseded_by !== record.id && (
          <span className="rounded bg-amber-900/30 px-2 py-0.5 text-amber-500">
            Archived version
          </span>
        )}
        {record.superseded_by === record.id && (
          <span className="rounded bg-red-900/30 px-2 py-0.5 text-red-500">
            Deleted
          </span>
        )}
      </div>

      {/* Rendered content — wikilinks resolved + Q2 hovercard + Q4 dashed-dim */}
      {record.content_markdown && (
        <section aria-label="Record content">
          <RenderedContent
            markdown={record.content_markdown}
            spaceId={spaceId}
            className="rounded-xl border border-zinc-800 bg-zinc-900/50 px-5 py-4"
          />
        </section>
      )}

      {/* Editor — client component handles save */}
      <RecordEditor
        recordId={recordId}
        spaceId={spaceId}
        initialTitle={record.title}
        initialContent={record.content_markdown}
        initialLabels={record.labels}
        initialSchemaData={record.schema_data}
        schemaJson={space.schema_json as SchemaJson}
        isDeleted={record.superseded_by === record.id}
        isArchived={
          record.superseded_by !== null && record.superseded_by !== record.id
        }
      />

      {/* Version history */}
      {history.length > 1 && (
        <div>
          <h2 className="mb-3 text-sm font-medium text-zinc-400">Version History</h2>
          <div className="rounded-xl border border-zinc-800 bg-zinc-900 overflow-hidden">
            {history.map((v) => (
              <div
                key={v.id}
                className="flex items-center justify-between border-b border-zinc-800 px-4 py-3 last:border-0"
              >
                <div className="flex items-center gap-3">
                  <span className="text-xs font-mono text-zinc-500">v{v.version}</span>
                  <span className="text-sm text-zinc-400">{v.title}</span>
                  {v.is_active && (
                    <span className="rounded bg-green-900/30 px-2 py-0.5 text-xs text-green-500">
                      current
                    </span>
                  )}
                </div>
                <div className="flex items-center gap-3">
                  <span className="text-xs text-zinc-600">{v.created_at}</span>
                  {!v.is_active && (
                    <Link
                      href={`/library/${spaceId}/${v.id}`}
                      className="text-xs text-zinc-500 hover:text-zinc-300 transition-colors"
                    >
                      view
                    </Link>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  )
}
