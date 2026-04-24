// Spec 032 Card 3 — linear.ts task-summary wrapper coverage.
// getLinearTasks queries Linear GraphQL, buckets issues into
// inProgress/todo/blocked counts + 3 most-recent. Pinning the bucketing
// rules + env short-circuit + response-error fallbacks.
//
// NB: gql() does not try/catch fetch() itself, so a network-error throw
// propagates up through getLinearTasks. That's an existing behavior —
// we don't test the throw path here to avoid pinning a latent fix surface.

import { beforeEach, afterEach, describe, it, expect, vi } from 'vitest'

import { getLinearTasks } from './linear'

type FetchMock = ReturnType<typeof vi.fn>

function mockResp(body: unknown, init: { ok?: boolean; status?: number } = {}): Response {
  return {
    ok: init.ok ?? true,
    status: init.status ?? 200,
    json: async () => body,
  } as unknown as Response
}

function node(
  overrides: Partial<{
    id: string
    title: string
    url: string
    updatedAt: string
    state: { name: string; type: string }
    labels: { nodes: { name: string }[] }
  }> = {}
) {
  return {
    id: overrides.id ?? 'iss-1',
    title: overrides.title ?? 'Task title',
    url: overrides.url ?? 'https://linear.app/sen/issue/iss-1',
    updatedAt: overrides.updatedAt ?? '2026-04-24T09:00:00Z',
    state: overrides.state ?? { name: 'In Progress', type: 'started' },
    labels: overrides.labels ?? { nodes: [] },
  }
}

describe('getLinearTasks — env short-circuit', () => {
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
    const result = await getLinearTasks()
    expect(result).toEqual({
      configured: false,
      inProgress: 0,
      todo: 0,
      blocked: 0,
      recent: [],
    })
    expect(fetchMock).not.toHaveBeenCalled()
  })
})

describe('getLinearTasks — response error handling', () => {
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

  it('returns configured=true+zeros when HTTP response is non-ok', async () => {
    fetchMock.mockResolvedValueOnce(mockResp(null, { ok: false, status: 500 }))
    const result = await getLinearTasks()
    expect(result).toEqual({
      configured: true,
      inProgress: 0,
      todo: 0,
      blocked: 0,
      recent: [],
    })
  })

  it('returns configured=true+zeros when GraphQL errors present', async () => {
    fetchMock.mockResolvedValueOnce(mockResp({ errors: [{ message: 'auth failed' }] }))
    const result = await getLinearTasks()
    expect(result.configured).toBe(true)
    expect(result.inProgress).toBe(0)
    expect(result.recent).toEqual([])
  })

  it('returns configured=true+zeros when data is missing', async () => {
    fetchMock.mockResolvedValueOnce(mockResp({}))
    const result = await getLinearTasks()
    expect(result).toEqual({
      configured: true,
      inProgress: 0,
      todo: 0,
      blocked: 0,
      recent: [],
    })
  })

  it('returns configured=true+zeros when issues.nodes is missing', async () => {
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: {} } }))
    const result = await getLinearTasks()
    expect(result.configured).toBe(true)
    expect(result.inProgress).toBe(0)
  })

  it('returns configured=true+zeros for empty nodes array', async () => {
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: { nodes: [] } } }))
    const result = await getLinearTasks()
    expect(result).toEqual({
      configured: true,
      inProgress: 0,
      todo: 0,
      blocked: 0,
      recent: [],
    })
  })
})

describe('getLinearTasks — bucketing by state type', () => {
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

  it("buckets stateType='started' into inProgress", async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: { issues: { nodes: [node({ state: { name: 'In Progress', type: 'started' } })] } },
      })
    )
    const result = await getLinearTasks()
    expect(result.inProgress).toBe(1)
    expect(result.todo).toBe(0)
    expect(result.blocked).toBe(0)
  })

  it("buckets stateType='unstarted' into todo", async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: { issues: { nodes: [node({ state: { name: 'Todo', type: 'unstarted' } })] } },
      })
    )
    const result = await getLinearTasks()
    expect(result.todo).toBe(1)
    expect(result.inProgress).toBe(0)
  })

  it("buckets stateType='backlog' into todo", async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: { issues: { nodes: [node({ state: { name: 'Backlog', type: 'backlog' } })] } },
      })
    )
    const result = await getLinearTasks()
    expect(result.todo).toBe(1)
  })

  it("buckets stateType='blocked' into blocked", async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: { issues: { nodes: [node({ state: { name: 'Blocked', type: 'blocked' } })] } },
      })
    )
    const result = await getLinearTasks()
    expect(result.blocked).toBe(1)
    expect(result.inProgress).toBe(0)
  })

  it('ignores nodes with unknown stateType (no bucket increment)', async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: { issues: { nodes: [node({ state: { name: '??', type: 'mystery_state' } })] } },
      })
    )
    const result = await getLinearTasks()
    expect(result.inProgress).toBe(0)
    expect(result.todo).toBe(0)
    expect(result.blocked).toBe(0)
    // But recent still includes the node
    expect(result.recent).toHaveLength(1)
  })

  it('handles missing state field (optional chaining → empty string type)', async () => {
    const rawNode = { id: 'x', title: 'T', url: 'u', updatedAt: 'd', labels: { nodes: [] } }
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: { nodes: [rawNode] } } }))
    const result = await getLinearTasks()
    expect(result.inProgress).toBe(0)
    expect(result.todo).toBe(0)
    expect(result.recent[0].state).toBe('Unknown') // fallback in recent mapping
  })
})

describe('getLinearTasks — bucketing by label (blocked override)', () => {
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

  it("label 'blocked' routes to blocked even if stateType='started'", async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [
              node({
                state: { name: 'In Progress', type: 'started' },
                labels: { nodes: [{ name: 'blocked' }] },
              }),
            ],
          },
        },
      })
    )
    const result = await getLinearTasks()
    expect(result.blocked).toBe(1)
    expect(result.inProgress).toBe(0)
  })

  it("label 'founder-action' routes to blocked even if stateType='unstarted'", async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [
              node({
                state: { name: 'Todo', type: 'unstarted' },
                labels: { nodes: [{ name: 'founder-action' }] },
              }),
            ],
          },
        },
      })
    )
    const result = await getLinearTasks()
    expect(result.blocked).toBe(1)
    expect(result.todo).toBe(0)
  })

  it('label comparison is case-insensitive (BLOCKED → blocked)', async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [
              node({
                state: { name: 'In Progress', type: 'started' },
                labels: { nodes: [{ name: 'BLOCKED' }] },
              }),
              node({
                id: 'iss-2',
                state: { name: 'Todo', type: 'unstarted' },
                labels: { nodes: [{ name: 'Founder-Action' }] },
              }),
            ],
          },
        },
      })
    )
    const result = await getLinearTasks()
    expect(result.blocked).toBe(2)
    expect(result.inProgress).toBe(0)
    expect(result.todo).toBe(0)
  })
})

describe('getLinearTasks — mixed bucketing + recent slice', () => {
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

  it('counts 5 mixed nodes correctly', async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [
              node({ id: 'a', state: { name: 'In Progress', type: 'started' } }),
              node({ id: 'b', state: { name: 'In Progress', type: 'started' } }),
              node({ id: 'c', state: { name: 'Todo', type: 'unstarted' } }),
              node({ id: 'd', state: { name: 'Backlog', type: 'backlog' } }),
              node({
                id: 'e',
                state: { name: 'Todo', type: 'unstarted' },
                labels: { nodes: [{ name: 'blocked' }] },
              }),
            ],
          },
        },
      })
    )
    const result = await getLinearTasks()
    expect(result.inProgress).toBe(2)
    expect(result.todo).toBe(2)
    expect(result.blocked).toBe(1)
  })

  it('recent returns first 3 nodes (API ordering preserved)', async () => {
    fetchMock.mockResolvedValueOnce(
      mockResp({
        data: {
          issues: {
            nodes: [
              node({ id: 'first', title: '1st', updatedAt: '2026-04-24T09:00:00Z' }),
              node({ id: 'second', title: '2nd', updatedAt: '2026-04-24T08:00:00Z' }),
              node({ id: 'third', title: '3rd', updatedAt: '2026-04-24T07:00:00Z' }),
              node({ id: 'fourth', title: '4th', updatedAt: '2026-04-24T06:00:00Z' }),
              node({ id: 'fifth', title: '5th', updatedAt: '2026-04-24T05:00:00Z' }),
            ],
          },
        },
      })
    )
    const result = await getLinearTasks()
    expect(result.recent).toHaveLength(3)
    expect(result.recent.map((r) => r.id)).toEqual(['first', 'second', 'third'])
    expect(result.recent.map((r) => r.title)).toEqual(['1st', '2nd', '3rd'])
  })

  it('recent maps state.name (falls back to "Unknown" if state absent)', async () => {
    const rawNodeMissingState = {
      id: 'no-state',
      title: 'Lost soul',
      url: 'u',
      updatedAt: 'd',
      labels: { nodes: [] },
    }
    fetchMock.mockResolvedValueOnce(
      mockResp({ data: { issues: { nodes: [rawNodeMissingState] } } })
    )
    const result = await getLinearTasks()
    expect(result.recent[0].state).toBe('Unknown')
    expect(result.recent[0].title).toBe('Lost soul')
  })

  it('recent is empty when nodes is empty (not null or undefined)', async () => {
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: { nodes: [] } } }))
    const result = await getLinearTasks()
    expect(result.recent).toEqual([])
    expect(Array.isArray(result.recent)).toBe(true)
  })
})

describe('getLinearTasks — request shape', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    process.env.LINEAR_API_KEY = 'my-linear-key'
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    delete process.env.LINEAR_API_KEY
  })

  it('POSTs to the Linear GraphQL endpoint', async () => {
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: { nodes: [] } } }))
    await getLinearTasks()
    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toBe('https://api.linear.app/graphql')
    expect(init.method).toBe('POST')
  })

  it('sends Authorization as raw API key (Linear quirk — not "Bearer X")', async () => {
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: { nodes: [] } } }))
    await getLinearTasks()
    const [, init] = fetchMock.mock.calls[0]
    // Linear auth spec: the key itself, not prefixed with Bearer.
    expect(init.headers.Authorization).toBe('my-linear-key')
    expect(init.headers.Authorization).not.toMatch(/^Bearer/)
  })

  it('body is JSON with query + variables', async () => {
    fetchMock.mockResolvedValueOnce(mockResp({ data: { issues: { nodes: [] } } }))
    await getLinearTasks()
    const [, init] = fetchMock.mock.calls[0]
    expect(init.headers['Content-Type']).toBe('application/json')
    const body = JSON.parse(init.body as string)
    expect(typeof body.query).toBe('string')
    expect(body.query).toContain('issues')
    expect(body.variables).toEqual({})
  })
})
