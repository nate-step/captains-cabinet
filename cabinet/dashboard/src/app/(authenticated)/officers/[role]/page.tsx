import Link from 'next/link'
import { notFound } from 'next/navigation'
import redis from '@/lib/redis'
import { getOfficerConfig } from '@/lib/config'
import { getTmuxWindows, isClaudeAlive, isTelegramConnected } from '@/lib/docker'
import {
  VoiceEditSection,
  RoleDefinitionSection,
  LoopPromptSection,
  OfficerActions,
  DeleteOfficerButton,
} from '@/components/officer-detail-forms'

export const dynamic = 'force-dynamic'

type OfficerStatus = 'running' | 'stopped' | 'no-heartbeat'

function StatusBadge({ status }: { status: OfficerStatus }) {
  const styles = {
    running: 'bg-green-900/50 text-green-500 border-green-500/30',
    stopped: 'bg-red-900/50 text-red-500 border-red-500/30',
    'no-heartbeat': 'bg-amber-900/50 text-amber-500 border-amber-500/30',
  }

  const labels = {
    running: 'Running',
    stopped: 'Stopped',
    'no-heartbeat': 'No heartbeat',
  }

  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border px-3 py-1 text-sm font-medium ${styles[status]}`}
    >
      <span
        className={`h-2 w-2 rounded-full ${
          status === 'running'
            ? 'bg-green-500'
            : status === 'stopped'
              ? 'bg-red-500'
              : 'bg-amber-500'
        }`}
      />
      {labels[status]}
    </span>
  )
}

function ConnectionIndicator({ connected, label }: { connected: boolean; label: string }) {
  return (
    <div className="flex items-center gap-2">
      <span
        className={`h-2.5 w-2.5 rounded-full ${connected ? 'bg-green-500' : 'bg-red-500'}`}
      />
      <span className="text-sm text-zinc-400">{label}</span>
      <span className={`text-sm font-medium ${connected ? 'text-green-400' : 'text-red-400'}`}>
        {connected ? 'Connected' : 'Disconnected'}
      </span>
    </div>
  )
}

function formatTimestamp(ts: string | null): string {
  if (!ts) return 'Never'
  const date = new Date(ts)
  if (isNaN(date.getTime())) return ts
  const now = new Date()
  const diff = Math.floor((now.getTime() - date.getTime()) / 1000)
  if (diff < 60) return `${diff}s ago`
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return date.toLocaleDateString()
}

function formatCost(cents: string | null): string {
  if (!cents) return '$0.00'
  const num = parseInt(cents, 10)
  if (isNaN(num)) return '$0.00'
  return `$${(num / 100).toFixed(2)}`
}

const KNOWN_ROLES = ['cos', 'cto', 'cpo', 'cro', 'coo']

export default async function OfficerDetailPage({
  params,
}: {
  params: Promise<{ role: string }>
}) {
  const { role } = await params

  // Validate role exists
  const expectedKeys = await redis.keys('cabinet:officer:expected:*')
  const heartbeatKeys = await redis.keys('cabinet:heartbeat:*')
  const knownRoles = new Set<string>(KNOWN_ROLES)
  for (const key of expectedKeys) {
    knownRoles.add(key.replace('cabinet:officer:expected:', ''))
  }
  for (const key of heartbeatKeys) {
    knownRoles.add(key.replace('cabinet:heartbeat:', ''))
  }

  if (!knownRoles.has(role)) {
    notFound()
  }

  // Fetch all data in parallel
  const [
    heartbeat,
    expected,
    runningWindows,
    claudeAliveResult,
    telegramResult,
  ] = await Promise.all([
    redis.get(`cabinet:heartbeat:${role}`),
    redis.get(`cabinet:officer:expected:${role}`),
    getTmuxWindows(),
    isClaudeAlive(role),
    isTelegramConnected(role),
  ])

  // Get daily cost
  const today = new Date().toISOString().split('T')[0]
  const dailyCost = await redis.get(`cabinet:cost:officer:${role}:${today}`)

  // Determine status
  const isRunning = runningWindows.includes(role)
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

  // Get officer config
  const config = getOfficerConfig(role)

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      {/* Back button */}
      <Link
        href="/officers"
        className="inline-flex items-center gap-1.5 text-sm text-zinc-500 transition-colors hover:text-zinc-300"
      >
        <svg className="h-4 w-4" fill="none" viewBox="0 0 24 24" strokeWidth={2} stroke="currentColor">
          <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
        </svg>
        Back to Officers
      </Link>

      {/* Status Panel */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
        <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <div className="flex items-center gap-3">
              <h1 className="text-2xl font-bold text-white uppercase">{role}</h1>
              <StatusBadge status={status} />
            </div>
            <p className="mt-1 text-lg text-zinc-400">{config.title}</p>
          </div>
          {dailyCost && (
            <div className="rounded-lg border border-zinc-700 bg-zinc-800" style={{ padding: '8px 16px' }}>
              <span className="text-xs text-zinc-500">Daily cost</span>
              <p className="text-lg font-semibold text-white">{formatCost(dailyCost)}</p>
            </div>
          )}
        </div>

        <div className="mt-6 space-y-3">
          <ConnectionIndicator connected={claudeAliveResult} label="Claude Code" />
          <ConnectionIndicator connected={telegramResult} label="Telegram Bot" />
          <div className="flex items-center gap-2">
            <span className="h-2.5 w-2.5 rounded-full bg-zinc-600" />
            <span className="text-sm text-zinc-400">Last heartbeat</span>
            <span className="text-sm font-medium text-zinc-300">
              {formatTimestamp(heartbeat)}
            </span>
          </div>
        </div>

        {/* Action buttons */}
        <div className="mt-6">
          <OfficerActions role={role} status={status} />
        </div>
      </div>

      {/* Telegram */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
        <h2 className="text-lg font-semibold text-white">Telegram</h2>
        <div className="mt-4 space-y-3">
          <div className="flex flex-col gap-1 sm:flex-row sm:items-baseline sm:gap-3">
            <span className="w-28 shrink-0 text-sm text-zinc-500">Bot Username</span>
            <span className="text-sm text-zinc-300">
              {config.botUsername ? `@${config.botUsername}` : 'Not configured'}
            </span>
          </div>
          <ConnectionIndicator connected={telegramResult} label="Connection" />
        </div>
      </div>

      {/* Voice Configuration (editable) */}
      <VoiceEditSection role={role} config={config} />

      {/* Role Definition (editable) */}
      <RoleDefinitionSection role={role} content={config.roleDefinition} />

      {/* Loop Prompt (editable) */}
      <LoopPromptSection role={role} content={config.loopPrompt} />

      {/* Danger Zone */}
      <DeleteOfficerButton role={role} />
    </div>
  )
}
