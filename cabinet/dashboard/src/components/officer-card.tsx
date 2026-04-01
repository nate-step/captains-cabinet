'use client'

import { useTransition } from 'react'
import Link from 'next/link'
import { startOfficer, stopOfficer, restartOfficer } from '@/actions/officers'

type OfficerStatus = 'running' | 'stopped' | 'no-heartbeat'

interface OfficerCardProps {
  role: string
  title?: string
  botUsername?: string
  voiceId?: string
  claudeAlive?: boolean
  telegramConnected?: boolean
  status: OfficerStatus
  lastHeartbeat: string | null
}

function Spinner() {
  return (
    <svg className="h-4 w-4 animate-spin" viewBox="0 0 24 24" fill="none">
      <circle
        className="opacity-25"
        cx="12"
        cy="12"
        r="10"
        stroke="currentColor"
        strokeWidth="4"
      />
      <path
        className="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
      />
    </svg>
  )
}

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
      className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium ${styles[status]}`}
    >
      <span
        className={`h-1.5 w-1.5 rounded-full ${
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

function ConnectionDot({ connected, label }: { connected: boolean; label: string }) {
  return (
    <span className="inline-flex items-center gap-1 text-xs text-zinc-500">
      <span
        className={`h-1.5 w-1.5 rounded-full ${connected ? 'bg-green-500' : 'bg-red-500'}`}
      />
      {label}
    </span>
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

export default function OfficerCard({
  role,
  title,
  botUsername,
  voiceId,
  claudeAlive,
  telegramConnected,
  status,
  lastHeartbeat,
}: OfficerCardProps) {
  const [isPending, startTransition] = useTransition()

  function handleStart(e: React.MouseEvent) {
    e.preventDefault()
    e.stopPropagation()
    startTransition(() => {
      startOfficer(role)
    })
  }

  function handleStop(e: React.MouseEvent) {
    e.preventDefault()
    e.stopPropagation()
    startTransition(() => {
      stopOfficer(role)
    })
  }

  function handleRestart(e: React.MouseEvent) {
    e.preventDefault()
    e.stopPropagation()
    startTransition(() => {
      restartOfficer(role)
    })
  }

  return (
    <Link
      href={`/officers/${role}`}
      className="block rounded-xl border border-zinc-800 bg-zinc-900 transition-colors hover:border-zinc-700 hover:bg-zinc-900/80"
      style={{ padding: '20px' }}
    >
      <div className="flex items-start justify-between">
        <div className="min-w-0">
          <h3 className="text-lg font-bold text-white uppercase">{role}</h3>
          {title && (
            <p className="mt-0.5 truncate text-sm text-zinc-500">{title}</p>
          )}
          {botUsername && (
            <p className="mt-0.5 truncate text-xs text-zinc-600">@{botUsername}</p>
          )}
        </div>
        <StatusBadge status={status} />
      </div>

      {/* Connection indicators */}
      {(claudeAlive !== undefined || telegramConnected !== undefined) && (
        <div className="mt-2 flex items-center gap-3">
          {claudeAlive !== undefined && (
            <ConnectionDot connected={claudeAlive} label="Claude" />
          )}
          {telegramConnected !== undefined && (
            <ConnectionDot connected={telegramConnected} label="Telegram" />
          )}
        </div>
      )}

      {/* Voice and heartbeat row */}
      <div className="mt-2 flex items-center justify-between">
        <span className="text-xs text-zinc-500">
          Last heartbeat: {formatTimestamp(lastHeartbeat)}
        </span>
        {voiceId !== undefined && (
          <span className={`text-xs ${voiceId ? 'text-zinc-500' : 'text-zinc-600'}`}>
            Voice: {voiceId ? 'enabled' : 'not configured'}
          </span>
        )}
      </div>

      <div className="mt-3 flex gap-2">
        {status === 'stopped' && (
          <button
            onClick={handleStart}
            disabled={isPending}
            className="inline-flex items-center gap-1.5 rounded-lg bg-green-600 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-green-500 disabled:opacity-50"
          >
            {isPending ? <Spinner /> : null}
            Start
          </button>
        )}
        {(status === 'running' || status === 'no-heartbeat') && (
          <>
            <button
              onClick={handleStop}
              disabled={isPending}
              className="inline-flex items-center gap-1.5 rounded-lg bg-red-600 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-red-500 disabled:opacity-50"
            >
              {isPending ? <Spinner /> : null}
              Stop
            </button>
            <button
              onClick={handleRestart}
              disabled={isPending}
              className="inline-flex items-center gap-1.5 rounded-lg bg-amber-600 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-amber-500 disabled:opacity-50"
            >
              {isPending ? <Spinner /> : null}
              Restart
            </button>
          </>
        )}
      </div>
    </Link>
  )
}
