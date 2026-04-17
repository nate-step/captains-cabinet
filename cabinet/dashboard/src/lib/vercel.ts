/**
 * vercel.ts — Tiny Vercel deploy-status wrapper for Spec 032 Card 0 (YOUR PRODUCTS).
 *
 * Fetches the latest production deployment for the given Vercel project.
 * Gracefully falls back if VERCEL_API_TOKEN or VERCEL_PROJECT_ID are missing.
 */

export type VercelDeployStatus = 'READY' | 'ERROR' | 'BUILDING' | 'QUEUED' | 'CANCELED' | 'unknown'

export interface VercelDeployInfo {
  configured: boolean
  status: VercelDeployStatus
  /** ISO timestamp of the deployment created-at time */
  createdAt: string | null
  /** How many seconds ago the deploy was created */
  ageSeconds: number | null
  url: string | null
}

const VERCEL_API = 'https://api.vercel.com'

export async function getLatestProdDeploy(): Promise<VercelDeployInfo> {
  const token = process.env.VERCEL_API_TOKEN
  const projectId = process.env.VERCEL_PROJECT_ID
  const teamId = process.env.VERCEL_TEAM_ID // optional

  if (!token || !projectId) {
    return { configured: false, status: 'unknown', createdAt: null, ageSeconds: null, url: null }
  }

  try {
    const teamParam = teamId ? `&teamId=${encodeURIComponent(teamId)}` : ''
    const res = await fetch(
      `${VERCEL_API}/v6/deployments?projectId=${encodeURIComponent(projectId)}&target=production&limit=1${teamParam}`,
      {
        headers: { Authorization: `Bearer ${token}` },
        next: { revalidate: 60 },
      }
    )

    if (!res.ok) {
      console.error('[vercel] deploy fetch failed', res.status)
      return { configured: true, status: 'unknown', createdAt: null, ageSeconds: null, url: null }
    }

    const json = (await res.json()) as {
      deployments?: {
        uid: string
        state: string
        createdAt: number
        url: string
      }[]
    }

    const deploy = json.deployments?.[0]
    if (!deploy) {
      return { configured: true, status: 'unknown', createdAt: null, ageSeconds: null, url: null }
    }

    const createdAt = new Date(deploy.createdAt).toISOString()
    const ageSeconds = Math.floor((Date.now() - deploy.createdAt) / 1000)
    const rawState = deploy.state?.toUpperCase() as VercelDeployStatus
    const status: VercelDeployStatus =
      rawState === 'READY' ||
      rawState === 'ERROR' ||
      rawState === 'BUILDING' ||
      rawState === 'QUEUED' ||
      rawState === 'CANCELED'
        ? rawState
        : 'unknown'

    return {
      configured: true,
      status,
      createdAt,
      ageSeconds,
      url: `https://${deploy.url}`,
    }
  } catch (err) {
    console.error('[vercel] deploy fetch error', err)
    return { configured: true, status: 'unknown', createdAt: null, ageSeconds: null, url: null }
  }
}
