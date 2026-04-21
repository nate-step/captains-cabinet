/**
 * TaskCard — renders a single officer_tasks row.
 *
 * Spec 038 §4.2:
 * - Title truncated at 80 chars
 * - Linked badge (Linear / GH / Library / Spec)
 * - WIP: "started Xh ago"
 * - Blocked: blocked_reason as subtitle
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

  const cardContent = (
    <div className="rounded-lg border border-zinc-800 bg-zinc-850 p-3 transition-colors hover:border-zinc-700">
      {/* Title */}
      <p
        className="text-sm font-medium text-zinc-200 leading-snug"
        title={hasTooltip ? task.title : undefined}
      >
        {titleDisplay}
      </p>

      {/* Linked badge */}
      {(task.linked_id || task.linked_kind) && (
        <div className="mt-1.5">
          <LinkedBadge kind={task.linked_kind} id={task.linked_id} url={task.linked_url} />
        </div>
      )}

      {/* Blocked reason */}
      {task.status === 'blocked' && task.blocked_reason && (
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
        {(task.status === 'queue' || task.status === 'blocked') && <span />}
      </div>
    </div>
  )

  // If there's a linked URL, wrap the whole card (but not the badge itself, to avoid double-link)
  if (task.linked_url && !task.linked_id && !task.linked_kind) {
    return (
      <a href={task.linked_url} target="_blank" rel="noopener noreferrer" className="block">
        {cardContent}
      </a>
    )
  }

  return cardContent
}
