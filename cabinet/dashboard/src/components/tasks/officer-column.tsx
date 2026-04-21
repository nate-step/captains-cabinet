/**
 * OfficerColumn — one column in the /tasks board for a single officer.
 *
 * Sections: WIP (0-1), Blocked, Queue, Done (last 3).
 * Spec 038 §4.1-§4.4.
 */

import { OfficerTasksBoard } from '@/lib/tasks'
import { TaskCard } from './task-card'

interface OfficerColumnProps {
  officerSlug: string
  board: OfficerTasksBoard
  isOnline: boolean
}

function SectionHeader({ label, count }: { label: string; count?: number }) {
  return (
    <div className="flex items-center gap-2">
      <span className="text-xs font-semibold uppercase tracking-widest text-zinc-500">
        {label}
      </span>
      {count !== undefined && count > 0 && (
        <span className="rounded-full bg-zinc-800 px-1.5 py-0.5 text-xs text-zinc-400">
          {count}
        </span>
      )}
    </div>
  )
}

export function OfficerColumn({ officerSlug, board, isOnline }: OfficerColumnProps) {
  const slug = officerSlug.toUpperCase()
  const hasWip = !!board.wip

  // Amber idle warning: online but no WIP (spec §4.3)
  const showIdleWarning = isOnline && !hasWip

  return (
    <div className="flex w-72 shrink-0 flex-col gap-4">
      {/* Column header */}
      <div className="flex items-center justify-between">
        <h2 className="text-sm font-bold uppercase tracking-wider text-zinc-300">{slug}</h2>
        <span
          className={`inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs ${
            isOnline
              ? 'bg-green-900/30 text-green-400'
              : 'bg-zinc-800 text-zinc-500'
          }`}
        >
          <span
            className={`h-1.5 w-1.5 rounded-full ${isOnline ? 'bg-green-400' : 'bg-zinc-500'}`}
          />
          {isOnline ? 'online' : 'offline'}
        </span>
      </div>

      {/* WIP section */}
      <div className="flex flex-col gap-2">
        <SectionHeader label="WIP" count={hasWip ? 1 : 0} />
        {board.wip ? (
          <TaskCard task={board.wip} />
        ) : showIdleWarning ? (
          <div className="rounded-lg border border-amber-700/40 bg-amber-900/10 px-3 py-2">
            <p className="text-xs text-amber-400">Idle — no WIP task declared</p>
          </div>
        ) : (
          <p className="text-xs text-zinc-600 italic px-1">(idle)</p>
        )}
      </div>

      {/* Blocked section — only show if there are blocked tasks */}
      {board.blocked.length > 0 && (
        <div className="flex flex-col gap-2">
          <SectionHeader label="Blocked" count={board.blocked.length} />
          {board.blocked.map((task) => (
            <TaskCard key={task.id} task={task} />
          ))}
        </div>
      )}

      {/* Queue section */}
      <div className="flex flex-col gap-2">
        <SectionHeader label="Queue" count={board.queue.length} />
        {board.queue.length === 0 ? (
          <p className="text-xs text-zinc-600 italic px-1">(queue empty)</p>
        ) : (
          board.queue.map((task) => <TaskCard key={task.id} task={task} />)
        )}
      </div>

      {/* Done section (last 3) */}
      <div className="flex flex-col gap-2">
        <SectionHeader label="Done (last 3)" count={board.done.length} />
        {board.done.length === 0 ? (
          <p className="text-xs text-zinc-600 italic px-1">(no completions yet)</p>
        ) : (
          board.done.map((task) => <TaskCard key={task.id} task={task} />)
        )}
      </div>
    </div>
  )
}
