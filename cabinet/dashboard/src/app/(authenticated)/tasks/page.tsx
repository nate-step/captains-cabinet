/**
 * /tasks — per-officer work front view (Spec 038 Phase A v1.2).
 *
 * Layout: Captain column (leftmost) + officer columns (alphabetical slug order).
 * Each column: WIP (0-3, blocked as chain-icon overlay), Queue, Done (last 3).
 *
 * Server component — data fetched at render time.
 * Live refresh via SSE handled by TasksClientRefresh (client component).
 */

import path from 'node:path'
import { readFile } from 'node:fs/promises'
import { getAllOfficerBoards, getBoardStats, WIP_CAP } from '@/lib/tasks'
import { getLinearFounderActions } from '@/lib/linear-tasks'
import redis from '@/lib/redis'
import { OfficerColumn } from '@/components/tasks/officer-column'
import { CaptainColumn } from '@/components/tasks/captain-column'
import TasksClientRefresh from '@/components/tasks/tasks-client-refresh'
import OfficerColumnsGated from '@/components/tasks/officer-columns-gated'
import { BoardStatStrip } from '@/components/tasks/board-stat-strip'

export const dynamic = 'force-dynamic'

/** Resolve the active context slug for this deployment. Follows the same
 *  precedence as my-tasks.sh: env > active-project.txt. Throws on miss —
 *  /tasks without a context can't render a per-(context,officer) WIP board. */
async function resolveActiveContext(): Promise<string> {
  if (process.env.CABINET_CONTEXT?.trim()) return process.env.CABINET_CONTEXT.trim()
  const cabinetRoot = process.env.CABINET_ROOT || '/opt/founders-cabinet'
  const activeFile = path.join(cabinetRoot, 'instance/config/active-project.txt')
  try {
    const txt = await readFile(activeFile, 'utf-8')
    const slug = txt.trim()
    if (!slug) throw new Error('active-project.txt is empty')
    return slug
  } catch (err) {
    throw new Error(
      `/tasks: cannot resolve active context. Set $CABINET_CONTEXT or write ${activeFile}. (${(err as Error).message})`
    )
  }
}

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
  const contextSlug = await resolveActiveContext()
  const [boards, captainTasks, onlineStatus, stats] = await Promise.all([
    getAllOfficerBoards(contextSlug),
    getLinearFounderActions(),
    getOfficerOnlineStatus(),
    getBoardStats(contextSlug),
  ])

  const officerSlugs = Object.keys(boards).sort()

  // WIP integrity check (Spec 038 v1.2 §4.4 — defense-in-depth).
  // v1.2: getOfficerBoard() no longer slices at WIP_CAP, so this banner
  // actually surfaces DB-state violations (advisory lock + trigger should
  // prevent them; if one fires, Sonnet's BLOCKER-3 concern would be real).
  const integrityViolations: string[] = []
  for (const slug of officerSlugs) {
    if (boards[slug].wip.length > WIP_CAP) {
      integrityViolations.push(`${slug} (${boards[slug].wip.length} WIP)`)
    }
  }

  return (
    <div className="flex flex-col gap-6">
      {/* Page header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Tasks</h1>
          <p className="mt-1 text-sm text-zinc-500">
            Per-officer work front — WIP={WIP_CAP} cap, DB-enforced trigger
          </p>
        </div>
        <TasksClientRefresh />
      </div>

      {/* All-officers rollup strip (Spec 038 v1.2 AC #19) — captainCount
          surfaces founder-action blockers per 038.8. Open = wip + queue
          + blocked; done rows are not "blocking" the Captain anymore. */}
      <BoardStatStrip
        stats={stats}
        captainCount={
          captainTasks.configured
            ? captainTasks.wip.length +
              captainTasks.queue.length +
              captainTasks.blocked.length
            : undefined
        }
      />

      {/* Integrity violation banner (defense-in-depth) */}
      {integrityViolations.length > 0 && (
        <div className="rounded-xl border border-red-500/50 bg-red-900/20 px-5 py-4">
          <p className="text-sm font-semibold text-red-400">
            Data integrity: {integrityViolations.join(', ')} exceed WIP cap of {WIP_CAP}. Fix manually.
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

          {/* Officer columns — Advanced mode only (AC #17). Gated on the
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
