/**
 * BoardStatStrip — pinned stat strip below the /tasks page title.
 *
 * Spec 038 v1.2 AC #19 (post-COO 038.7 / 038.8):
 *   [K officers · C captain · N/M WIP · B blocked · Q queued · D last 20 done]
 *
 * Where:
 *   K = distinct officers with any non-cancelled row
 *   C = Captain founder-action count (Linear label='founder-action', open)
 *   N = total WIP across officers
 *   M = K × 3 (officer_count × WIP_CAP)
 *   B = rows with status IN ('queue','wip') AND blocked=true
 *   Q = rows with status='queue'
 *   D = recent 20 done rows (count; always ≤ 20 once board is seeded)
 *
 * 038.7 killed the "done this week" calendar framing per Captain's
 * phases-not-calendar rule (msg 1619). 038.8 added Captain count so the
 * strip surfaces founder-blockers at a glance.
 */

import type { BoardStats } from '@/lib/tasks'

export function BoardStatStrip({
  stats,
  captainCount,
}: {
  stats: BoardStats
  captainCount?: number
}) {
  const wipTone =
    stats.totalCap > 0 && stats.totalWip >= stats.totalCap
      ? 'text-amber-300'
      : 'text-white'

  return (
    <div className="flex flex-wrap items-baseline gap-x-3 gap-y-1 rounded-xl border border-zinc-800 bg-zinc-900/70 px-4 py-2 text-sm">
      <span className="text-zinc-300">
        <span className="font-bold text-white">{stats.officers}</span>
        <span className="ml-1 text-zinc-500">officers</span>
      </span>
      {captainCount !== undefined && (
        <>
          <span className="text-zinc-600">·</span>
          <span className={captainCount > 0 ? 'text-amber-400' : 'text-zinc-300'}>
            <span className="font-bold">{captainCount}</span>
            <span className="ml-1 text-zinc-500">captain</span>
          </span>
        </>
      )}
      <span className="text-zinc-600">·</span>
      <span className="text-zinc-300">
        <span className={`font-bold ${wipTone}`}>
          {stats.totalWip}/{stats.totalCap}
        </span>
        <span className="ml-1 text-zinc-500">WIP</span>
      </span>
      <span className="text-zinc-600">·</span>
      <span className={stats.totalBlocked > 0 ? 'text-amber-400' : 'text-zinc-300'}>
        <span className="font-bold">{stats.totalBlocked}</span>
        <span className="ml-1 text-zinc-500">blocked</span>
      </span>
      <span className="text-zinc-600">·</span>
      <span className="text-zinc-300">
        <span className="font-bold text-white">{stats.totalQueue}</span>
        <span className="ml-1 text-zinc-500">queued</span>
      </span>
      <span className="text-zinc-600">·</span>
      <span className="text-zinc-300">
        <span className="font-bold text-white">{stats.recentDone}</span>
        <span className="ml-1 text-zinc-500">last 20 done</span>
      </span>
    </div>
  )
}
