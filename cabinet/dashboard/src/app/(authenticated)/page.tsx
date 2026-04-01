import Link from 'next/link'
import redis, { getCostHistory } from '@/lib/redis'
import { getTmuxWindows, isClaudeAlive, isTelegramConnected } from '@/lib/docker'
import { getOfficerConfig } from '@/lib/config'
import OfficerCard from '@/components/officer-card'
import KillSwitch from '@/components/kill-switch'
import { BarChart, HorizontalBars, ChartLegend } from '@/components/cost-chart'

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

export default async function DashboardPage() {
  const [officers, killSwitchActive, costHistory] = await Promise.all([
    getOfficerData(),
    getKillSwitchState(),
    getCostHistory(7),
  ])

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

  // 7-day trend
  const trendData = costHistory
    .slice()
    .reverse()
    .map((d) => ({
      label: d.date.slice(5), // MM-DD
      value: d.total,
    }))

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Dashboard</h1>
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

      {/* Kill switch */}
      <KillSwitch active={killSwitchActive} />

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
              <BarChart data={trendData} height={180} />
            ) : (
              <p className="text-sm text-zinc-600">No cost data available.</p>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}
