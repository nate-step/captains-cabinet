/**
 * linear-tasks.ts — Captain column data source for Spec 038 /tasks page.
 *
 * Queries Linear for founder-action labelled issues, grouped into the four
 * dashboard buckets: wip (in-progress), blocked, queue (todo/backlog), done (last 3).
 *
 * Cached at fetch level (30s revalidate) — not via React cache, to keep
 * it compatible with both RSC and route handlers.
 *
 * Reuses the base gql() pattern from linear.ts.
 */

const LINEAR_API = 'https://api.linear.app/graphql'

export interface CaptainTask {
  id: string
  title: string
  url: string
  state: string
  stateType: string
  updatedAt: string
  labels: string[]
}

export interface CaptainTasksBoard {
  configured: boolean
  wip: CaptainTask[]
  blocked: CaptainTask[]
  queue: CaptainTask[]
  done: CaptainTask[] // last 3
}

async function linearGql(q: string, variables: Record<string, unknown> = {}): Promise<unknown> {
  const apiKey = process.env.LINEAR_API_KEY
  if (!apiKey) return null

  try {
    const res = await fetch(LINEAR_API, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: apiKey,
      },
      body: JSON.stringify({ query: q, variables }),
      next: { revalidate: 30 }, // 30s cache per spec §3.2
    })
    if (!res.ok) return null
    const json = (await res.json()) as { data?: unknown; errors?: unknown }
    if (json.errors) {
      console.error('[linear-tasks] GraphQL errors', json.errors)
      return null
    }
    return json.data
  } catch (err) {
    console.error('[linear-tasks] fetch error', err)
    return null
  }
}

interface LinearNode {
  id: string
  title: string
  url: string
  updatedAt: string
  state?: { name: string; type: string }
  labels?: { nodes: { name: string }[] }
}

interface LinearData {
  issues: { nodes: LinearNode[] }
}

export async function getLinearFounderActions(): Promise<CaptainTasksBoard> {
  if (!process.env.LINEAR_API_KEY) {
    return { configured: false, wip: [], blocked: [], queue: [], done: [] }
  }

  const data = (await linearGql(`
    query FounderActions {
      issues(
        first: 50
        filter: {
          labels: { name: { eq: "founder-action" } }
        }
        orderBy: updatedAt
      ) {
        nodes {
          id
          title
          url
          updatedAt
          state { name type }
          labels { nodes { name } }
        }
      }
    }
  `)) as LinearData | null

  if (!data?.issues?.nodes) {
    return { configured: true, wip: [], blocked: [], queue: [], done: [] }
  }

  const wip: CaptainTask[] = []
  const blocked: CaptainTask[] = []
  const queue: CaptainTask[] = []
  const done: CaptainTask[] = []

  for (const node of data.issues.nodes) {
    const stateType = node.state?.type ?? ''
    const stateName = node.state?.name ?? 'Unknown'
    const labels = (node.labels?.nodes ?? []).map((l) => l.name.toLowerCase())

    const task: CaptainTask = {
      id: node.id,
      title: node.title,
      url: node.url,
      state: stateName,
      stateType,
      updatedAt: node.updatedAt,
      labels,
    }

    const isBlocked = labels.includes('blocked')
    const isCompleted = stateType === 'completed' || stateType === 'cancelled'

    if (isCompleted) {
      done.push(task)
    } else if (isBlocked) {
      blocked.push(task)
    } else if (stateType === 'started') {
      wip.push(task)
    } else {
      queue.push(task)
    }
  }

  // Done: only last 3
  done.sort((a, b) => new Date(b.updatedAt).getTime() - new Date(a.updatedAt).getTime())

  return {
    configured: true,
    wip,
    blocked,
    queue,
    done: done.slice(0, 3),
  }
}
