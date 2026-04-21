/**
 * TaskCard — renders a single officer_tasks row.
 *
 * Spec 038 v1.1 §4.2:
 * - Title truncated at 80 chars
 * - Linked badge (Linear / GH / Library / Spec)
 * - WIP: "started Xh ago"; chain icon overlay if blocked=true
 * - Blocked overlay: chain icon + blocked_reason as subtitle (still status='wip')
 * - Done: "done Apr 16"
 * - Queue: no timestamp
 */

import { OfficerTask } from '@/lib/tasks'

function relativeTime(isoStr: string | null): string {
  if (!isoStr) return ''
  const diffMs = Date.now() - new Date(isoStr).getTime()
  const mins = Math.round(diffMs / 60000)
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.round(diffMs / 3600000)
  if (hrs < 24) return `${hrs}h ago`
  return `${Math.round(hrs / 24)}d ago`
}

function formatDate(isoStr: string | null): string {
  if (!isoStr) return ''
  return new Date(isoStr).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })
}

function truncate(str: string, max = 80): string {
  if (str.length <= max) return str
  return str.slice(0, max - 1) + '…'
}

interface LinkedBadgeProps {
  kind: string | null
  id: string | null
  url: string | null
}

function LinkedBadge({ kind, id, url }: LinkedBadgeProps) {
  if (!kind && !id) return null

  const label = id ?? kind ?? 'link'
  const colorClass =
    kind === 'linear'
      ? 'bg-purple-900/50 text-purple-300 border-purple-700/50'
      : kind === 'github'
        ? 'bg-zinc-800 text-zinc-300 border-zinc-700'
        : kind === 'library'
          ? 'bg-blue-900/50 text-blue-300 border-blue-700/50'
          : 'bg-zinc-800 text-zinc-400 border-zinc-700'

  const inner = (
    <span
      className={`inline-flex items-center rounded border px-1.5 py-0.5 text-xs font-mono ${colorClass}`}
    >
      {label}
    </span>
  )

  if (url) {
    return (
      <a href={url} target="_blank" rel="noopener noreferrer" className="hover:opacity-80">
        {inner}
      </a>
    )
  }
  return inner
}

interface TaskCardProps {
  task: OfficerTask
}

export function TaskCard({ task }: TaskCardProps) {
  const titleDisplay = truncate(task.title)
  const hasTooltip = task.title.length > 80
  const isBlockedOverlay = task.status === 'wip' && task.blocked === true

  // Amber left-border when blocked overlay is on; subtle default otherwise
  const borderClass = isBlockedOverlay
    ? 'border border-zinc-800 border-l-2 border-l-amber-500/70'
    : 'border border-zinc-800'

  const cardContent = (
    <div className={`rounded-lg ${borderClass} bg-zinc-850 p-3 transition-colors hover:border-zinc-700`}>
      {/* Header row: chain icon (if blocked) + title */}
      <div className="flex items-start gap-1.5">
        {isBlockedOverlay && (
          <span
            aria-label="blocked"
            title="Blocked"
            className="mt-0.5 text-amber-400 text-xs shrink-0"
          >
            ⛓
          </span>
        )}
        <p
          className="text-sm font-medium text-zinc-200 leading-snug flex-1"
          title={hasTooltip ? task.title : undefined}
        >
          {titleDisplay}
        </p>
      </div>

      {/* Linked badge */}
      {(task.linked_id || task.linked_kind) && (
        <div className="mt-1.5">
          <LinkedBadge kind={task.linked_kind} id={task.linked_id} url={task.linked_url} />
        </div>
      )}

      {/* Blocked reason (shown whenever blocked=true, regardless of status) */}
      {isBlockedOverlay && task.blocked_reason && (
        <p className="mt-1.5 text-xs text-amber-400 leading-snug">{task.blocked_reason}</p>
      )}

      {/* Timestamps */}
      <div className="mt-1.5 flex items-center justify-between">
        {task.status === 'wip' && task.started_at && (
          <span className="text-xs text-zinc-500">started {relativeTime(task.started_at)}</span>
        )}
        {task.status === 'done' && task.completed_at && (
          <span className="text-xs text-zinc-500">done {formatDate(task.completed_at)}</span>
        )}
        {task.status === 'queue' && <span />}
      </div>
    </div>
  )

  // If there's a linked URL but no badge surface, make the whole card clickable
  if (task.linked_url && !task.linked_id && !task.linked_kind) {
    return (
      <a href={task.linked_url} target="_blank" rel="noopener noreferrer" className="block">
        {cardContent}
      </a>
    )
  }

  return cardContent
}
