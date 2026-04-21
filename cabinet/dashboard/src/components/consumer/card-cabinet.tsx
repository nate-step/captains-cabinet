/**
 * Card 1: YOUR CABINET — Spec 032 Consumer Mode.
 *
 * Shows plain-English status for each officer. Server component.
 *
 * Data sources:
 *   - cabinet:heartbeat:<role> — last heartbeat timestamp (15 min TTL → offline)
 *   - cabinet:officer:activity:<role> — JSON {verb, object, since, blocker_type?}
 *   - cabinet:officer:expected:* — which officers exist
 *
 * CRO v3 amendments:
 *   - Activity objects HTML-escaped and visually truncated at 40 chars with ellipsis
 *   - "Investigate in Advanced →" link when offline 15+ min OR activity stale 30+ min
 *   - "between tasks" ONLY when no blockers; blocker_type renders as "waiting for..."
 */

import Link from 'next/link'
import redis from '@/lib/redis'

const OFFLINE_THRESHOLD_MS = 15 * 60 * 1000 // 15 min → offline
const STALE_ACTIVITY_MS = 30 * 60 * 1000 // 30 min → show investigate link
const STALE_DISPLAY_MS = 5 * 60 * 1000 // 5 min → append elapsed time

/** Whitelisted verbs (spec §2 Card 1 implementation notes) */
const ALLOWED_VERBS = new Set([
  'drafting', 'reviewing', 'debugging', 'deploying', 'researching',
  'waiting', 'auditing', 'testing', 'shipping', 'planning',
  'investigating', 'triaging', 'working',
])

function escapeHtml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
}

/** Visual truncation at 40 chars (CRO v3 amendment) */
function truncate40(str: string): string {
  if (str.length <= 40) return str
  return str.slice(0, 37) + '...'
}

function elapsedLabel(sinceMs: number): string {
  const mins = Math.round(sinceMs / 60000)
  if (mins < 60) return `${mins} min`
  const hrs = Math.round(sinceMs / 3600000)
  return `${hrs}h`
}

interface ActivityPayload {
  verb?: string
  object?: string
  since?: string
  blocker_type?: 'captain_approval' | 'founder_action' | null
}

interface OfficerRow {
  role: string
  activityText: string
  status: 'online' | 'stale' | 'offline'
  showInvestigateLink: boolean
  elapsedText: string | null
}

async function buildOfficerRows(): Promise<OfficerRow[]> {
  const expectedKeys = await redis.keys('cabinet:officer:expected:*')
  const heartbeatKeys = await redis.keys('cabinet:heartbeat:*')
  const roles = new Set<string>()
  for (const k of expectedKeys) roles.add(k.replace('cabinet:officer:expected:', ''))
  for (const k of heartbeatKeys) roles.add(k.replace('cabinet:heartbeat:', ''))

  const now = Date.now()

  const rows: OfficerRow[] = await Promise.all(
    Array.from(roles).map(async (role) => {
      const [heartbeatRaw, activityRaw] = await Promise.all([
        redis.get(`cabinet:heartbeat:${role}`),
        redis.get(`cabinet:officer:activity:${role}`),
      ])

      // Determine online/offline
      let isOffline = true
      let offlineDurationMs = 0
      if (heartbeatRaw) {
        const hbTime = new Date(heartbeatRaw).getTime()
        if (!isNaN(hbTime)) {
          offlineDurationMs = now - hbTime
          isOffline = offlineDurationMs > OFFLINE_THRESHOLD_MS
        }
      }

      if (isOffline) {
        return {
          role,
          activityText: `${role.toUpperCase()} is offline`,
          status: 'offline' as const,
          showInvestigateLink: true,
          elapsedText: offlineDurationMs > 0 ? elapsedLabel(offlineDurationMs) : null,
        }
      }

      // Parse activity
      let activityText = `${role.toUpperCase()} is working`
      let isStale = false
      let elapsedText: string | null = null

      if (activityRaw) {
        let payload: ActivityPayload = {}
        try {
          payload = JSON.parse(activityRaw) as ActivityPayload
        } catch {
          // malformed JSON — treat as no activity
        }

        const sinceMs = payload.since ? now - new Date(payload.since).getTime() : 0
        isStale = sinceMs > STALE_ACTIVITY_MS

        if (sinceMs > STALE_DISPLAY_MS) {
          elapsedText = elapsedLabel(sinceMs)
        }

        if (payload.blocker_type === 'captain_approval') {
          const obj = payload.object ? truncate40(escapeHtml(payload.object)) : 'Captain approval'
          activityText = `${role.toUpperCase()} is waiting for ${obj}`
        } else if (payload.blocker_type === 'founder_action') {
          const obj = payload.object ? truncate40(escapeHtml(payload.object)) : 'a founder action'
          activityText = `${role.toUpperCase()} is blocked on ${obj}`
        } else if (payload.verb) {
          const verb = ALLOWED_VERBS.has(payload.verb) ? payload.verb : 'working'
          if (payload.object) {
            const obj = truncate40(escapeHtml(payload.object))
            activityText = `${role.toUpperCase()} is ${verb} ${obj}`
          } else {
            activityText = `${role.toUpperCase()} is ${verb}`
          }
        } else {
          // Online heartbeat, no structured activity → "between tasks"
          activityText = `${role.toUpperCase()} is between tasks`
        }
      } else {
        // Online but no activity key at all → "between tasks"
        activityText = `${role.toUpperCase()} is between tasks`
      }

      const showInvestigateLink = isStale

      return {
        role,
        activityText,
        status: isStale ? ('stale' as const) : ('online' as const),
        showInvestigateLink,
        elapsedText,
      }
    })
  )

  // Sort alphabetically
  rows.sort((a, b) => a.role.localeCompare(b.role))
  return rows
}

function StatusIndicator({ status }: { status: 'online' | 'stale' | 'offline' }) {
  if (status === 'online') return <span className="text-green-400 text-sm">🟢</span>
  if (status === 'stale') return <span className="text-amber-400 text-sm">🟡</span>
  return <span className="text-red-400 text-sm">🔴</span>
}

export default async function CardCabinet() {
  const rows = await buildOfficerRows()

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-5">
      <div className="mb-4">
        <h2 className="text-xs font-semibold uppercase tracking-widest text-zinc-500">
          Your Cabinet
        </h2>
      </div>

      {rows.length === 0 ? (
        <div className="py-4 text-center">
          <p className="text-sm text-zinc-500">
            Welcome to your Cabinet.
          </p>
          <p className="mt-1 text-xs text-zinc-600">
            Your officers will appear here once they come online.
          </p>
          {/* PENDING CAPTAIN APPROVAL: empty-state copy */}
        </div>
      ) : (
        <div className="space-y-3">
          {rows.map((row) => (
            <div key={row.role}>
              <div className="flex items-start gap-2">
                <StatusIndicator status={row.status} />
                <div className="min-w-0 flex-1">
                  <p className="text-sm leading-snug text-zinc-200">
                    {row.activityText}
                    {row.elapsedText && (
                      <span className="ml-1 text-zinc-500">({row.elapsedText})</span>
                    )}
                  </p>
                  {/* Contextual "Investigate in Advanced" — only for genuinely abnormal states */}
                  {row.showInvestigateLink && (
                    <Link
                      href={`/officers/${row.role}`}
                      className="mt-0.5 inline-flex items-center gap-1 text-xs text-zinc-500 transition-colors hover:text-zinc-300"
                    >
                      See details
                      <span aria-hidden="true">&rarr;</span>
                    </Link>
                  )}
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
