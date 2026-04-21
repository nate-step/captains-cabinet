/**
 * CaptainColumn — leftmost column in /tasks board.
 *
 * Data source: Linear founder-action issues (spec §3.2).
 * No WIP=1 constraint — Captain can juggle multiple committed items.
 *
 * Spec 038 §2, §3.2.
 */

import { CaptainTasksBoard, CaptainTask } from '@/lib/linear-tasks'

interface CaptainTaskCardProps {
  task: CaptainTask
}

function CaptainTaskCard({ task }: CaptainTaskCardProps) {
  const title = task.title.length > 80 ? task.title.slice(0, 79) + '…' : task.title

  return (
    <a
      href={task.url}
      target="_blank"
      rel="noopener noreferrer"
      className="block rounded-lg border border-zinc-700/60 bg-zinc-850 p-3 transition-colors hover:border-zinc-600"
    >
      <p className="text-sm font-medium text-zinc-200 leading-snug" title={task.title}>
        {title}
      </p>
      <div className="mt-1.5 flex items-center gap-2">
        <span className="inline-flex items-center rounded border border-purple-700/50 bg-purple-900/50 px-1.5 py-0.5 text-xs font-mono text-purple-300">
          founder-action
        </span>
        <span className="text-xs text-zinc-500">{task.state}</span>
      </div>
    </a>
  )
}

function SectionHeader({ label, count }: { label: string; count: number }) {
  return (
    <div className="flex items-center gap-2">
      <span className="text-xs font-semibold uppercase tracking-widest text-zinc-500">
        {label}
      </span>
      {count > 0 && (
        <span className="rounded-full bg-zinc-800 px-1.5 py-0.5 text-xs text-zinc-400">
          {count}
        </span>
      )}
    </div>
  )
}

interface CaptainColumnProps {
  tasks: CaptainTasksBoard
}

export function CaptainColumn({ tasks }: CaptainColumnProps) {
  if (!tasks.configured) {
    return (
      <div className="flex w-72 shrink-0 flex-col gap-4">
        <div className="flex items-center justify-between">
          <h2 className="text-sm font-bold uppercase tracking-wider text-amber-300">CAPTAIN</h2>
        </div>
        <div className="rounded-lg border border-zinc-800 p-4 text-center">
          <p className="text-xs text-zinc-500">
            LINEAR_API_KEY not configured.
            <br />
            Captain tasks unavailable.
          </p>
        </div>
      </div>
    )
  }

  const allEmpty =
    tasks.wip.length === 0 &&
    tasks.blocked.length === 0 &&
    tasks.queue.length === 0 &&
    tasks.done.length === 0

  return (
    <div className="flex w-72 shrink-0 flex-col gap-4">
      {/* Column header — highlighted */}
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-bold uppercase tracking-wider text-amber-300">CAPTAIN</h2>
        <span className="rounded-full bg-amber-900/30 px-2 py-0.5 text-xs text-amber-400">
          Linear
        </span>
      </div>

      {allEmpty ? (
        <div className="rounded-lg border border-zinc-800 p-4 text-center">
          <p className="text-xs text-zinc-500">No founder-action items in Linear.</p>
        </div>
      ) : (
        <>
          {/* In-flight (WIP) */}
          {tasks.wip.length > 0 && (
            <div className="flex flex-col gap-2">
              <SectionHeader label="In Flight" count={tasks.wip.length} />
              {tasks.wip.map((t: CaptainTask) => (
                <CaptainTaskCard key={t.id} task={t} />
              ))}
            </div>
          )}

          {/* Blocked */}
          {tasks.blocked.length > 0 && (
            <div className="flex flex-col gap-2">
              <SectionHeader label="Blocked" count={tasks.blocked.length} />
              {tasks.blocked.map((t: CaptainTask) => (
                <CaptainTaskCard key={t.id} task={t} />
              ))}
            </div>
          )}

          {/* Queue / Todo */}
          <div className="flex flex-col gap-2">
            <SectionHeader label="Queue" count={tasks.queue.length} />
            {tasks.queue.length === 0 ? (
              <p className="text-xs text-zinc-600 italic px-1">(queue empty)</p>
            ) : (
              tasks.queue.map((t: CaptainTask) => <CaptainTaskCard key={t.id} task={t} />)
            )}
          </div>

          {/* Done last 3 */}
          <div className="flex flex-col gap-2">
            <SectionHeader label="Done (last 3)" count={tasks.done.length} />
            {tasks.done.length === 0 ? (
              <p className="text-xs text-zinc-600 italic px-1">(no completions yet)</p>
            ) : (
              tasks.done.map((t: CaptainTask) => <CaptainTaskCard key={t.id} task={t} />)
            )}
          </div>
        </>
      )}
    </div>
  )
}
