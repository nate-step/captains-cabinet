'use server'

import { dockerWriteFile } from '@/lib/docker'
import { revalidatePath } from 'next/cache'

const AGENTS_DIR = '/opt/founders-cabinet/.claude/agents'
const LOOP_PROMPTS_DIR = '/opt/founders-cabinet/cabinet/loop-prompts'

export async function updateRoleDefinition(role: string, content: string) {
  try {
    if (!/^[a-z]{2,4}$/.test(role)) {
      return { success: false, error: 'Invalid role identifier' }
    }
    await dockerWriteFile(`${AGENTS_DIR}/${role}.md`, content)
    revalidatePath(`/officers/${role}`)
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to update role definition',
    }
  }
}

export async function updateLoopPrompt(role: string, content: string) {
  try {
    if (!/^[a-z]{2,4}$/.test(role)) {
      return { success: false, error: 'Invalid role identifier' }
    }
    await dockerWriteFile(`${LOOP_PROMPTS_DIR}/${role}.txt`, content)
    revalidatePath(`/officers/${role}`)
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to update loop prompt',
    }
  }
}
