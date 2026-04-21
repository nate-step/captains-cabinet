/**
 * OfficerColumn — one column in the /tasks board for a single officer.
 *
 * Spec 038 v1.1 §4.1-§4.4:
 * - WIP bucket holds 0..3 cards (cap enforced via DB trigger).
 * - Blocked is a chain-icon OVERLAY on a WIP card, not a separate bucket.
 * - Queue: unbounded list.
 * - Done: last 3 only.
 * - Column header badge: `<slug> N/3` — amber at N=3, green at 1-2, gray at 0.
 * - AC #12: amber "Idle — 0/3 WIP slots" when online and WIP is empty.
 */

import { OfficerTasksBoard, WIP_CAP } from '@/lib/tasks'
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

/** Per-officer rollup badge (Spec 038 v1.1 AC #18). */
function WipCapBadge({ count }: { count: number }) {
  const tone =
    count >= WIP_CAP
      ? 'bg-amber-900/40 text-amber-300 border-amber-700/60'
      : count > 0
        ? 'bg-green-900/30 text-green-400 border-green-700/50'
        : 'bg-zinc-800 text-zinc-500 border-zinc-700'
  return (
    <span
      className={`inline-flex items-center rounded-full border px-2 py-0.5 text-xs font-mono ${tone}`}
      title={`${count} of ${WIP_CAP} WIP slots used`}
    >
      {count}/{WIP_CAP}
    </span>
  )
}

export function OfficerColumn({ officerSlug, board, isOnline }: OfficerColumnProps) {
  const slug = officerSlug.toUpperCase()
  const wipCount = board.wip.length

  // Amber idle warning: online but no WIP (spec §4.3)
  const showIdleWarning = isOnline && wipCount === 0

  // Defense-in-depth banner: trigger somehow failed (Spec 038 v1.1 §4.4)
  const capViolation = wipCount > WIP_CAP

  return (
    <div className="flex w-72 shrink-0 flex-col gap-4">
      {/* Column header — slug + N/3 badge + online/offline */}
      <div className="flex items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <h2 className="text-sm font-bold uppercase tracking-wider text-zinc-300">{slug}</h2>
          <WipCapBadge count={wipCount} />
        </div>
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

      {/* WIP section — up to WIP_CAP cards, blocked shown as overlay on-card */}
      <div className="flex flex-col gap-2">
        <SectionHeader label="WIP" count={wipCount} />
        {capViolation && (
          <div className="rounded-lg border border-red-500/50 bg-red-900/20 px-3 py-2">
            <p className="text-xs text-red-400">
              ⚠ {wipCount} WIP (cap {WIP_CAP}). Fix manually.
            </p>
          </div>
        )}
        {wipCount === 0 ? (
          showIdleWarning ? (
            <div className="rounded-lg border border-amber-700/40 bg-amber-900/10 px-3 py-2">
              <p className="text-xs text-amber-400">Idle — 0/{WIP_CAP} WIP slots</p>
            </div>
          ) : (
            <p className="text-xs text-zinc-600 italic px-1">(idle)</p>
          )
        ) : (
          board.wip.map((task) => <TaskCard key={task.id} task={task} />)
        )}
      </div>

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
