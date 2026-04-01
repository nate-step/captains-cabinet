'use server'

import { dockerExec } from '@/lib/docker'
import redis from '@/lib/redis'
import { revalidatePath } from 'next/cache'

export async function startOfficer(role: string) {
  try {
    await dockerExec(
      `source /opt/founders-cabinet/cabinet/.env && export $(grep -v "^#" /opt/founders-cabinet/cabinet/.env | xargs) && bash /opt/founders-cabinet/cabinet/scripts/start-officer.sh ${role}`
    )
    await redis.set(`cabinet:officer:expected:${role}`, 'active')
    revalidatePath('/officers')
    revalidatePath('/')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to start officer',
    }
  }
}

export async function stopOfficer(role: string) {
  try {
    await dockerExec(`tmux kill-window -t cabinet:officer-${role}`)
    await redis.set(`cabinet:officer:expected:${role}`, 'stopped')
    revalidatePath('/officers')
    revalidatePath('/')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to stop officer',
    }
  }
}

export async function restartOfficer(role: string) {
  try {
    await dockerExec(`tmux kill-window -t cabinet:officer-${role}`)
    // Brief delay to let tmux clean up
    await new Promise((resolve) => setTimeout(resolve, 2000))
    await dockerExec(
      `source /opt/founders-cabinet/cabinet/.env && export $(grep -v "^#" /opt/founders-cabinet/cabinet/.env | xargs) && bash /opt/founders-cabinet/cabinet/scripts/start-officer.sh ${role}`
    )
    await redis.set(`cabinet:officer:expected:${role}`, 'active')
    revalidatePath('/officers')
    revalidatePath('/')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to restart officer',
    }
  }
}

export async function createOfficer(
  _prevState: { error?: string; success?: boolean } | null,
  formData: FormData
) {
  const abbrev = (formData.get('abbreviation') as string).toLowerCase()
  const title = formData.get('title') as string
  const domain = formData.get('domain') as string
  const botUsername = formData.get('botUsername') as string
  const botToken = formData.get('botToken') as string

  if (!/^[a-z]{2,4}$/.test(abbrev)) {
    return { error: 'Abbreviation must be 2-4 lowercase letters' }
  }

  if (!title || !domain || !botUsername || !botToken) {
    return { error: 'All fields are required' }
  }

  try {
    await dockerExec(
      `source /opt/founders-cabinet/cabinet/.env && export $(grep -v "^#" /opt/founders-cabinet/cabinet/.env | xargs) && bash /opt/founders-cabinet/cabinet/scripts/create-officer.sh "${abbrev}" "${title}" "${domain}" "${botUsername}" "${botToken}"`
    )
    revalidatePath('/officers')
    revalidatePath('/')
    return { success: true }
  } catch (err) {
    return {
      error: err instanceof Error ? err.message : 'Failed to create officer',
    }
  }
}
