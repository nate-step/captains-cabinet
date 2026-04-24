// Spec 032 Card 0 — sentry.ts unresolved-issues wrapper coverage.
// Same fetch-stub pattern as vercel.test.ts: env read per-call, so
// beforeEach env-set + vi.stubGlobal('fetch') works cleanly.
//
// Surface pinned: env short-circuit (three-way: token/org/project), fetch
// non-ok + throw fallbacks, array.length counting, SPIKE_THRESHOLD=10 gate,
// non-array response defaults to 0, URL encoding of org + project, query
// string shape, Bearer Authorization, since=~24h-ago. Regression in any of
// these leaks bad spike signal or crash to the Card 0 UI.

import { beforeEach, afterEach, describe, it, expect, vi } from 'vitest'

import { getSentryStats } from './sentry'

type FetchMock = ReturnType<typeof vi.fn>

function mockFetchOnce(body: unknown, init: { ok?: boolean; status?: number } = {}): Response {
  return {
    ok: init.ok ?? true,
    status: init.status ?? 200,
    json: async () => body,
  } as unknown as Response
}

function setEnv(token?: string, org?: string, project?: string) {
  if (token === undefined) delete process.env.SENTRY_AUTH_TOKEN
  else process.env.SENTRY_AUTH_TOKEN = token
  if (org === undefined) delete process.env.SENTRY_ORG
  else process.env.SENTRY_ORG = org
  if (project === undefined) delete process.env.SENTRY_PROJECT
  else process.env.SENTRY_PROJECT = project
}

describe('getSentryStats — env short-circuit', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    setEnv() // clear all
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('returns configured=false when token is missing', async () => {
    setEnv(undefined, 'my-org', 'my-proj')
    const result = await getSentryStats()
    expect(result).toEqual({ configured: false, issues24h: null, isSpiking: false })
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('returns configured=false when org is missing', async () => {
    setEnv('tok', undefined, 'my-proj')
    const result = await getSentryStats()
    expect(result.configured).toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('returns configured=false when project is missing', async () => {
    setEnv('tok', 'my-org', undefined)
    const result = await getSentryStats()
    expect(result.configured).toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('returns configured=false when all three are missing', async () => {
    const result = await getSentryStats()
    expect(result).toEqual({ configured: false, issues24h: null, isSpiking: false })
    expect(fetchMock).not.toHaveBeenCalled()
  })
})

describe('getSentryStats — fetch response handling', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    setEnv('tok', 'my-org', 'my-proj')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    setEnv()
  })

  it('returns configured=true+null when fetch response is non-ok', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce(null, { ok: false, status: 500 }))
    const result = await getSentryStats()
    expect(result).toEqual({ configured: true, issues24h: null, isSpiking: false })
  })

  it('returns configured=true+null when fetch throws', async () => {
    fetchMock.mockRejectedValueOnce(new Error('network-down'))
    const result = await getSentryStats()
    expect(result).toEqual({ configured: true, issues24h: null, isSpiking: false })
  })

  it('counts issues24h as array length for valid array response', async () => {
    const issues = Array.from({ length: 7 }, (_, i) => ({ id: `issue-${i}` }))
    fetchMock.mockResolvedValueOnce(mockFetchOnce(issues))
    const result = await getSentryStats()
    expect(result.configured).toBe(true)
    expect(result.issues24h).toBe(7)
  })

  it('counts issues24h as 0 when response is not an array', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce({ unexpected: 'shape' }))
    const result = await getSentryStats()
    expect(result.configured).toBe(true)
    expect(result.issues24h).toBe(0)
  })

  it('counts issues24h as 0 for empty array', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce([]))
    const result = await getSentryStats()
    expect(result.issues24h).toBe(0)
    expect(result.isSpiking).toBe(false)
  })
})

describe('getSentryStats — SPIKE_THRESHOLD (>= 10)', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    setEnv('tok', 'my-org', 'my-proj')
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    setEnv()
  })

  it('is not spiking at 9 issues (below threshold)', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce(Array(9).fill({ id: 'x' })))
    const result = await getSentryStats()
    expect(result.issues24h).toBe(9)
    expect(result.isSpiking).toBe(false)
  })

  it('is spiking at exactly 10 issues (threshold boundary, >=)', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce(Array(10).fill({ id: 'x' })))
    const result = await getSentryStats()
    expect(result.issues24h).toBe(10)
    expect(result.isSpiking).toBe(true)
  })

  it('is spiking above 10 issues', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce(Array(50).fill({ id: 'x' })))
    const result = await getSentryStats()
    expect(result.issues24h).toBe(50)
    expect(result.isSpiking).toBe(true)
  })

  it('is not spiking when issues24h is 0 (empty array)', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce([]))
    const result = await getSentryStats()
    expect(result.isSpiking).toBe(false)
  })
})

describe('getSentryStats — request URL shaping', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    setEnv()
  })

  it('URL-encodes org + project in the path', async () => {
    setEnv('tok', 'my org/ns', 'proj&x')
    fetchMock.mockResolvedValueOnce(mockFetchOnce([]))
    await getSentryStats()
    const [url] = fetchMock.mock.calls[0]
    expect(url).toContain('/projects/my%20org%2Fns/proj%26x/issues/')
  })

  it('pins the query string: is:unresolved, limit=100, start=<iso>', async () => {
    setEnv('tok', 'org', 'proj')
    fetchMock.mockResolvedValueOnce(mockFetchOnce([]))
    await getSentryStats()
    const [url] = fetchMock.mock.calls[0] as [string]
    expect(url).toContain('query=is:unresolved')
    expect(url).toContain('limit=100')
    expect(url).toMatch(/start=[^&]+/)
  })

  it('start param is ~24h ago (within 5s of expected)', async () => {
    setEnv('tok', 'org', 'proj')
    fetchMock.mockResolvedValueOnce(mockFetchOnce([]))
    const before = Date.now()
    await getSentryStats()
    const [url] = fetchMock.mock.calls[0] as [string]
    const match = url.match(/start=([^&]+)/)
    expect(match).not.toBeNull()
    const startIso = decodeURIComponent(match![1])
    const startMs = new Date(startIso).getTime()
    const expectedMs = before - 24 * 3600 * 1000
    expect(startMs).toBeGreaterThanOrEqual(expectedMs - 5000)
    expect(startMs).toBeLessThanOrEqual(expectedMs + 5000)
  })

  it('sends Bearer token in Authorization header', async () => {
    setEnv('my-secret-token', 'org', 'proj')
    fetchMock.mockResolvedValueOnce(mockFetchOnce([]))
    await getSentryStats()
    const [, init] = fetchMock.mock.calls[0]
    expect(init.headers.Authorization).toBe('Bearer my-secret-token')
  })

  it('hits the sentry.io api/0 endpoint', async () => {
    setEnv('tok', 'org', 'proj')
    fetchMock.mockResolvedValueOnce(mockFetchOnce([]))
    await getSentryStats()
    const [url] = fetchMock.mock.calls[0]
    expect(url).toMatch(/^https:\/\/sentry\.io\/api\/0\/projects\//)
  })
})
