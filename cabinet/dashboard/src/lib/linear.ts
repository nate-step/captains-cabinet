/**
 * linear.ts — Tiny Linear GraphQL wrapper for Spec 032 Card 3 (YOUR TASKS).
 *
 * Returns task counts and recent state changes. Handles missing LINEAR_API_KEY
 * gracefully — returns a "not configured" sentinel so the card can render the
 * appropriate empty state (spec §7 / AC #16).
 */

export interface LinearTaskSummary {
  configured: boolean
  inProgress: number
  todo: number
  blocked: number
  recent: LinearRecentItem[]
}

export interface LinearRecentItem {
  id: string
  title: string
  state: string
  url: string
  updatedAt: string
}

const LINEAR_API = 'https://api.linear.app/graphql'

async function gql(query: string, variables: Record<string, unknown> = {}): Promise<unknown> {
  const apiKey = process.env.LINEAR_API_KEY
  if (!apiKey) return null

  const res = await fetch(LINEAR_API, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: apiKey,
    },
    body: JSON.stringify({ query, variables }),
    next: { revalidate: 120 }, // 2-min cache
  })

  if (!res.ok) {
    console.error('[linear] GraphQL request failed', res.status)
    return null
  }

  const json = (await res.json()) as { data?: unknown; errors?: unknown }
  if (json.errors) {
    console.error('[linear] GraphQL errors', json.errors)
    return null
  }
  return json.data
}

interface LinearNode {
  id: string
  title: string
  url: string
  updatedAt: string
  state?: { name: string; type: string }
  labels?: { nodes: { name: string }[] }
}

interface LinearIssuesData {
  issues: {
    nodes: LinearNode[]
    pageInfo?: { hasNextPage: boolean }
  }
}

export async function getLinearTasks(): Promise<LinearTaskSummary> {
  const apiKey = process.env.LINEAR_API_KEY
  if (!apiKey) {
    return { configured: false, inProgress: 0, todo: 0, blocked: 0, recent: [] }
  }

  // Fetch recent issues (last 50 by updatedAt) — we'll bucket them client-side.
  const data = await gql(`
    query ConsumerDashboard {
      issues(
        first: 50
        orderBy: updatedAt
        filter: {
          state: { type: { nin: ["cancelled", "completed"] } }
        }
      ) {
        nodes {
          id
          title
          url
          updatedAt
          state {
            name
            type
          }
          labels {
            nodes { name }
          }
        }
      }
    }
  `) as LinearIssuesData | null

  if (!data?.issues?.nodes) {
    // API configured but returned nothing — treat as zero counts, configured.
    return { configured: true, inProgress: 0, todo: 0, blocked: 0, recent: [] }
  }

  const nodes = data.issues.nodes
  let inProgress = 0
  let todo = 0
  let blocked = 0

  for (const node of nodes) {
    const stateType = node.state?.type ?? ''
    const labels = node.labels?.nodes.map((l) => l.name.toLowerCase()) ?? []
    const isBlocked =
      labels.includes('blocked') ||
      labels.includes('founder-action') ||
      stateType === 'blocked'

    if (isBlocked) {
      blocked++
    } else if (stateType === 'started') {
      inProgress++
    } else if (stateType === 'unstarted' || stateType === 'backlog') {
      todo++
    }
  }

  // Last 3 by updatedAt (nodes already ordered by updatedAt desc from API)
  const recent: LinearRecentItem[] = nodes.slice(0, 3).map((n) => ({
    id: n.id,
    title: n.title,
    state: n.state?.name ?? 'Unknown',
    url: n.url,
    updatedAt: n.updatedAt,
  }))

  return { configured: true, inProgress, todo, blocked, recent }
}
