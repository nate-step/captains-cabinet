import redis from '@/lib/redis'

export const dynamic = 'force-dynamic'

interface OfficerHealth {
  role: string
  heartbeat: string | null
  lastToolCall: string | null
  toolCallsToday: number
  contextPct: number | null
  contextTokens: number | null
  contextUpdated: string | null
}

type StatusLevel = 'green' | 'yellow' | 'red'

function getStatus(health: OfficerHealth, now: number): StatusLevel {
  if (!health.heartbeat) return 'red'
  const hbAge = now - new Date(health.heartbeat).getTime()
  if (hbAge > 15 * 60 * 1000) return 'red'
  if (!health.lastToolCall) return 'yellow'
  const tcAge = now - new Date(health.lastToolCall).getTime()
  if (tcAge > 5 * 60 * 1000) return 'yellow'
  return 'green'
}

function formatRelative(isoTs: string | null, now: number): string {
  if (!isoTs) return '—'
  const diffMs = now - new Date(isoTs).getTime()
  const diffSec = Math.floor(diffMs / 1000)
  if (diffSec < 60) return `${diffSec}s ago`
  const diffMin = Math.floor(diffSec / 60)
  if (diffMin < 60) return `${diffMin}m ago`
  const diffHr = Math.floor(diffMin / 60)
  if (diffHr < 24) return `${diffHr}h ago`
  const diffDay = Math.floor(diffHr / 24)
  return `${diffDay}d ago`
}

async function getHealthData(): Promise<OfficerHealth[]> {
  // Discover officers dynamically from expected keys
  const officerKeys = await redis.keys('cabinet:officer:expected:*')
  const roles = officerKeys
    .map((k) => k.replace('cabinet:officer:expected:', ''))
    .filter((k) => !k.includes(':'))
    .sort()

  if (roles.length === 0) {
    // Fallback: discover from heartbeat keys
    const hbKeys = await redis.keys('cabinet:heartbeat:*')
    roles.push(
      ...hbKeys
        .map((k) => k.replace('cabinet:heartbeat:', ''))
        .filter((k) => !k.includes(':'))
        .sort()
    )
  }

  const results: OfficerHealth[] = await Promise.all(
    roles.map(async (role) => {
      const [heartbeat, lastToolCall, toolCallsStr, contextHash] = await Promise.all([
        redis.get(`cabinet:heartbeat:${role}`),
        redis.get(`cabinet:last-toolcall:${role}`),
        redis.get(`cabinet:toolcalls:${role}`),
        redis.hgetall(`cabinet:cost:tokens:${role}`),
      ])

      const toolCallsToday = toolCallsStr ? parseInt(toolCallsStr, 10) : 0

      let contextPct: number | null = null
      let contextTokens: number | null = null
      let contextUpdated: string | null = null

      if (contextHash) {
        const pctStr = contextHash['last_context_pct']
        const tokStr = contextHash['last_context_tokens']
        const updStr = contextHash['last_updated']
        if (pctStr) contextPct = parseFloat(pctStr)
        if (tokStr) contextTokens = parseInt(tokStr, 10)
        if (updStr) contextUpdated = updStr
      }

      return {
        role,
        heartbeat,
        lastToolCall,
        toolCallsToday,
        contextPct,
        contextTokens,
        contextUpdated,
      }
    })
  )

  return results
}

function formatTokens(n: number): string {
  if (n >= 1000000) return `${(n / 1000000).toFixed(1)}M`
  if (n >= 1000) return `${(n / 1000).toFixed(0)}K`
  return String(n)
}

export default async function HealthPage() {
  const officers = await getHealthData()
  const now = Date.now()

  const statusCounts = officers.reduce(
    (acc, o) => {
      const s = getStatus(o, now)
      acc[s] = (acc[s] || 0) + 1
      return acc
    },
    {} as Record<StatusLevel, number>
  )

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      {/* Header */}
      <div>
        <h1 className="text-2xl font-bold text-white">Health</h1>
        <p className="mt-1 text-sm text-zinc-500">
          Live operational status for all officers
        </p>
      </div>

      {/* Summary badges */}
      <div className="grid grid-cols-3 gap-4">
        <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '20px' }}>
          <div className="flex items-center gap-2">
            <span
              style={{
                display: 'inline-block',
                width: '10px',
                height: '10px',
                borderRadius: '50%',
                background: '#10b981',
              }}
            />
            <span className="text-sm text-zinc-500">Active</span>
          </div>
          <p className="mt-1 text-3xl font-bold text-white">{statusCounts.green || 0}</p>
        </div>
        <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '20px' }}>
          <div className="flex items-center gap-2">
            <span
              style={{
                display: 'inline-block',
                width: '10px',
                height: '10px',
                borderRadius: '50%',
                background: '#f59e0b',
              }}
            />
            <span className="text-sm text-zinc-500">Idle</span>
          </div>
          <p className="mt-1 text-3xl font-bold text-white">{statusCounts.yellow || 0}</p>
        </div>
        <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '20px' }}>
          <div className="flex items-center gap-2">
            <span
              style={{
                display: 'inline-block',
                width: '10px',
                height: '10px',
                borderRadius: '50%',
                background: '#ef4444',
              }}
            />
            <span className="text-sm text-zinc-500">Down</span>
          </div>
          <p className="mt-1 text-3xl font-bold text-white">{statusCounts.red || 0}</p>
        </div>
      </div>

      {/* Officer cards */}
      {officers.length === 0 ? (
        <div className="rounded-xl border border-zinc-800 bg-zinc-900 p-12 text-center">
          <p className="text-zinc-500">No officers found in Redis.</p>
          <p className="mt-1 text-sm text-zinc-600">
            Officers register themselves via heartbeat keys when running.
          </p>
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {officers.map((officer) => {
            const status = getStatus(officer, now)

            const statusDotColor =
              status === 'green'
                ? '#10b981'
                : status === 'yellow'
                  ? '#f59e0b'
                  : '#ef4444'

            const statusLabel =
              status === 'green' ? 'Active' : status === 'yellow' ? 'Idle' : 'Down'

            const ctxPct = officer.contextPct ?? 0
            const ctxBarColor =
              ctxPct >= 75
                ? '#ef4444'
                : ctxPct >= 50
                  ? '#f59e0b'
                  : '#10b981'

            return (
              <div
                key={officer.role}
                className="rounded-xl border border-zinc-800 bg-zinc-900"
                style={{ padding: '24px' }}
              >
                {/* Card header */}
                <div
                  style={{
                    display: 'flex',
                    alignItems: 'center',
                    justifyContent: 'space-between',
                    marginBottom: '20px',
                  }}
                >
                  <span className="text-lg font-bold text-white uppercase">
                    {officer.role}
                  </span>
                  <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
                    <span
                      style={{
                        display: 'inline-block',
                        width: '10px',
                        height: '10px',
                        borderRadius: '50%',
                        background: statusDotColor,
                        flexShrink: 0,
                      }}
                    />
                    <span
                      style={{
                        fontSize: '12px',
                        color: statusDotColor,
                        fontWeight: 500,
                      }}
                    >
                      {statusLabel}
                    </span>
                  </div>
                </div>

                {/* Stats */}
                <div style={{ display: 'flex', flexDirection: 'column', gap: '14px' }}>
                  {/* Idle time */}
                  <div
                    style={{
                      display: 'flex',
                      justifyContent: 'space-between',
                      alignItems: 'baseline',
                    }}
                  >
                    <span className="text-sm text-zinc-500">Last tool call</span>
                    <span className="text-sm font-medium text-white">
                      {formatRelative(officer.lastToolCall, now)}
                    </span>
                  </div>

                  {/* Tool calls today */}
                  <div
                    style={{
                      display: 'flex',
                      justifyContent: 'space-between',
                      alignItems: 'baseline',
                    }}
                  >
                    <span className="text-sm text-zinc-500">Tool calls today</span>
                    <span className="text-sm font-medium text-white">
                      {officer.toolCallsToday.toLocaleString()}
                    </span>
                  </div>

                  {/* Last active (heartbeat) */}
                  <div
                    style={{
                      display: 'flex',
                      justifyContent: 'space-between',
                      alignItems: 'baseline',
                    }}
                  >
                    <span className="text-sm text-zinc-500">Last heartbeat</span>
                    <span className="text-sm font-medium text-white">
                      {formatRelative(officer.heartbeat, now)}
                    </span>
                  </div>

                  {/* Context window */}
                  <div style={{ marginTop: '4px' }}>
                    <div
                      style={{
                        display: 'flex',
                        justifyContent: 'space-between',
                        alignItems: 'baseline',
                        marginBottom: '6px',
                      }}
                    >
                      <span className="text-sm text-zinc-500">Context window</span>
                      <span className="text-sm font-medium text-white">
                        {officer.contextPct !== null
                          ? `${officer.contextPct.toFixed(1)}%`
                          : '—'}
                        {officer.contextTokens !== null
                          ? ` (${formatTokens(officer.contextTokens)})`
                          : ''}
                      </span>
                    </div>
                    {/* Progress bar */}
                    <div
                      style={{
                        height: '6px',
                        borderRadius: '3px',
                        background: '#27272a',
                        overflow: 'hidden',
                      }}
                    >
                      <div
                        style={{
                          height: '100%',
                          width: `${Math.min(ctxPct, 100)}%`,
                          borderRadius: '3px',
                          background: officer.contextPct !== null ? ctxBarColor : '#3f3f46',
                          transition: 'width 0.3s ease',
                        }}
                      />
                    </div>
                    {officer.contextUpdated && (
                      <p
                        style={{
                          fontSize: '11px',
                          color: '#71717a',
                          marginTop: '4px',
                          textAlign: 'right',
                        }}
                      >
                        updated {formatRelative(officer.contextUpdated, now)}
                      </p>
                    )}
                  </div>
                </div>
              </div>
            )
          })}
        </div>
      )}

      {/* Legend */}
      <div
        className="rounded-xl border border-zinc-800 bg-zinc-900"
        style={{ padding: '16px 24px' }}
      >
        <div style={{ display: 'flex', gap: '24px', flexWrap: 'wrap' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
            <span
              style={{
                display: 'inline-block',
                width: '10px',
                height: '10px',
                borderRadius: '50%',
                background: '#10b981',
              }}
            />
            <span className="text-xs text-zinc-400">
              Active — heartbeat within 15 min, last tool call within 5 min
            </span>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
            <span
              style={{
                display: 'inline-block',
                width: '10px',
                height: '10px',
                borderRadius: '50%',
                background: '#f59e0b',
              }}
            />
            <span className="text-xs text-zinc-400">
              Idle — heartbeat fresh but no tool call in 5+ min
            </span>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
            <span
              style={{
                display: 'inline-block',
                width: '10px',
                height: '10px',
                borderRadius: '50%',
                background: '#ef4444',
              }}
            />
            <span className="text-xs text-zinc-400">
              Down — heartbeat expired (15 min TTL) or missing
            </span>
          </div>
        </div>
      </div>
    </div>
  )
}
