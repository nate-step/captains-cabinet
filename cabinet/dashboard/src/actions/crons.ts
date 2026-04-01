'use server'

import { exec as execCb } from 'child_process'
import { promisify } from 'util'
import { revalidatePath } from 'next/cache'
import redis from '@/lib/redis'

const exec = promisify(execCb)
const prefix = process.env.CABINET_PREFIX || 'cabinet'
const watchdog = `${prefix}-watchdog`
const IS_MOCK = process.env.MOCK_DATA === 'true' || !process.env.REDIS_URL

async function watchdogExec(command: string): Promise<string> {
  if (IS_MOCK) {
    console.log(`[mock watchdog] Would exec: ${command}`)
    return ''
  }
  const { stdout } = await exec(
    `docker exec ${watchdog} sh -c '${command.replace(/'/g, "'\\''")}'`
  )
  return stdout.trim()
}

export async function updateCronSchedule(
  _prev: { error?: string; success?: boolean } | null,
  formData: FormData
) {
  const originalSchedule = formData.get('originalSchedule') as string
  const newSchedule = formData.get('schedule') as string
  const command = formData.get('command') as string

  if (!newSchedule || !command) {
    return { error: 'Schedule and command are required' }
  }

  // Validate cron expression (5 fields)
  const cronParts = newSchedule.trim().split(/\s+/)
  if (cronParts.length !== 5) {
    return { error: 'Cron expression must have exactly 5 fields (minute hour day month weekday)' }
  }

  if (IS_MOCK) {
    revalidatePath('/crons')
    return { success: true }
  }

  try {
    // Get current crontab, replace the matching line, write it back
    const escapedOriginal = originalSchedule.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    const escapedCommand = command.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')

    await watchdogExec(
      `crontab -l | sed "s|^${escapedOriginal}.*${escapedCommand}.*|${newSchedule} ${command}|" | crontab -`
    )
    revalidatePath('/crons')
    return { success: true }
  } catch (err) {
    return { error: err instanceof Error ? err.message : 'Failed to update cron' }
  }
}

export async function addCronJob(
  _prev: { error?: string; success?: boolean } | null,
  formData: FormData
) {
  const schedule = formData.get('schedule') as string
  const command = formData.get('command') as string
  const description = formData.get('description') as string

  if (!schedule || !command) {
    return { error: 'Schedule and command are required' }
  }

  const cronParts = schedule.trim().split(/\s+/)
  if (cronParts.length !== 5) {
    return { error: 'Cron expression must have exactly 5 fields' }
  }

  if (IS_MOCK) {
    revalidatePath('/crons')
    return { success: true }
  }

  try {
    const comment = description ? `# ${description}` : ''
    const newLine = `${schedule} ${command} >> /var/log/watchdog/cron.log 2>&1`

    if (comment) {
      await watchdogExec(`(crontab -l; echo "${comment}"; echo "${newLine}") | crontab -`)
    } else {
      await watchdogExec(`(crontab -l; echo "${newLine}") | crontab -`)
    }
    revalidatePath('/crons')
    return { success: true }
  } catch (err) {
    return { error: err instanceof Error ? err.message : 'Failed to add cron job' }
  }
}

export async function deleteCronJob(
  _prev: { error?: string; success?: boolean } | null,
  formData: FormData
) {
  const schedule = formData.get('schedule') as string
  const command = formData.get('command') as string

  if (!schedule || !command) {
    return { error: 'Schedule and command are required to identify the job' }
  }

  if (IS_MOCK) {
    revalidatePath('/crons')
    return { success: true }
  }

  try {
    const escapedSchedule = schedule.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    // Remove the line matching this schedule + command pattern
    await watchdogExec(
      `crontab -l | grep -v "^${escapedSchedule}.*" | crontab -`
    )
    revalidatePath('/crons')
    return { success: true }
  } catch (err) {
    return { error: err instanceof Error ? err.message : 'Failed to delete cron job' }
  }
}

// === Officer Task Actions ===

export async function resetTaskTimer(officer: string, task: string) {
  try {
    const now = new Date().toISOString().replace(/\.\d+Z$/, 'Z')
    await redis.set(`cabinet:schedule:last-run:${officer}:${task}`, now)
    revalidatePath('/crons')
    return { success: true }
  } catch (err) {
    return { error: err instanceof Error ? err.message : 'Failed to reset timer' }
  }
}

export async function deleteTaskTimer(officer: string, task: string) {
  try {
    await redis.del(`cabinet:schedule:last-run:${officer}:${task}`)
    revalidatePath('/crons')
    return { success: true }
  } catch (err) {
    return { error: err instanceof Error ? err.message : 'Failed to delete task' }
  }
}

export async function createTaskTimer(
  _prev: { error?: string; success?: boolean } | null,
  formData: FormData
) {
  const officer = formData.get('officer') as string
  const task = formData.get('task') as string

  if (!officer || !task) {
    return { error: 'Officer and task name are required' }
  }

  if (!/^[a-z-]+$/.test(task)) {
    return { error: 'Task name must be lowercase with dashes (e.g. research-sweep)' }
  }

  try {
    const now = new Date().toISOString().replace(/\.\d+Z$/, 'Z')
    await redis.set(`cabinet:schedule:last-run:${officer}:${task}`, now)
    revalidatePath('/crons')
    return { success: true }
  } catch (err) {
    return { error: err instanceof Error ? err.message : 'Failed to create task' }
  }
}
