// Spec 032 Card 0 — vercel.ts deploy-status wrapper coverage.
// getLatestProdDeploy reads env per-call (no module-load capture), so a
// clean fetch-stub pattern works without dynamic imports.
//
// Surface pinned: env short-circuit, fetch non-ok fallback, empty-deployments
// fallback, state normalization (whitelist → direct, anything else → 'unknown'),
// case-normalization via toUpperCase, ISO timestamp conversion, ageSeconds
// monotonicity, URL https:// prefix, optional teamId query param, and the
// throw-to-unknown contract. A regression in any of these would leak stale
// or malformed deploy status to the Card 0 UI.

import { beforeEach, afterEach, describe, it, expect, vi } from 'vitest'

import { getLatestProdDeploy } from './vercel'

type FetchMock = ReturnType<typeof vi.fn>

function mockFetchOnce(body: unknown, init: { ok?: boolean; status?: number } = {}): Response {
  return {
    ok: init.ok ?? true,
    status: init.status ?? 200,
    json: async () => body,
  } as unknown as Response
}

describe('getLatestProdDeploy — env short-circuit', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    // Ensure a clean slate per test
    delete process.env.VERCEL_API_TOKEN
    delete process.env.VERCEL_PROJECT_ID
    delete process.env.VERCEL_TEAM_ID
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('returns configured=false when token is missing', async () => {
    process.env.VERCEL_PROJECT_ID = 'proj_abc' // only projectId set
    const result = await getLatestProdDeploy()
    expect(result).toEqual({
      configured: false,
      status: 'unknown',
      createdAt: null,
      ageSeconds: null,
      url: null,
    })
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('returns configured=false when projectId is missing', async () => {
    process.env.VERCEL_API_TOKEN = 'tok' // only token set
    const result = await getLatestProdDeploy()
    expect(result.configured).toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('returns configured=false when both are missing', async () => {
    const result = await getLatestProdDeploy()
    expect(result.configured).toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
  })
})

describe('getLatestProdDeploy — fetch response handling', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    process.env.VERCEL_API_TOKEN = 'test-token'
    process.env.VERCEL_PROJECT_ID = 'proj_abc'
    delete process.env.VERCEL_TEAM_ID
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('returns configured=true+unknown when fetch response is non-ok', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce(null, { ok: false, status: 500 }))
    const result = await getLatestProdDeploy()
    expect(result).toEqual({
      configured: true,
      status: 'unknown',
      createdAt: null,
      ageSeconds: null,
      url: null,
    })
  })

  it('returns configured=true+unknown when deployments array is missing', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce({}))
    const result = await getLatestProdDeploy()
    expect(result.configured).toBe(true)
    expect(result.status).toBe('unknown')
    expect(result.createdAt).toBeNull()
  })

  it('returns configured=true+unknown when deployments array is empty', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce({ deployments: [] }))
    const result = await getLatestProdDeploy()
    expect(result.configured).toBe(true)
    expect(result.status).toBe('unknown')
  })

  it('returns configured=true+unknown when fetch throws', async () => {
    fetchMock.mockRejectedValueOnce(new Error('network-down'))
    const result = await getLatestProdDeploy()
    expect(result).toEqual({
      configured: true,
      status: 'unknown',
      createdAt: null,
      ageSeconds: null,
      url: null,
    })
  })
})

describe('getLatestProdDeploy — state normalization', () => {
  let fetchMock: FetchMock

  const baseDeploy = {
    uid: 'dpl_x',
    createdAt: Date.now() - 60_000, // 60s ago
    url: 'my-app.vercel.app',
  }

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    process.env.VERCEL_API_TOKEN = 'test-token'
    process.env.VERCEL_PROJECT_ID = 'proj_abc'
    delete process.env.VERCEL_TEAM_ID
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it.each(['READY', 'ERROR', 'BUILDING', 'QUEUED', 'CANCELED'] as const)(
    'passes through known state %s unchanged',
    async (state) => {
      fetchMock.mockResolvedValueOnce(mockFetchOnce({ deployments: [{ ...baseDeploy, state }] }))
      const result = await getLatestProdDeploy()
      expect(result.status).toBe(state)
    }
  )

  it('normalizes lowercase state via toUpperCase (ready → READY)', async () => {
    fetchMock.mockResolvedValueOnce(
      mockFetchOnce({ deployments: [{ ...baseDeploy, state: 'ready' }] })
    )
    const result = await getLatestProdDeploy()
    expect(result.status).toBe('READY')
  })

  it("returns 'unknown' for state outside the whitelist", async () => {
    fetchMock.mockResolvedValueOnce(
      mockFetchOnce({ deployments: [{ ...baseDeploy, state: 'MYSTERY_STATE' }] })
    )
    const result = await getLatestProdDeploy()
    expect(result.status).toBe('unknown')
  })

  it("returns 'unknown' when state field is absent (optional chaining path)", async () => {
    fetchMock.mockResolvedValueOnce(
      mockFetchOnce({ deployments: [{ uid: 'dpl_y', createdAt: Date.now(), url: 'x.vercel.app' }] })
    )
    const result = await getLatestProdDeploy()
    expect(result.status).toBe('unknown')
  })
})

describe('getLatestProdDeploy — timestamp + URL shaping', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    process.env.VERCEL_API_TOKEN = 'test-token'
    process.env.VERCEL_PROJECT_ID = 'proj_abc'
    delete process.env.VERCEL_TEAM_ID
  })

  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('converts numeric createdAt to ISO 8601 string', async () => {
    const fixedMs = 1_700_000_000_000 // 2023-11-14T22:13:20Z
    fetchMock.mockResolvedValueOnce(
      mockFetchOnce({
        deployments: [{ uid: 'dpl', state: 'READY', createdAt: fixedMs, url: 'a.vercel.app' }],
      })
    )
    const result = await getLatestProdDeploy()
    expect(result.createdAt).toBe(new Date(fixedMs).toISOString())
    expect(result.createdAt).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/)
  })

  it('computes ageSeconds as floor((Date.now() - createdAt) / 1000)', async () => {
    const nowMs = Date.now()
    const thirtyAgo = nowMs - 30_000
    fetchMock.mockResolvedValueOnce(
      mockFetchOnce({
        deployments: [{ uid: 'dpl', state: 'READY', createdAt: thirtyAgo, url: 'a.vercel.app' }],
      })
    )
    const result = await getLatestProdDeploy()
    // Allow 2s slack for test-execution time
    expect(result.ageSeconds).toBeGreaterThanOrEqual(30)
    expect(result.ageSeconds).toBeLessThanOrEqual(32)
  })

  it('prefixes deployment url with https://', async () => {
    fetchMock.mockResolvedValueOnce(
      mockFetchOnce({
        deployments: [
          { uid: 'dpl', state: 'READY', createdAt: Date.now(), url: 'sensed-app.vercel.app' },
        ],
      })
    )
    const result = await getLatestProdDeploy()
    expect(result.url).toBe('https://sensed-app.vercel.app')
  })
})

describe('getLatestProdDeploy — request URL shaping', () => {
  let fetchMock: FetchMock

  beforeEach(() => {
    fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    process.env.VERCEL_API_TOKEN = 'test-token'
    process.env.VERCEL_PROJECT_ID = 'proj_abc'
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    delete process.env.VERCEL_TEAM_ID
  })

  it('omits teamId query param when VERCEL_TEAM_ID is unset', async () => {
    delete process.env.VERCEL_TEAM_ID
    fetchMock.mockResolvedValueOnce(mockFetchOnce({ deployments: [] }))
    await getLatestProdDeploy()
    const [url] = fetchMock.mock.calls[0]
    expect(url).not.toContain('teamId=')
    expect(url).toContain('projectId=proj_abc')
    expect(url).toContain('target=production')
    expect(url).toContain('limit=1')
  })

  it('includes teamId query param when VERCEL_TEAM_ID is set', async () => {
    process.env.VERCEL_TEAM_ID = 'team_xyz'
    fetchMock.mockResolvedValueOnce(mockFetchOnce({ deployments: [] }))
    await getLatestProdDeploy()
    const [url] = fetchMock.mock.calls[0]
    expect(url).toContain('teamId=team_xyz')
  })

  it('URL-encodes projectId with special chars (encodeURIComponent)', async () => {
    process.env.VERCEL_PROJECT_ID = 'proj with spaces&amp'
    fetchMock.mockResolvedValueOnce(mockFetchOnce({ deployments: [] }))
    await getLatestProdDeploy()
    const [url] = fetchMock.mock.calls[0]
    expect(url).toContain('projectId=proj%20with%20spaces%26amp')
  })

  it('URL-encodes teamId with special chars (encodeURIComponent)', async () => {
    process.env.VERCEL_TEAM_ID = 'team/slash'
    fetchMock.mockResolvedValueOnce(mockFetchOnce({ deployments: [] }))
    await getLatestProdDeploy()
    const [url] = fetchMock.mock.calls[0]
    expect(url).toContain('teamId=team%2Fslash')
  })

  it('sends Bearer token in Authorization header', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce({ deployments: [] }))
    await getLatestProdDeploy()
    const [, init] = fetchMock.mock.calls[0]
    expect(init.headers.Authorization).toBe('Bearer test-token')
  })

  it('requests the v6 deployments endpoint', async () => {
    fetchMock.mockResolvedValueOnce(mockFetchOnce({ deployments: [] }))
    await getLatestProdDeploy()
    const [url] = fetchMock.mock.calls[0]
    expect(url).toMatch(/^https:\/\/api\.vercel\.com\/v6\/deployments\?/)
  })
})
