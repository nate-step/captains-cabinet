import { getCronSchedule } from '@/lib/docker'
import { getScheduleLastRuns } from '@/lib/redis'
import CronTable from './cron-table'

export const dynamic = 'force-dynamic'

export default async function CronsPage() {
  const [cronJobs, lastRuns] = await Promise.all([
    getCronSchedule(),
    getScheduleLastRuns(),
  ])

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: '32px' }}>
      <div>
        <h1 className="text-2xl font-bold text-white">Scheduled Jobs</h1>
        <p className="mt-1 text-sm text-zinc-500">
          Manage watchdog cron schedule, add or remove jobs
        </p>
      </div>

      <CronTable cronJobs={cronJobs} lastRuns={lastRuns} />
    </div>
  )
}
