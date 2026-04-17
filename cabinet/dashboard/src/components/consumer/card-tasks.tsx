/**
 * Card 3: YOUR TASKS — Spec 032 Consumer Mode.
 *
 * Shows in-progress / next-up / blocked counts + last 3 recent state changes.
 * Uses LINEAR_API_KEY from env. Gracefully renders "No task backlog configured"
 * when LINEAR_API_KEY is absent (spec §7 AC #16).
 *
 * Server component.
 */

import Link from 'next/link'
import { getLinearTasks } from '@/lib/linear'

function relativeTime(iso: string): string {
  const diffMs = Date.now() - new Date(iso).getTime()
  const mins = Math.round(diffMs / 60000)
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.round(diffMs / 3600000)
  if (hrs < 24) return `${hrs}h ago`
  return `${Math.round(hrs / 24)}d ago`
}

export default async function CardTasks() {
  const tasks = await getLinearTasks()

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-xs font-semibold uppercase tracking-widest text-zinc-500">
          Your Tasks
        </h2>
        {tasks.configured && (
          <span className="text-xs text-zinc-600">Linear</span>
        )}
      </div>

      {!tasks.configured ? (
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
      ) : tasks.inProgress === 0 && tasks.todo === 0 && tasks.blocked === 0 ? (
        /* Configured but empty (spec §7 "No tasks + backlog.provider configured") */
        <p className="py-2 text-sm text-zinc-400">No tasks right now.</p>
      ) : (
        <>
          {/* Count rows */}
          <div className="mb-4 space-y-2">
            <div className="flex items-center justify-between">
              <span className="flex items-center gap-2 text-sm text-zinc-300">
                <span className="text-blue-400">🔵</span>
                <span className="font-medium uppercase tracking-wide text-xs">In Progress</span>
              </span>
              <span className="text-lg font-bold text-white">{tasks.inProgress}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="flex items-center gap-2 text-sm text-zinc-300">
                <span className="text-zinc-400">⚪</span>
                <span className="font-medium uppercase tracking-wide text-xs">Next Up</span>
              </span>
              <span className="text-lg font-bold text-white">{tasks.todo}</span>
            </div>
            {tasks.blocked > 0 && (
              <div className="flex items-center justify-between">
                <span className="flex items-center gap-2 text-sm text-zinc-300">
                  <span className="text-red-400">🔴</span>
                  <span className="font-medium uppercase tracking-wide text-xs">Blocked</span>
                </span>
                <span className="text-lg font-bold text-red-400">{tasks.blocked}</span>
              </div>
            )}
          </div>

          {/* Recent items */}
          {tasks.recent.length > 0 && (
            <div className="border-t border-zinc-800 pt-4">
              <p className="mb-2 text-xs font-medium uppercase tracking-wide text-zinc-600">
                Recent
              </p>
              <ul className="space-y-1.5">
                {tasks.recent.map((item) => (
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

          {/* See all link */}
          <div className="mt-3 border-t border-zinc-800 pt-3">
            <Link
              href="/library"
              className="inline-flex items-center gap-1 text-xs text-zinc-500 transition-colors hover:text-zinc-300"
            >
              See all tasks &rarr;
            </Link>
          </div>
        </>
      )}
    </div>
  )
}
