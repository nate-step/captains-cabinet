'use client'

import { useState, useTransition, useActionState } from 'react'
import { updateCronSchedule, addCronJob, deleteCronJob } from '@/actions/crons'
import type { CronJob } from '@/lib/docker'

function formatSchedule(cron: string): string {
  const patterns: Record<string, string> = {
    '*/5 * * * *': 'Every 5 minutes',
    '*/15 * * * *': 'Every 15 minutes',
    '0 */4 * * *': 'Every 4 hours',
    '0 */12 * * *': 'Every 12 hours',
    '0 6 * * *': 'Daily at 06:00 UTC',
    '0 7 * * *': 'Daily at 07:00 UTC',
    '0 18 * * *': 'Daily at 18:00 UTC',
    '0 19 * * *': 'Daily at 19:00 UTC',
    '30 6 * * *': 'Daily at 06:30 UTC',
    '30 7 * * *': 'Daily at 07:30 UTC',
    '0 20 * * *': 'Daily at 20:00 UTC',
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

function EditRow({ job, onCancel }: { job: CronJob; onCancel: () => void }) {
  const [state, formAction, isPending] = useActionState(updateCronSchedule, null)

  if (state?.success) {
    onCancel()
  }

  return (
    <tr className="border-b border-zinc-800/50 bg-zinc-800/30">
      <td colSpan={4} style={{ padding: '16px' }}>
        <form action={formAction} className="flex flex-col gap-3">
          <input type="hidden" name="originalSchedule" value={job.schedule} />
          <input type="hidden" name="command" value={job.command} />
          <div className="flex flex-col gap-2 sm:flex-row sm:items-center sm:gap-4">
            <div className="flex-1">
              <label className="text-xs text-zinc-500">Cron Expression</label>
              <input name="schedule" defaultValue={job.schedule}
                className="mt-1 block w-full rounded border border-zinc-700 bg-zinc-800 px-3 py-1.5 text-sm text-white font-mono focus:border-zinc-500 focus:outline-none" />
            </div>
            <div className="flex-1">
              <label className="text-xs text-zinc-500">Command</label>
              <div className="mt-1 text-sm text-zinc-400 font-mono truncate">{job.command}</div>
            </div>
          </div>
          {state?.error && <p className="text-xs text-red-500">{state.error}</p>}
          <div className="flex gap-2">
            <button type="submit" disabled={isPending}
              className="rounded bg-white px-3 py-1 text-xs font-semibold text-zinc-900 hover:bg-zinc-200 disabled:opacity-50">
              {isPending ? 'Saving...' : 'Save'}
            </button>
            <button type="button" onClick={onCancel}
              className="rounded border border-zinc-700 px-3 py-1 text-xs text-zinc-400 hover:bg-zinc-800">
              Cancel
            </button>
          </div>
        </form>
      </td>
    </tr>
  )
}

function DeleteButton({ job }: { job: CronJob }) {
  const [confirming, setConfirming] = useState(false)
  const [isPending, startTransition] = useTransition()
  const [, formAction] = useActionState(deleteCronJob, null)

  if (confirming) {
    return (
      <form action={(fd) => { startTransition(() => formAction(fd)); setConfirming(false) }}>
        <input type="hidden" name="schedule" value={job.schedule} />
        <input type="hidden" name="command" value={job.command} />
        <div className="flex gap-1">
          <button type="submit" disabled={isPending}
            className="rounded bg-red-600 px-2 py-0.5 text-xs text-white hover:bg-red-700 disabled:opacity-50">
            Confirm
          </button>
          <button type="button" onClick={() => setConfirming(false)}
            className="rounded border border-zinc-700 px-2 py-0.5 text-xs text-zinc-400 hover:bg-zinc-800">
            No
          </button>
        </div>
      </form>
    )
  }

  return (
    <button onClick={() => setConfirming(true)}
      className="rounded border border-red-800 px-2 py-0.5 text-xs text-red-400 hover:bg-red-900/30">
      Delete
    </button>
  )
}

function AddJobForm() {
  const [open, setOpen] = useState(false)
  const [state, formAction, isPending] = useActionState(addCronJob, null)

  if (state?.success) {
    setOpen(false)
  }

  if (!open) {
    return (
      <button onClick={() => setOpen(true)}
        className="rounded-lg border border-zinc-700 px-4 py-2 text-sm text-zinc-400 hover:bg-zinc-800 hover:text-white">
        + Add Cron Job
      </button>
    )
  }

  return (
    <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
      <h3 className="text-sm font-semibold text-white">Add Cron Job</h3>
      <form action={formAction} className="mt-4 flex flex-col gap-4">
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <div>
            <label className="text-xs text-zinc-500">Cron Expression</label>
            <input name="schedule" placeholder="*/30 * * * *" required
              className="mt-1 block w-full rounded border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-white font-mono placeholder-zinc-600 focus:border-zinc-500 focus:outline-none" />
            <p className="mt-1 text-xs text-zinc-600">minute hour day month weekday</p>
          </div>
          <div>
            <label className="text-xs text-zinc-500">Description</label>
            <input name="description" placeholder="e.g. Performance check"
              className="mt-1 block w-full rounded border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-white placeholder-zinc-600 focus:border-zinc-500 focus:outline-none" />
          </div>
        </div>
        <div>
          <label className="text-xs text-zinc-500">Command</label>
          <input name="command" placeholder="/opt/watchdog/my-script.sh" required
            className="mt-1 block w-full rounded border border-zinc-700 bg-zinc-800 px-3 py-2 text-sm text-white font-mono placeholder-zinc-600 focus:border-zinc-500 focus:outline-none" />
        </div>
        {state?.error && <p className="text-xs text-red-500">{state.error}</p>}
        <div className="flex gap-2">
          <button type="submit" disabled={isPending}
            className="rounded bg-white px-4 py-2 text-sm font-semibold text-zinc-900 hover:bg-zinc-200 disabled:opacity-50">
            {isPending ? 'Adding...' : 'Add Job'}
          </button>
          <button type="button" onClick={() => setOpen(false)}
            className="rounded border border-zinc-700 px-4 py-2 text-sm text-zinc-400 hover:bg-zinc-800">
            Cancel
          </button>
        </div>
      </form>
    </div>
  )
}

export default function CronTable({
  cronJobs,
  lastRuns,
}: {
  cronJobs: CronJob[]
  lastRuns: Record<string, string>
}) {
  const [editingIndex, setEditingIndex] = useState<number | null>(null)

  return (
    <>
      {/* Cron schedule table */}
      <div className="rounded-xl border border-zinc-800 bg-zinc-900" style={{ padding: '24px' }}>
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold text-white">Cron Schedule</h2>
          <span className="text-xs text-zinc-600">{cronJobs.length} jobs</span>
        </div>
        <div className="mt-4 overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead>
              <tr className="border-b border-zinc-800">
                <th className="font-medium text-zinc-500" style={{ padding: '8px 12px' }}>Job</th>
                <th className="font-medium text-zinc-500" style={{ padding: '8px 12px' }}>Schedule</th>
                <th className="font-medium text-zinc-500" style={{ padding: '8px 12px' }}>Cron Expression</th>
                <th className="font-medium text-zinc-500" style={{ padding: '8px 12px' }}>Actions</th>
              </tr>
            </thead>
            <tbody>
              {cronJobs.map((job, i) =>
                editingIndex === i ? (
                  <EditRow key={i} job={job} onCancel={() => setEditingIndex(null)} />
                ) : (
                  <tr key={i} className="border-b border-zinc-800/50">
                    <td className="text-zinc-300" style={{ padding: '10px 12px' }}>
                      {job.description}
                    </td>
                    <td className="text-zinc-400" style={{ padding: '10px 12px' }}>
                      {formatSchedule(job.schedule)}
                    </td>
                    <td className="font-mono text-zinc-500" style={{ padding: '10px 12px' }}>
                      {job.schedule}
                    </td>
                    <td style={{ padding: '10px 12px' }}>
                      <div className="flex gap-2">
                        <button onClick={() => setEditingIndex(i)}
                          className="rounded border border-zinc-700 px-2 py-0.5 text-xs text-zinc-400 hover:bg-zinc-800 hover:text-white">
                          Edit
                        </button>
                        <DeleteButton job={job} />
                      </div>
                    </td>
                  </tr>
                )
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Add job */}
      <AddJobForm />

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
                  <th className="font-medium text-zinc-500" style={{ padding: '8px 12px' }}>Officer</th>
                  <th className="font-medium text-zinc-500" style={{ padding: '8px 12px' }}>Task</th>
                  <th className="font-medium text-zinc-500" style={{ padding: '8px 12px' }}>Last Run</th>
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
                        <td className="font-medium text-zinc-300 uppercase" style={{ padding: '10px 12px' }}>
                          {officer}
                        </td>
                        <td className="text-zinc-400" style={{ padding: '10px 12px' }}>
                          {task}
                        </td>
                        <td className="text-zinc-500" style={{ padding: '10px 12px' }}>
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
    </>
  )
}
