// POST /api/auth/reauth-challenge — Spec 034 PR 5 step-1-of-2 challenge issuer.
//
// Behavioral invariants pinned here (70-LOC handler but security-sensitive):
//   - Guard runs FIRST — no crypto.randomBytes, no Redis writes when guard fires
//   - Token: crypto.randomBytes(32).toString('hex') → 64-char hex, unique per call
//   - Redis key prefix: `cabinet:reauth:challenge:<token>`
//   - Redis value: literal 'pending' (verify step mutates to 'consumed')
//   - TTL: 300s exactly (5 min; constant CHALLENGE_TTL_SECONDS)
//   - ioredis branch: `typeof r.set === 'function'` → 4-arg .set(key, val, 'EX', ttl)
//   - Redis throws → 500 with generic message (no internal leakage)
//
// Mock strategy:
//   - `@/lib/provisioning/guard`: requireProvisioningAccess returns either
//     {response: NextResponse, user: null} (fail) or {response: null, user: {token}} (ok).
//     Route short-circuits on `if (guard.response)` — so a truthy response means
//     return early, falsy (null) means proceed.
//   - `@/lib/redis`: default export with .set vi.fn. Route casts to any then
//     checks typeof r.set === 'function', so vi.fn always takes the ioredis branch.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { NextResponse } from 'next/server'

const { mockGuard, mockRedisSet } = vi.hoisted(() => ({
  mockGuard: vi.fn(),
  mockRedisSet: vi.fn(),
}))

vi.mock('@/lib/provisioning/guard', () => ({
  requireProvisioningAccess: mockGuard,
}))

vi.mock('@/lib/redis', () => ({
  default: {
    set: mockRedisSet,
  },
}))

import { POST } from './route'

function makeReq() {
  // POST /reauth-challenge handler does not read body — just an empty object satisfies NextRequest shape
  return {} as unknown as import('next/server').NextRequest
}

beforeEach(() => {
  mockGuard.mockReset()
  mockRedisSet.mockReset()
  // Default: guard passes
  mockGuard.mockResolvedValue({ response: null, user: { token: 'captain' } })
  // Default: redis set succeeds
  mockRedisSet.mockResolvedValue('OK')
})

describe('POST reauth-challenge — guard short-circuit', () => {
  it('returns guard.response directly when guard fires (feature-flag 503)', async () => {
    const flagResp = NextResponse.json(
      { ok: false, disabled: true, message: 'Cabinet provisioning not configured' },
      { status: 503 }
    )
    mockGuard.mockResolvedValueOnce({ response: flagResp, user: null })
    const res = await POST(makeReq())
    expect(res.status).toBe(503)
    expect(mockRedisSet).not.toHaveBeenCalled()
  })

  it('returns guard.response directly when auth guard fires (401)', async () => {
    const authResp = NextResponse.json({ ok: false, message: 'Unauthorized' }, { status: 401 })
    mockGuard.mockResolvedValueOnce({ response: authResp, user: null })
    const res = await POST(makeReq())
    expect(res.status).toBe(401)
    expect(mockRedisSet).not.toHaveBeenCalled()
  })

  it('does NOT generate a challenge token when guard fires', async () => {
    mockGuard.mockResolvedValueOnce({
      response: NextResponse.json({ ok: false }, { status: 401 }),
      user: null,
    })
    const res = await POST(makeReq())
    const body = await res.json().catch(() => ({}))
    expect(body).not.toHaveProperty('challenge_token')
  })
})

describe('POST reauth-challenge — happy path (200)', () => {
  it('returns 200 with {ok, challenge_token, expires_in_seconds}', async () => {
    const res = await POST(makeReq())
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.ok).toBe(true)
    expect(body.expires_in_seconds).toBe(300)
    expect(typeof body.challenge_token).toBe('string')
  })

  it('challenge_token is 64 hex chars (crypto.randomBytes(32).toString("hex"))', async () => {
    const res = await POST(makeReq())
    const body = await res.json()
    expect(body.challenge_token).toMatch(/^[0-9a-f]{64}$/)
  })

  it('two consecutive calls produce different tokens (no determinism / caching)', async () => {
    const res1 = await POST(makeReq())
    const res2 = await POST(makeReq())
    const body1 = await res1.json()
    const body2 = await res2.json()
    expect(body1.challenge_token).not.toBe(body2.challenge_token)
  })
})

describe('POST reauth-challenge — Redis write contract', () => {
  it('redis.set called with (key, "pending", "EX", 300) — ioredis 4-arg signature', async () => {
    const res = await POST(makeReq())
    const body = await res.json()
    expect(mockRedisSet).toHaveBeenCalledTimes(1)
    expect(mockRedisSet).toHaveBeenCalledWith(
      `cabinet:reauth:challenge:${body.challenge_token}`,
      'pending',
      'EX',
      300
    )
  })

  it('key prefix is exactly "cabinet:reauth:challenge:" (namespace pin)', async () => {
    await POST(makeReq())
    const [keyArg] = mockRedisSet.mock.calls[0]
    expect(keyArg).toMatch(/^cabinet:reauth:challenge:[0-9a-f]{64}$/)
  })

  it('stored value is literal string "pending" — verify step mutates to "consumed"', async () => {
    await POST(makeReq())
    const [, valueArg] = mockRedisSet.mock.calls[0]
    expect(valueArg).toBe('pending')
  })

  it('TTL argument is "EX" + 300 (5 minutes), not PX or EXAT', async () => {
    await POST(makeReq())
    const [, , ttlFlag, ttlValue] = mockRedisSet.mock.calls[0]
    expect(ttlFlag).toBe('EX')
    expect(ttlValue).toBe(300)
  })
})

describe('POST reauth-challenge — redis error path (500)', () => {
  it('returns 500 when redis.set throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisSet.mockRejectedValueOnce(new Error('ECONNREFUSED'))
    const res = await POST(makeReq())
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Failed to issue challenge token' })
    spy.mockRestore()
  })

  it('500 body never leaks internal redis error detail to client', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisSet.mockRejectedValueOnce(new Error('secret: REDIS_URL=redis://u:p@h:6379'))
    const res = await POST(makeReq())
    const body = await res.json()
    const serialized = JSON.stringify(body)
    expect(serialized).not.toContain('p@h')
    expect(serialized).not.toContain('REDIS_URL')
    expect(serialized).not.toContain('secret')
    spy.mockRestore()
  })

  it('500 response does NOT include challenge_token (don\'t leak a token that wasn\'t persisted)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisSet.mockRejectedValueOnce(new Error('pg down'))
    const res = await POST(makeReq())
    const body = await res.json()
    expect(body).not.toHaveProperty('challenge_token')
    spy.mockRestore()
  })
})
