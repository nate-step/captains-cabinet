import Link from 'next/link'
import redis from '@/lib/redis'
import { getTmuxWindows, isClaudeAlive, isTelegramConnected } from '@/lib/docker'
import { getOfficerConfig, getConfig } from '@/lib/config'
import OfficerCard from '@/components/officer-card'
import fs from 'fs'
import path from 'path'

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

  // Also check for role definitions on disk
  const agentDir = '/opt/founders-cabinet/.claude/agents'
  let diskRoles: string[] = []
  try {
    diskRoles = fs
      .readdirSync(agentDir)
      .filter((f: string) => f.endsWith('.md'))
      .map((f: string) => f.replace('.md', ''))
  } catch {
    // Not available
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
  for (const r of diskRoles) {
    roles.add(r)
  }

  // Build officer info with parallel fetches for connection status
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

  officers.sort((a, b) => a.role.localeCompare(b.role))
  return officers
}

export default async function OfficersPage() {
  const officers = await getOfficerData()
  const config = getConfig()
  const voiceConfig = config.voice as Record<string, unknown> | undefined
  const voiceGlobalEnabled = voiceConfig?.enabled === true

  return (
    <div className="space-y-8">
      {/* Header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h1 className="text-2xl font-bold text-white">Officers</h1>
          <p className="mt-1 text-sm text-zinc-500">
            Manage officer sessions and roles
          </p>
        </div>
        <Link
          href="/officers/create"
          className="inline-flex items-center gap-2 rounded-lg bg-white px-4 py-2 text-sm font-semibold text-zinc-900 transition-colors hover:bg-zinc-200"
        >
          <svg
            className="h-4 w-4"
            fill="none"
            viewBox="0 0 24 24"
            strokeWidth={2}
            stroke="currentColor"
          >
            <path
              strokeLinecap="round"
              strokeLinejoin="round"
              d="M12 4.5v15m7.5-7.5h-15"
            />
          </svg>
          New Officer
        </Link>
      </div>

      {/* Officer list */}
      {officers.length === 0 ? (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-12 text-center">
          <p className="text-zinc-500">No officers found.</p>
          <p className="mt-1 text-sm text-zinc-600">
            Create your first officer to get started.
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
    </div>
  )
}
