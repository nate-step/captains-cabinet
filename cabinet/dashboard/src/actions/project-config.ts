'use server'

import { dockerExec } from '@/lib/docker'
import { revalidatePath } from 'next/cache'

const IS_MOCK = process.env.MOCK_DATA === 'true' || !process.env.REDIS_URL

const ASSEMBLE_SCRIPT = '/opt/founders-cabinet/cabinet/scripts/assemble-config.sh'
const PROJECTS_DIR = '/opt/founders-cabinet/instance/config/projects'

// Whitelisted sections that may be edited through this action
const ALLOWED_SECTIONS = ['product', 'notion', 'linear', 'neon', 'telegram']

/**
 * Resolve the active project slug so we know which YAML to edit.
 */
async function getActiveSlug(): Promise<string> {
  if (IS_MOCK) return 'sensed'
  try {
    const { stdout } = await dockerExec(
      'cat /opt/founders-cabinet/instance/config/active-project.txt 2>/dev/null || echo sensed'
    )
    return stdout.trim() || 'sensed'
  } catch {
    return 'sensed'
  }
}

/**
 * Update a field inside the active project's config YAML, then reassemble
 * product.yml so every running officer picks up the change.
 *
 * `section`  — top-level YAML key (must be in ALLOWED_SECTIONS)
 * `path`     — dot-separated path beneath the section, e.g. "team_key" or
 *              "dashboard.page_id"
 * `value`    — the new scalar value to write
 */
export async function updateProjectConfig(
  section: string,
  path: string,
  value: string,
): Promise<{ success: boolean; error?: string }> {
  try {
    if (!ALLOWED_SECTIONS.includes(section)) {
      return { success: false, error: `Section not allowed: ${section}` }
    }

    // Sanitise value for shell interpolation
    const safeValue = value.replace(/'/g, "'\\''")
    const slug = await getActiveSlug()
    const projectFile = `${PROJECTS_DIR}/${slug}.yml`

    if (IS_MOCK) {
      console.log(`[mock] Would update ${section}.${path} = ${value} in ${projectFile}`)
      revalidatePath('/project')
      return { success: true }
    }

    const parts = path.split('.')

    if (parts.length === 1) {
      // Simple field directly under the section, e.g. product.name or linear.team_key
      const field = parts[0]
      await dockerExec(
        `sed -i '/^${section}:/,/^[a-z]/{s/^  ${field}: .*/  ${field}: ${safeValue}/}' ${projectFile}`
      )
    } else if (parts.length === 2) {
      // Nested field, e.g. notion.dashboard.page_id
      const [sub, field] = parts
      await dockerExec(
        `sed -i '/^${section}:/,/^[a-z]/{/^  ${sub}:/,/^  [a-z]/{s/^    ${field}: .*/    ${field}: ${safeValue}/}}' ${projectFile}`
      )
    } else {
      return { success: false, error: `Path too deep: ${path} (max 2 levels)` }
    }

    // Reassemble product.yml from platform + project sources
    await dockerExec(`bash ${ASSEMBLE_SCRIPT}`)

    revalidatePath('/project')
    revalidatePath('/settings')
    revalidatePath('/')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to update project config',
    }
  }
}
