import redis from '@/lib/redis'
import { getTmuxWindows } from '@/lib/docker'
import OfficerCard from '@/components/officer-card'
import KillSwitch from '@/components/kill-switch'

export const dynamic = 'force-dynamic'

type OfficerStatus = 'running' | 'stopped' | 'no-heartbeat'

interface OfficerInfo {
  role: string
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

  // Build officer info
  const officers: OfficerInfo[] = []
  for (const role of roles) {
    const heartbeat = await redis.get(`cabinet:heartbeat:${role}`)
    const expected = await redis.get(`cabinet:officer:expected:${role}`)
    const isRunning = runningWindows.includes(role)

    let status: OfficerStatus
    if (isRunning) {
      if (heartbeat) {
        const hbTime = new Date(heartbeat).getTime()
        const now = Date.now()
        // Consider "no heartbeat" if older than 10 minutes
        status = now - hbTime > 10 * 60 * 1000 ? 'no-heartbeat' : 'running'
      } else {
        status = 'no-heartbeat'
      }
    } else if (expected === 'stopped') {
      status = 'stopped'
    } else if (expected === 'active') {
      // Expected to be running but not found in tmux
      status = 'stopped'
    } else {
      status = 'stopped'
    }

    officers.push({ role, status, lastHeartbeat: heartbeat })
  }

  // Sort alphabetically
  officers.sort((a, b) => a.role.localeCompare(b.role))
  return officers
}

async function getDailyCost(): Promise<string | null> {
  const today = new Date().toISOString().split('T')[0]
  return redis.get(`cabinet:cost:daily:${today}`)
}

async function getKillSwitchState(): Promise<boolean> {
  const value = await redis.get('cabinet:killswitch')
  return value === 'active'
}

export default async function DashboardPage() {
  const [officers, dailyCost, killSwitchActive] = await Promise.all([
    getOfficerData(),
    getDailyCost(),
    getKillSwitchState(),
  ])

  const now = new Date().toLocaleString('en-US', {
    dateStyle: 'medium',
    timeStyle: 'short',
  })

  const runningCount = officers.filter((o) => o.status === 'running').length
  const totalCount = officers.length

  return (
    <div className="space-y-8">
      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Dashboard</h1>
          <p className="mt-1 text-sm text-zinc-500">Last updated: {now}</p>
        </div>
        <div className="flex items-center gap-3">
          {dailyCost && (
            <div className="rounded-lg border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-sm">
              <span className="text-zinc-500">Daily cost: </span>
              <span className="font-medium text-white">${(parseInt(dailyCost) / 100).toFixed(2)}</span>
            </div>
          )}
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
              status={officer.status}
              lastHeartbeat={officer.lastHeartbeat}
            />
          ))}
        </div>
      )}
    </div>
  )
}
