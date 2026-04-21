/**
 * Card 3: YOUR TASKS — Spec 038 Phase A (folds in Spec 032 + Spec 039).
 *
 * Shows Captain's founder-action items grouped by state (in flight / blocked /
 * queued) with preview of most recent items. Pulls from the same Linear query
 * as the /tasks Captain column (`getLinearFounderActions`), so frontpage card
 * and /tasks view stay in sync.
 *
 * Server component. Gracefully renders an empty state when LINEAR_API_KEY is
 * absent or no founder-action issues exist.
 */

import Link from 'next/link'
import { getLinearFounderActions } from '@/lib/linear-tasks'

function relativeTime(iso: string): string {
  const diffMs = Date.now() - new Date(iso).getTime()
  const mins = Math.round(diffMs / 60000)
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.round(diffMs / 3600000)
  if (hrs < 24) return `${hrs}h ago`
  return `${Math.round(hrs / 24)}d ago`
}

export default async function CardTasks() {
  const board = await getLinearFounderActions()

  const wipCount = board.wip.length
  const blockedCount = board.blocked.length
  const queueCount = board.queue.length
  const total = wipCount + blockedCount + queueCount

  // Most recent across all active buckets — up to 3
  const recent = [...board.wip, ...board.blocked, ...board.queue]
    .sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime())
    .slice(0, 3)

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-xs font-semibold uppercase tracking-widest text-zinc-500">
          Your Tasks
        </h2>
      </div>

      {!board.configured ? (
        /* No backlog provider configured (spec §7) */
        <div className="py-2">
          <p className="text-sm text-amber-400">
            ⚠ No task backlog configured. Connect Linear or set provider: none.
          </p>
          <a
            href="/settings"
            className="mt-1 inline-flex items-center gap-1 text-xs text-zinc-500 transition-colors hover:text-zinc-300"
          >
            Configure backlog &rarr;
          </a>
        </div>
      ) : total === 0 ? (
        <p className="py-2 text-sm text-zinc-400">Nothing on your plate.</p>
      ) : (
        <>
          {/* Count summary line per Spec 038 §4.5 */}
          <div className="mb-4 flex flex-wrap items-baseline gap-x-3 gap-y-1 text-sm">
            <span className="text-zinc-300">
              <span className="font-bold text-white">{wipCount}</span>
              <span className="ml-1 text-zinc-500">in flight</span>
            </span>
            <span className="text-zinc-600">·</span>
            <span className={blockedCount > 0 ? 'text-red-400' : 'text-zinc-300'}>
              <span className="font-bold">{blockedCount}</span>
              <span className="ml-1 text-zinc-500">blocked</span>
            </span>
            <span className="text-zinc-600">·</span>
            <span className="text-zinc-300">
              <span className="font-bold text-white">{queueCount}</span>
              <span className="ml-1 text-zinc-500">queued</span>
            </span>
          </div>

          {/* Recent items */}
          {recent.length > 0 && (
            <div className="border-t border-zinc-800 pt-4">
              <p className="mb-2 text-xs font-medium uppercase tracking-wide text-zinc-600">
                Recent
              </p>
              <ul className="space-y-1.5">
                {recent.map((item) => (
                  <li key={item.id}>
                    <a
                      href={item.url}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="group flex items-start gap-1.5 text-sm text-zinc-400 transition-colors hover:text-zinc-200"
                    >
                      <span className="mt-1 shrink-0 text-xs text-zinc-600">&middot;</span>
                      <span className="flex-1 truncate">{item.title}</span>
                      <span className="shrink-0 text-xs text-zinc-600">
                        {relativeTime(item.updatedAt)}
                      </span>
                    </a>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </>
      )}

      {/* Spec 038 §4.5 CTA — always shown if configured */}
      {board.configured && (
        <div className="mt-3 border-t border-zinc-800 pt-3">
          <Link
            href="/tasks"
            className="inline-flex items-center gap-1 text-xs text-zinc-500 transition-colors hover:text-zinc-300"
          >
            See tasks &rarr;
          </Link>
        </div>
      )}
    </div>
  )
}
