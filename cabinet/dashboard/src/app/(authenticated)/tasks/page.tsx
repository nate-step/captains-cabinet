/**
 * /tasks — per-officer work front view (Spec 038 Phase A).
 *
 * Layout: Captain column (leftmost) + officer columns (alphabetical slug order).
 * Each column: WIP (0-1), Blocked, Queue, Done (last 3).
 *
 * Server component — data fetched at render time.
 * SSE auto-refresh handled by TasksClientRefresh (client component).
 */

import { getAllOfficerBoards } from '@/lib/tasks'
import { getLinearFounderActions } from '@/lib/linear-tasks'
import redis from '@/lib/redis'
import { OfficerColumn } from '@/components/tasks/officer-column'
import { CaptainColumn } from '@/components/tasks/captain-column'
import TasksClientRefresh from '@/components/tasks/tasks-client-refresh'
import OfficerColumnsGated from '@/components/tasks/officer-columns-gated'

export const dynamic = 'force-dynamic'

const OFFLINE_THRESHOLD_MS = 15 * 60 * 1000

/** Returns a map of officer_slug → is_online (heartbeat < 15min) */
async function getOfficerOnlineStatus(): Promise<Record<string, boolean>> {
  const heartbeatKeys = await redis.keys('cabinet:heartbeat:*')
  const now = Date.now()
  const result: Record<string, boolean> = {}

  await Promise.all(
    heartbeatKeys.map(async (key) => {
      const slug = key.replace('cabinet:heartbeat:', '')
      const val = await redis.get(key)
      if (val) {
        const hbTime = new Date(val).getTime()
        result[slug] = now - hbTime < OFFLINE_THRESHOLD_MS
      } else {
        result[slug] = false
      }
    })
  )
  return result
}

export default async function TasksPage() {
  const [boards, captainTasks, onlineStatus] = await Promise.all([
    getAllOfficerBoards(),
    getLinearFounderActions(),
    getOfficerOnlineStatus(),
  ])

  const officerSlugs = Object.keys(boards).sort()

  // WIP integrity check: if DB somehow has 2+ WIP for same officer (partial
  // unique index *should* prevent this — defense-in-depth banner if not).
  // We already filter to max-1 in getOfficerBoard(), so this is belt+suspenders.
  const integrityViolations: string[] = []
  // (real violation would require raw DB bypass of unique index — leave banner placeholder)

  return (
    <div className="flex flex-col gap-6">
      {/* Page header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Tasks</h1>
          <p className="mt-1 text-sm text-zinc-500">
            Per-officer work front — WIP=1 enforced at DB level
          </p>
        </div>
        <TasksClientRefresh />
      </div>

      {/* Integrity violation banner (defense-in-depth) */}
      {integrityViolations.length > 0 && (
        <div className="rounded-xl border border-red-500/50 bg-red-900/20 px-5 py-4">
          <p className="text-sm font-semibold text-red-400">
            Data integrity: {integrityViolations.join(', ')} has 2+ WIP tasks. Fix manually.
          </p>
        </div>
      )}

      {/* Horizontal-scroll column grid */}
      <div className="w-full overflow-x-auto">
        <div
          className="flex gap-4"
          style={{ minWidth: `${(officerSlugs.length + 1) * 296}px` }}
        >
          {/* Captain column — always leftmost, visible in both modes */}
          <CaptainColumn tasks={captainTasks} />

          {/* Officer columns — Advanced mode only (AC #16). Gated on the
              client because dashboard mode lives in localStorage. */}
          <OfficerColumnsGated>
            {officerSlugs.map((slug) => (
              <OfficerColumn
                key={slug}
                officerSlug={slug}
                board={boards[slug]}
                isOnline={onlineStatus[slug] ?? false}
              />
            ))}
          </OfficerColumnsGated>
        </div>
      </div>

    </div>
  )
}
