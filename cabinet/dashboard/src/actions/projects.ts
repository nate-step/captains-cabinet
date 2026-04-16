'use server'

import { dockerExec } from '@/lib/docker'
import redis from '@/lib/redis'
import { revalidatePath } from 'next/cache'

const IS_MOCK = process.env.MOCK_DATA === 'true' || !process.env.REDIS_URL

export interface ProjectInfo {
  slug: string
  name: string
  active: boolean
}

export async function switchProject(slug: string): Promise<{ success: boolean; error?: string }> {
  try {
    if (IS_MOCK) {
      console.log(`[mock] Would switch to project: ${slug}`)
      return { success: true }
    }
    const safeSlug = slug.replace(/[^a-z0-9_-]/g, '')
    await dockerExec(`bash /opt/founders-cabinet/cabinet/scripts/switch-project.sh ${safeSlug}`)
    revalidatePath('/')
    revalidatePath('/settings')
    return { success: true }
  } catch (err) {
    return {
      success: false,
      error: err instanceof Error ? err.message : 'Failed to switch project',
    }
  }
}

export async function getActiveProject(): Promise<string> {
  if (IS_MOCK) {
    return 'sensed'
  }
  try {
    const redisValue = await redis.get('cabinet:active-project')
    if (redisValue) return redisValue
    const { stdout } = await dockerExec('cat /opt/founders-cabinet/instance/config/active-project.txt 2>/dev/null || echo sensed')
    return stdout.trim() || 'sensed'
  } catch {
    return 'sensed'
  }
}

export async function getProjects(): Promise<ProjectInfo[]> {
  if (IS_MOCK) {
    return [
      { slug: 'sensed', name: 'Sensed', active: true },
      { slug: 'demo-project', name: 'Demo Project', active: false },
    ]
  }

  try {
    const activeSlug = await getActiveProject()
    const { stdout } = await dockerExec(
      `for f in /opt/founders-cabinet/instance/config/projects/*.yml; do
        slug=$(basename "$f" .yml)
        name=$(grep -m1 "^  name:" "$f" 2>/dev/null | sed 's/.*name: *//')
        [ -z "$name" ] && name=$(grep -m1 "name:" "$f" 2>/dev/null | sed 's/.*name: *//')
        echo "$slug|$name"
      done`
    )

    const projects: ProjectInfo[] = stdout
      .split('\n')
      .filter((line) => line.includes('|'))
      .filter((line) => !line.split('|')[0].trim().startsWith('_'))
      .map((line) => {
        const [slug, name] = line.split('|')
        return {
          slug: slug.trim(),
          name: name.trim() || slug.trim(),
          active: slug.trim() === activeSlug,
        }
      })

    if (projects.length === 0) {
      return [{ slug: 'sensed', name: 'Sensed', active: true }]
    }

    return projects
  } catch {
    return [{ slug: 'sensed', name: 'Sensed', active: true }]
  }
}
