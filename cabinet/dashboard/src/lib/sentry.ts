/**
 * sentry.ts — Tiny Sentry stats wrapper for Spec 032 Card 0 (YOUR PRODUCTS).
 *
 * Fetches 24h unresolved issue count for the configured Sentry project.
 * Gracefully falls back if SENTRY_AUTH_TOKEN, SENTRY_ORG, or SENTRY_PROJECT
 * env vars are missing.
 */

export interface SentryStats {
  configured: boolean
  /** Number of unresolved issues in the last 24h window */
  issues24h: number | null
  /** Whether this looks like a spike (> threshold) */
  isSpiking: boolean
}

const SENTRY_API = 'https://sentry.io/api/0'
/** Issue count above which we consider the project spiking */
const SPIKE_THRESHOLD = 10

export async function getSentryStats(): Promise<SentryStats> {
  const token = process.env.SENTRY_AUTH_TOKEN
  const org = process.env.SENTRY_ORG
  const project = process.env.SENTRY_PROJECT

  if (!token || !org || !project) {
    return { configured: false, issues24h: null, isSpiking: false }
  }

  try {
    // Fetch unresolved issues from the last 24h
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString()
    const res = await fetch(
      `${SENTRY_API}/projects/${encodeURIComponent(org)}/${encodeURIComponent(project)}/issues/?query=is:unresolved&limit=100&start=${encodeURIComponent(since)}`,
      {
        headers: { Authorization: `Bearer ${token}` },
        next: { revalidate: 120 },
      }
    )

    if (!res.ok) {
      console.error('[sentry] issues fetch failed', res.status)
      return { configured: true, issues24h: null, isSpiking: false }
    }

    const issues = (await res.json()) as unknown[]
    const count = Array.isArray(issues) ? issues.length : 0

    return {
      configured: true,
      issues24h: count,
      isSpiking: count >= SPIKE_THRESHOLD,
    }
  } catch (err) {
    console.error('[sentry] issues fetch error', err)
    return { configured: true, issues24h: null, isSpiking: false }
  }
}
