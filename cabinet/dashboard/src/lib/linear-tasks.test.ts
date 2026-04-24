// Spec 038 — linear-tasks.ts Captain column data source coverage.
// getLinearFounderActions queries Linear for founder-action labelled issues
// and buckets into wip/blocked/queue/done (last 3). Pin bucketing, sort,
// and the fail-soft fallbacks that keep /tasks from 500-ing on API blips.
//
// Mirrors the linear.ts / vercel.ts / sentry.ts fetch-stub pattern.

import { beforeEach, afterEach, describe, it, expect, vi } from 'vitest'

import { getLinearFounderActions } from './linear-tasks'

type FetchMock = ReturnType<typeof vi.fn>

function mockResp(body: unknown, init: { ok?: boolean; status?: number } = {}): Response {
  return {
    ok: init.ok ?? true,
    status: init.status ?? 200,
    json: async () => body,
  } as unknown as Response
}

function issueNode(overrides: {
  id?: string
  title?: string
  url?: string
  updatedAt?: string
  state: { name: string; type: string }
  labels?: { name: string }[]
}) {
  return {
    id: overrides.id ?? 'iss-1',
    title: overrides.title ?? 'Task',
    url: overrides.url ?? 'https://linear.app/sen/iss-1',
    updatedAt: overrides.updatedAt ?? '2026-04-24T09:00:00Z',
    state: overrides.state,
    labels: { nodes: overrides.labels ?? [] },
  }
}

const emptyBoard = {
  configured: true,
  wip: [],
  blocked: [],
  queue: [],
  done: [],
} as const

describe('getLinearFounderActions — env short-circuit', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    delete process.env.LINEAR_API_KEY
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('returns configured=false when LINEAR_API_KEY is missing', async () => {
    const result = await getLinearFounderActions()
    expect(result).toEqual({ configured: false, wip: [], blocked: [], queue: [], done: [] })
    expect(fetchMock).not.toHaveBeenCalled()
  })
})

describe('getLinearFounderActions — response error handling', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    process.env.LINEAR_API_KEY = 'lin_tok'
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    delete process.env.LINEAR_API_KEY
  })

  it('returns configured=true+empty when HTTP response is non-ok', async () => {
    fetchMock.mockResolvedValueOnce(mockResp(null, { ok: false, status: 500 }))
    const result = await getLinearFounderActions()
    expect(result).toEqual(emptyBoard)
  })

  it('returns configured=true+empty when GraphQL errors present', async () => {
    fetchMock.mockResolvedValueOnce(mockResp({ errors: [{ message: 'bad query' }] }))
    const result = await getLinearFounderActions()
    expect(result).toEqual(emptyBoard)
  })

  it('returns configured=true+empty when fetch throws', async () => {
    fetchMock.mockRejectedValueOnce(new Error('network-down'))
    const result = await getLinearFounderActions()
    expect(result).toEqual(emptyBoard)
  })

  it('returns configured=true+empty when issues.nodes is missing', async () => {
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: {} } }))
    const result = await getLinearFounderActions()
    expect(result).toEqual(emptyBoard)
  })

  it('returns configured=true+empty for empty nodes array', async () => {
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: { nodes: [] } } }))
    const result = await getLinearFounderActions()
    expect(result).toEqual(emptyBoard)
  })
})

describe('getLinearFounderActions — bucketing (priority: done > blocked > wip > queue)', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    process.env.LINEAR_API_KEY = 'lin_tok'
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    delete process.env.LINEAR_API_KEY
  })

  it("stateType='completed' routes to done", async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [issueNode({ id: 'x', state: { name: 'Done', type: 'completed' } })],
          },
        },
      })
    )
    const result = await getLinearFounderActions()
    expect(result.done).toHaveLength(1)
    expect(result.done[0].id).toBe('x')
  })

  it("stateType='cancelled' also routes to done", async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [issueNode({ id: 'x', state: { name: 'Cancelled', type: 'cancelled' } })],
          },
        },
      })
    )
    const result = await getLinearFounderActions()
    expect(result.done).toHaveLength(1)
  })

  it("label 'blocked' routes to blocked when not completed", async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [
              issueNode({
                id: 'x',
                state: { name: 'In Progress', type: 'started' },
                labels: [{ name: 'blocked' }],
              }),
            ],
          },
        },
      })
    )
    const result = await getLinearFounderActions()
    expect(result.blocked).toHaveLength(1)
    expect(result.wip).toHaveLength(0)
  })

  it("stateType='started' without blocked label → wip", async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [issueNode({ id: 'x', state: { name: 'In Progress', type: 'started' } })],
          },
        },
      })
    )
    const result = await getLinearFounderActions()
    expect(result.wip).toHaveLength(1)
  })

  it("anything else (unstarted/backlog/etc) → queue", async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [
              issueNode({ id: 'a', state: { name: 'Todo', type: 'unstarted' } }),
              issueNode({ id: 'b', state: { name: 'Backlog', type: 'backlog' } }),
              issueNode({ id: 'c', state: { name: '?', type: 'mystery' } }),
            ],
          },
        },
      })
    )
    const result = await getLinearFounderActions()
    expect(result.queue).toHaveLength(3)
  })

  it('completed + blocked label still routes to done (completed takes precedence)', async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [
              issueNode({
                id: 'x',
                state: { name: 'Done', type: 'completed' },
                labels: [{ name: 'blocked' }],
              }),
            ],
          },
        },
      })
    )
    const result = await getLinearFounderActions()
    expect(result.done).toHaveLength(1)
    expect(result.blocked).toHaveLength(0)
  })

  it('label comparison is case-insensitive (BLOCKED → blocked)', async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [
              issueNode({
                state: { name: 'In Progress', type: 'started' },
                labels: [{ name: 'BLOCKED' }],
              }),
            ],
          },
        },
      })
    )
    const result = await getLinearFounderActions()
    expect(result.blocked).toHaveLength(1)
    expect(result.wip).toHaveLength(0)
  })
})

describe('getLinearFounderActions — done slice (last 3 by updatedAt desc)', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    process.env.LINEAR_API_KEY = 'lin_tok'
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    delete process.env.LINEAR_API_KEY
  })

  it('limits done to the 3 most recent by updatedAt desc', async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [
              issueNode({
                id: 'oldest',
                updatedAt: '2026-04-20T09:00:00Z',
                state: { name: 'Done', type: 'completed' },
              }),
              issueNode({
                id: 'newest',
                updatedAt: '2026-04-24T09:00:00Z',
                state: { name: 'Done', type: 'completed' },
              }),
              issueNode({
                id: 'middle',
                updatedAt: '2026-04-22T09:00:00Z',
                state: { name: 'Done', type: 'completed' },
              }),
              issueNode({
                id: 'extra',
                updatedAt: '2026-04-18T09:00:00Z',
                state: { name: 'Done', type: 'completed' },
              }),
              issueNode({
                id: 'another',
                updatedAt: '2026-04-21T09:00:00Z',
                state: { name: 'Done', type: 'completed' },
              }),
            ],
          },
        },
      })
    )
    const result = await getLinearFounderActions()
    expect(result.done).toHaveLength(3)
    expect(result.done.map((t) => t.id)).toEqual(['newest', 'middle', 'another'])
  })

  it('does not slice wip/blocked/queue (only done capped at 3)', async () => {
    const nodes = Array.from({ length: 5 }, (_, i) =>
      issueNode({
        id: `wip-${i}`,
        state: { name: 'In Progress', type: 'started' },
        updatedAt: `2026-04-24T0${i}:00:00Z`,
      })
    )
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: { nodes } } }))
    const result = await getLinearFounderActions()
    expect(result.wip).toHaveLength(5)
  })

  it('done preserves task fields (id/title/url/state/stateType/updatedAt/labels)', async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [
              issueNode({
                id: 'done-1',
                title: 'Done task',
                url: 'https://linear.app/done-1',
                updatedAt: '2026-04-24T09:00:00Z',
                state: { name: 'Done', type: 'completed' },
                labels: [{ name: 'founder-action' }, { name: 'P0' }],
              }),
            ],
          },
        },
      })
    )
    const result = await getLinearFounderActions()
    expect(result.done[0]).toEqual({
      id: 'done-1',
      title: 'Done task',
      url: 'https://linear.app/done-1',
      state: 'Done',
      stateType: 'completed',
      updatedAt: '2026-04-24T09:00:00Z',
      labels: ['founder-action', 'p0'], // lowercased per source
    })
  })
})

describe('getLinearFounderActions — edge cases', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    process.env.LINEAR_API_KEY = 'lin_tok'
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    delete process.env.LINEAR_API_KEY
  })

  it('handles missing state field (stateType="" fallback → queue, state="Unknown")', async () => {
    const rawNode = {
      id: 'x',
      title: 'Missing state',
      url: 'u',
      updatedAt: '2026-04-24T09:00:00Z',
      labels: { nodes: [] },
    }
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: { nodes: [rawNode] } } }))
    const result = await getLinearFounderActions()
    expect(result.queue).toHaveLength(1)
    expect(result.queue[0].state).toBe('Unknown')
    expect(result.queue[0].stateType).toBe('')
  })

  it('handles missing labels field (defaults to empty array)', async () => {
    const rawNode = {
      id: 'x',
      title: 'No labels key',
      url: 'u',
      updatedAt: '2026-04-24T09:00:00Z',
      state: { name: 'In Progress', type: 'started' },
    }
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: { nodes: [rawNode] } } }))
    const result = await getLinearFounderActions()
    expect(result.wip).toHaveLength(1)
    expect(result.wip[0].labels).toEqual([])
  })
})
