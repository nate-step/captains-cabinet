import Link from 'next/link'
import redis, { getCostHistory } from '@/lib/redis'
import { getTmuxWindows, isClaudeAlive, isTelegramConnected } from '@/lib/docker'
import { getOfficerConfig, getConfig, getDashboardConfig } from '@/lib/config'
import { getProjects } from '@/actions/projects'
import OfficerCard from '@/components/officer-card'
import { StackedBarChart, HorizontalBars, ChartLegend } from '@/components/cost-chart'
import ConsumerFrontPage from '@/components/consumer/consumer-front-page'
import CardProducts from '@/components/consumer/card-products'
import CardCabinet from '@/components/consumer/card-cabinet'
import CardCosts from '@/components/consumer/card-costs'
import CardTasks from '@/components/consumer/card-tasks'
import CardLibrary from '@/components/consumer/card-library'
import { cookies } from 'next/headers'

export const dynamic = 'force-dynamic'

type OfficerStatus = 'running' | 'stopped' | 'no-heartbeat'

interface OfficerInfo {
  role: string
  title: string
  botUsername: string
  voiceId: string
  claudeAlive: boolean
  telegramConnected: boolean
  status: OfficerStatus
  lastHeartbeat: string | null
}

async function getOfficerData(): Promise<OfficerInfo[]> {
  // Get all expected officers
  const expectedKeys = await redis.keys('cabinet:officer:expected:*')
  const heartbeatKeys = await redis.keys('cabinet:heartbeat:*')

  // Get running tmux windows
  let runningWindows: string[] = []
  try {
    runningWindows = await getTmuxWindows()
  } catch {
    // Docker may not be available in dev
  }

  // Collect all known roles
  const roles = new Set<string>()
  for (const key of expectedKeys) {
    roles.add(key.replace('cabinet:officer:expected:', ''))
  }
  for (const key of heartbeatKeys) {
    roles.add(key.replace('cabinet:heartbeat:', ''))
  }
  for (const w of runningWindows) {
    roles.add(w)
  }

  // Build officer info with parallel fetches
  const roleArray = Array.from(roles)
  const officers: OfficerInfo[] = await Promise.all(
    roleArray.map(async (role) => {
      const [heartbeat, expected, claudeAliveResult, telegramResult] = await Promise.all([
        redis.get(`cabinet:heartbeat:${role}`),
        redis.get(`cabinet:officer:expected:${role}`),
        isClaudeAlive(role),
        isTelegramConnected(role),
      ])

      const isRunning = runningWindows.includes(role)
      const config = getOfficerConfig(role)

      let status: OfficerStatus
      if (isRunning) {
        if (heartbeat) {
          const hbTime = new Date(heartbeat).getTime()
          const now = Date.now()
          status = now - hbTime > 10 * 60 * 1000 ? 'no-heartbeat' : 'running'
        } else {
          status = 'no-heartbeat'
        }
      } else if (expected === 'stopped') {
        status = 'stopped'
      } else if (expected === 'active') {
        status = 'stopped'
      } else {
        status = 'stopped'
      }

      return {
        role,
        title: config.title,
        botUsername: config.botUsername,
        voiceId: config.voiceId,
        claudeAlive: claudeAliveResult,
        telegramConnected: telegramResult,
        status,
        lastHeartbeat: heartbeat,
      }
    })
  )

  // Sort alphabetically
  officers.sort((a, b) => a.role.localeCompare(b.role))
  return officers
}

async function getKillSwitchState(): Promise<boolean> {
  const value = await redis.get('cabinet:killswitch')
  return value === 'active'
}

function formatCents(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`
}

/**
 * Read dashboard mode from cookies (server-side best-effort).
 *
 * The canonical source of truth is localStorage (client-side), but for the
 * initial server render we try reading from a cookie that the client optionally
 * sets. If the cookie isn't present, we fall back to 'consumer' (spec default).
 * The client will re-render after hydration if the localStorage value differs.
 */
async function getServerMode(): Promise<'consumer' | 'advanced'> {
  try {
    const cookieStore = await cookies()
    const val = cookieStore.get('cabinet:dashboard:mode')?.value
    if (val === 'advanced' || val === 'consumer') return val
  } catch {
    // cookies() may fail in some environments
  }
  return 'consumer'
}

export default async function DashboardPage() {
  const { consumerModeEnabled } = getDashboardConfig()

  // --- Consumer Mode branch ---
  // Feature flag gate at the PAGE level (not inside ConsumerFrontPage) so the
  // consumer card tree is structurally absent when the flag is off — no hooks,
  // no Redis reads for card data, purely inert. (Spec 032 plan §feature-flag)
  if (consumerModeEnabled) {
    const serverMode = await getServerMode()

    if (serverMode === 'consumer') {
      // Render consumer cards. KillSwitchHeader is in layout.tsx.
      return (
        <ConsumerFrontPage>
          <CardProducts />
          <CardCabinet />
          <CardCosts />
          <CardTasks />
          <CardLibrary />
        </ConsumerFrontPage>
      )
    }
    // If server-side mode is 'advanced', fall through to the advanced render.
    // After client hydration, useDashboardMode() takes over and the client can
    // switch modes without a full page reload.
  }

  // --- Advanced Mode (zero regression from pre-Spec-032 dashboard) ---
  const [officers, killSwitchActive, costHistory, projects] = await Promise.all([
    getOfficerData(),
    getKillSwitchState(),
    getCostHistory(7),
    getProjects(),
  ])

  const activeProjectName = projects.find((p) => p.active)?.name || 'Unknown'
  const config = getConfig()
  const voiceConfig = config.voice as Record<string, unknown> | undefined
  const voiceGlobalEnabled = voiceConfig?.enabled === true

  const now = new Date().toLocaleString('en-US', {
    dateStyle: 'medium',
    timeStyle: 'short',
  })

  const runningCount = officers.filter((o) => o.status === 'running').length
  const totalCount = officers.length

  const today = costHistory[0]
  const todayCost = today?.total || 0

  // Per-officer breakdown for today
  const officerCostData = today
    ? Object.entries(today.officers)
        .map(([role, value]) => ({ label: role.toUpperCase(), value, role }))
        .sort((a, b) => b.value - a.value)
    : []

  // 7-day trend (stacked by officer)
  const trendData = costHistory
    .slice()
    .reverse()
    .map((d) => ({
      label: d.date.slice(5), // MM-DD
      total: d.total,
      segments: Object.entries(d.officers)
        .map(([role, value]) => ({ role, value }))
        .sort((a, b) => b.value - a.value),
    }))

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">
            Dashboard <span className="text-zinc-500">&mdash;</span>{' '}
            <span className="text-zinc-300">{activeProjectName}</span>
          </h1>
          <p className="mt-1 text-sm text-zinc-500">Last updated: {now}</p>
        </div>
        <div className="flex items-center gap-3">
          <div className="rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-sm">
            <span className="text-zinc-500">Daily cost: </span>
            <span className="font-medium text-white">{formatCents(todayCost)}</span>
          </div>
          <div className="rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-sm">
            <span className="text-zinc-500">Officers: </span>
            <span className="font-medium text-white">
              {runningCount}/{totalCount} running
            </span>
          </div>
        </div>
      </div>

      {/* Kill switch status shown in Advanced mode — the header pill is always present */}
      {killSwitchActive && (
        <div className="rounded-xl border border-red-500/50 bg-red-900/20 px-5 py-4">
          <p className="text-sm font-semibold text-red-400">
            Kill switch is ACTIVE &mdash; all officer operations are halted.
          </p>
          <p className="mt-0.5 text-xs text-zinc-500">
            Use the Stop All button in the header to resume.
          </p>
        </div>
      )}

      {/* Officer grid */}
      {officers.length === 0 ? (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-12 text-center">
          <p className="text-zinc-500">No officers registered yet.</p>
          <p className="mt-1 text-sm text-zinc-600">
            Officers will appear here once they start sending heartbeats.
          </p>
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {officers.map((officer) => (
            <OfficerCard
              key={officer.role}
              role={officer.role}
              title={officer.title}
              botUsername={officer.botUsername}
              voiceId={officer.voiceId}
              voiceGlobalEnabled={voiceGlobalEnabled}
              claudeAlive={officer.claudeAlive}
              telegramConnected={officer.telegramConnected}
              status={officer.status}
              lastHeartbeat={officer.lastHeartbeat}
            />
          ))}
        </div>
      )}

      {/* Cost Analytics Section */}
      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        {/* Today's breakdown */}
        <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
          <div className="flex items-center justify-between">
            <div>
              <h2 className="text-lg font-semibold text-white">Today&apos;s Cost</h2>
              <p className="mt-1 text-2xl font-bold text-white">{formatCents(todayCost)}</p>
            </div>
            <Link
              href="/costs"
              className="text-sm text-zinc-500 transition-colors hover:text-zinc-300"
            >
              View all
            </Link>
          </div>
          <div className="mt-4">
            {officerCostData.length > 0 ? (
              <HorizontalBars data={officerCostData} />
            ) : (
              <p className="text-sm text-zinc-600">No cost data for today.</p>
            )}
          </div>
        </div>

        {/* 7-day trend */}
        <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
          <div className="flex items-center justify-between">
            <h2 className="text-lg font-semibold text-white">7-Day Trend</h2>
            <ChartLegend />
          </div>
          <div className="mt-4">
            {trendData.length > 0 ? (
              <StackedBarChart data={trendData} height={180} />
            ) : (
              <p className="text-sm text-zinc-600">No cost data available.</p>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
