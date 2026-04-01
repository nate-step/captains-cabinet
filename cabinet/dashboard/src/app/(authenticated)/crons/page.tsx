import { getCronSchedule } from '@/lib/docker'
import { getScheduleLastRuns } from '@/lib/redis'

export const dynamic = 'force-dynamic'

function formatSchedule(cron: string): string {
  // Human-readable translations for common patterns
  const patterns: Record<string, string> = {
    '*/5 * * * *': 'Every 5 minutes',
    '*/15 * * * *': 'Every 15 minutes',
    '0 */4 * * *': 'Every 4 hours',
    '0 */12 * * *': 'Every 12 hours',
    '0 6 * * *': 'Daily at 06:00 UTC',
    '0 18 * * *': 'Daily at 18:00 UTC',
    '30 6 * * *': 'Daily at 06:30 UTC',
    '0 19 * * *': 'Daily at 19:00 UTC',
  }
  return patterns[cron] || cron
}

function formatTimestamp(ts: string): string {
  const date = new Date(ts)
  if (isNaN(date.getTime())) return ts
  const now = new Date()
  const diff = Math.floor((now.getTime() - date.getTime()) / 1000)
  if (diff < 60) return `${diff}s ago`
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return date.toLocaleDateString() + ' ' + date.toLocaleTimeString()
}

export default async function CronsPage() {
  const [cronJobs, lastRuns] = await Promise.all([
    getCronSchedule(),
    getScheduleLastRuns(),
  ])

  return (
    <div className="space-y-8">
      <div>
        <h1 className="text-2xl font-bold text-white">Scheduled Jobs</h1>
        <p className="mt-1 text-sm text-zinc-500">
          Watchdog cron schedule and last-run times
        </p>
      </div>

      {/* Cron schedule table */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
        <h2 className="text-lg font-semibold text-white">Cron Schedule</h2>
        <div className="mt-4 overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-zinc-800">
                <th className="pb-3 font-medium text-zinc-500" style={{ padding: '12px 16px' }}>Job</th>
                <th className="pb-3 font-medium text-zinc-500" style={{ padding: '12px 16px' }}>Schedule</th>
                <th className="pb-3 font-medium text-zinc-500" style={{ padding: '12px 16px' }}>Cron Expression</th>
              </tr>
            </thead>
            <tbody>
              {cronJobs.map((job, i) => (
                <tr key={i} className="border-b border-zinc-800/50">
                  <td className="text-zinc-300" style={{ padding: '16px 16px' }}>
                    {job.description}
                  </td>
                  <td className="text-zinc-400" style={{ padding: '16px 16px' }}>
                    {formatSchedule(job.schedule)}
                  </td>
                  <td className="font-mono text-zinc-500" style={{ padding: '16px 16px' }}>
                    {job.schedule}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>

      {/* Last-run times */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
        <h2 className="text-lg font-semibold text-white">Last Run Times</h2>
        <p className="mt-1 text-sm text-zinc-600">
          From Redis cabinet:schedule:last-run:* keys
        </p>
        <div className="mt-4 overflow-x-auto">
          {Object.keys(lastRuns).length === 0 ? (
            <p className="text-sm text-zinc-600">No scheduled runs recorded yet.</p>
          ) : (
            <table className="w-full text-left text-sm">
              <thead>
                <tr className="border-b border-zinc-800">
                  <th className="font-medium text-zinc-500" style={{ padding: '12px 16px' }}>Officer</th>
                  <th className="font-medium text-zinc-500" style={{ padding: '12px 16px' }}>Task</th>
                  <th className="font-medium text-zinc-500" style={{ padding: '12px 16px' }}>Last Run</th>
                </tr>
              </thead>
              <tbody>
                {Object.entries(lastRuns)
                  .sort(([a], [b]) => a.localeCompare(b))
                  .map(([key, ts]) => {
                    const parts = key.split(':')
                    const officer = parts[0] || key
                    const task = parts.slice(1).join(':') || '-'
                    return (
                      <tr key={key} className="border-b border-zinc-800/50">
                        <td className="font-medium text-zinc-300 uppercase" style={{ padding: '16px 16px' }}>
                          {officer}
                        </td>
                        <td className="text-zinc-400" style={{ padding: '16px 16px' }}>
                          {task}
                        </td>
                        <td className="text-zinc-500" style={{ padding: '16px 16px' }}>
                          {formatTimestamp(ts)}
                        </td>
                      </tr>
                    )
                  })}
              </tbody>
            </table>
          )}
        </div>
      </div>
    </div>
  )
}
