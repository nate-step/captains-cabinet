// POST /api/auth/reauth-verify — Spec 034 PR 5 step-2-of-2 password check → OTU token.
//
// Behavioral invariants pinned here (128-LOC handler, highest security-value in the flow):
//   - Guard FIRST, body parse AFTER
//   - req.json() throws → 400 'Invalid JSON body' (NOT 500)
//   - Missing/empty challenge_token | password → 400 with explicit field name
//   - Redis GET for challenge state runs BEFORE checkPassword (fast-fail on invalid tokens)
//   - Any challengeState !== 'pending' → 401 'invalid, expired, or already used'
//     (covers null, 'consumed', 'used', anything else)
//   - checkPassword called ONLY when challenge is 'pending' (protects timing channel +
//     prevents password-oracle via missing/expired tokens)
//   - Wrong password → 401 'Incorrect password' + no OTU issued
//   - Right password path:
//       1. Mark challenge 'consumed' with EX=60 — NON-FATAL on failure (console.warn only)
//       2. Generate OTU token: crypto.randomBytes(32).toString('hex') → 64 hex
//       3. Store OTU: key=`cabinet:reauth:otu:<token>`, value='valid', EX=300
//       4. Return 200 {ok, otu_token, expires_in_seconds:300}
//   - OTU storage failure → 500 'Could not issue OTU token' (DIFFERENT message from challenge-get 500)
//   - Exported helper otuKey(token) → `cabinet:reauth:otu:${token}` for archive-route import

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

const { mockGuard, mockRedisGet, mockRedisSet, mockCheckPassword } = vi.hoisted(() => ({
  mockGuard: vi.fn(),
  mockRedisGet: vi.fn(),
  mockRedisSet: vi.fn(),
  mockCheckPassword: vi.fn(),
}))

vi.mock('@/lib/provisioning/guard', () => ({
  requireProvisioningAccess: mockGuard,
}))

vi.mock('@/lib/redis', () => ({
  default: {
    get: mockRedisGet,
    set: mockRedisSet,
  },
}))

vi.mock('@/lib/auth', () => ({
  checkPassword: mockCheckPassword,
}))

import { POST, otuKey } from './route'

function makeReq(body: unknown, throwOnJson = false): NextRequest {
  return {
    json: throwOnJson
      ? async () => {
          throw new SyntaxError('Unexpected token')
        }
      : async () => body,
  } as unknown as NextRequest
}

beforeEach(() => {
  mockGuard.mockReset()
  mockRedisGet.mockReset()
  mockRedisSet.mockReset()
  mockCheckPassword.mockReset()
  // Default: guard passes, redis ops succeed, challenge is 'pending', password correct
  mockGuard.mockResolvedValue({ response: null, user: { token: 'captain' } })
  mockRedisGet.mockResolvedValue('pending')
  mockRedisSet.mockResolvedValue('OK')
  mockCheckPassword.mockReturnValue(true)
})

describe('POST reauth-verify — guard short-circuit', () => {
  it('returns guard.response directly when guard fires (503)', async () => {
    const flagResp = NextResponse.json({ ok: false, disabled: true }, { status: 503 })
    mockGuard.mockResolvedValueOnce({ response: flagResp, user: null })
    const res = await POST(makeReq({ challenge_token: 'x', password: 'y' }))
    expect(res.status).toBe(503)
    expect(mockRedisGet).not.toHaveBeenCalled()
    expect(mockCheckPassword).not.toHaveBeenCalled()
  })

  it('returns guard.response directly when auth guard fires (401)', async () => {
    const authResp = NextResponse.json({ ok: false, message: 'Unauthorized' }, { status: 401 })
    mockGuard.mockResolvedValueOnce({ response: authResp, user: null })
    const res = await POST(makeReq({ challenge_token: 'x', password: 'y' }))
    expect(res.status).toBe(401)
    expect(mockRedisGet).not.toHaveBeenCalled()
  })
})

describe('POST reauth-verify — body validation (400)', () => {
  it('400 when req.json() throws (malformed JSON)', async () => {
    const res = await POST(makeReq(null, true))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Invalid JSON body' })
    expect(mockRedisGet).not.toHaveBeenCalled()
    expect(mockCheckPassword).not.toHaveBeenCalled()
  })

  it('400 when challenge_token is missing', async () => {
    const res = await POST(makeReq({ password: 'pw' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('challenge_token is required')
    expect(mockRedisGet).not.toHaveBeenCalled()
  })

  it('400 when challenge_token is empty string (falsy check)', async () => {
    const res = await POST(makeReq({ challenge_token: '', password: 'pw' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('challenge_token is required')
  })

  it('400 when password is missing', async () => {
    const res = await POST(makeReq({ challenge_token: 'abc' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('password is required')
    expect(mockRedisGet).not.toHaveBeenCalled()
  })

  it('400 when password is empty string (falsy check)', async () => {
    const res = await POST(makeReq({ challenge_token: 'abc', password: '' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('password is required')
  })

  it('challenge_token validated BEFORE password (explicit field order)', async () => {
    const res = await POST(makeReq({}))
    const body = await res.json()
    // Both missing — the error should be about challenge_token first
    expect(body.message).toBe('challenge_token is required')
  })
})

describe('POST reauth-verify — challenge-state validation (401)', () => {
  it('500 when redis.get throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisGet.mockRejectedValueOnce(new Error('ECONNREFUSED'))
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Could not verify challenge token' })
    spy.mockRestore()
  })

  it('401 when challengeState is null (token expired or never existed)', async () => {
    mockRedisGet.mockResolvedValueOnce(null)
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    expect(res.status).toBe(401)
    const body = await res.json()
    expect(body.message).toBe('Challenge token is invalid, expired, or already used')
    expect(mockCheckPassword).not.toHaveBeenCalled()
  })

  it('401 when challengeState is "consumed" (already used)', async () => {
    mockRedisGet.mockResolvedValueOnce('consumed')
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    expect(res.status).toBe(401)
    expect(mockCheckPassword).not.toHaveBeenCalled()
  })

  it('401 when challengeState is any unexpected value (strict !== "pending")', async () => {
    for (const bogus of ['used', 'valid', 'OK', 'PENDING', '1']) {
      mockRedisGet.mockResolvedValueOnce(bogus)
      const res = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
      expect(res.status, `bogus state "${bogus}" should be rejected`).toBe(401)
    }
    expect(mockCheckPassword).not.toHaveBeenCalled()
  })

  it('looks up challenge under exact key `cabinet:reauth:challenge:<token>`', async () => {
    await POST(makeReq({ challenge_token: 'deadbeef', password: 'pw' }))
    expect(mockRedisGet).toHaveBeenCalledWith('cabinet:reauth:challenge:deadbeef')
  })
})

describe('POST reauth-verify — password check (401)', () => {
  it('401 when checkPassword returns false (wrong password)', async () => {
    mockCheckPassword.mockReturnValueOnce(false)
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'wrong' }))
    expect(res.status).toBe(401)
    const body = await res.json()
    expect(body.message).toBe('Incorrect password')
  })

  it('wrong password → NO OTU token issued (no redis.set for otu key)', async () => {
    mockCheckPassword.mockReturnValueOnce(false)
    await POST(makeReq({ challenge_token: 'abc', password: 'wrong' }))
    const otuCalls = mockRedisSet.mock.calls.filter(([key]) =>
      String(key).startsWith('cabinet:reauth:otu:')
    )
    expect(otuCalls).toHaveLength(0)
  })

  it('checkPassword called with exact password from body (no mutation)', async () => {
    await POST(makeReq({ challenge_token: 'abc', password: 'hunter2' }))
    expect(mockCheckPassword).toHaveBeenCalledWith('hunter2')
  })
})

describe('POST reauth-verify — happy path (200)', () => {
  it('returns 200 with {ok, otu_token, expires_in_seconds:300}', async () => {
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.ok).toBe(true)
    expect(body.expires_in_seconds).toBe(300)
    expect(typeof body.otu_token).toBe('string')
  })

  it('otu_token is 64 hex chars (crypto.randomBytes(32).toString("hex"))', async () => {
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    const body = await res.json()
    expect(body.otu_token).toMatch(/^[0-9a-f]{64}$/)
  })

  it('two successful verifies produce different OTU tokens', async () => {
    const r1 = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    const r2 = await POST(makeReq({ challenge_token: 'def', password: 'pw' }))
    const b1 = await r1.json()
    const b2 = await r2.json()
    expect(b1.otu_token).not.toBe(b2.otu_token)
  })

  it('marks challenge as "consumed" with EX=60s (short re-grace window)', async () => {
    await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    expect(mockRedisSet).toHaveBeenCalledWith(
      'cabinet:reauth:challenge:abc',
      'consumed',
      'EX',
      60
    )
  })

  it('stores OTU token with value="valid" + EX=300s', async () => {
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    const body = await res.json()
    expect(mockRedisSet).toHaveBeenCalledWith(
      `cabinet:reauth:otu:${body.otu_token}`,
      'valid',
      'EX',
      300
    )
  })

  it('exactly 2 redis.set calls on happy path (consume challenge + issue OTU)', async () => {
    await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    expect(mockRedisSet).toHaveBeenCalledTimes(2)
  })

  it('challenge consumed BEFORE OTU issued (ordering — prevents TOCTOU on replay)', async () => {
    await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    const callKeys = mockRedisSet.mock.calls.map(([k]) => String(k))
    expect(callKeys[0]).toBe('cabinet:reauth:challenge:abc')
    expect(callKeys[1]).toMatch(/^cabinet:reauth:otu:/)
  })
})

describe('POST reauth-verify — mark-consumed non-fatal branch', () => {
  it('200 even if marking challenge consumed throws (console.warn, not console.error)', async () => {
    // First call (mark consumed) throws, second call (store OTU) succeeds
    mockRedisSet
      .mockRejectedValueOnce(new Error('transient'))
      .mockResolvedValueOnce('OK')
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.ok).toBe(true)
    expect(warnSpy).toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('consume-challenge failure still produces valid OTU token', async () => {
    mockRedisSet.mockRejectedValueOnce(new Error('transient')).mockResolvedValueOnce('OK')
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    const body = await res.json()
    expect(body.otu_token).toMatch(/^[0-9a-f]{64}$/)
    warnSpy.mockRestore()
  })
})

describe('POST reauth-verify — OTU-storage error (500)', () => {
  it('500 when OTU storage throws (after consume succeeds)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisSet
      .mockResolvedValueOnce('OK') // consume challenge succeeds
      .mockRejectedValueOnce(new Error('redis OOM')) // OTU storage fails
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Could not issue OTU token' })
    spy.mockRestore()
  })

  it('500 uses DIFFERENT message than challenge-GET 500 (disambiguable failure sites)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisSet
      .mockResolvedValueOnce('OK')
      .mockRejectedValueOnce(new Error('down'))
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'pw' }))
    const body = await res.json()
    expect(body.message).not.toBe('Could not verify challenge token')
    expect(body.message).toBe('Could not issue OTU token')
    spy.mockRestore()
  })

  it('500 body does not leak password or internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisSet
      .mockResolvedValueOnce('OK')
      .mockRejectedValueOnce(new Error('REDIS_URL=redis://u:hunter2@h'))
    const res = await POST(makeReq({ challenge_token: 'abc', password: 'hunter2' }))
    const body = await res.json()
    const serialized = JSON.stringify(body)
    expect(serialized).not.toContain('hunter2')
    expect(serialized).not.toContain('REDIS_URL')
    spy.mockRestore()
  })
})

describe('otuKey() exported helper (imported by archive route)', () => {
  it('prefixes token with `cabinet:reauth:otu:`', () => {
    expect(otuKey('abc123')).toBe('cabinet:reauth:otu:abc123')
  })

  it('does NOT prefix with challenge namespace (archive must not consume challenges)', () => {
    expect(otuKey('xyz')).not.toContain('challenge')
  })

  it('pass-through: no validation/trim on input (contract is raw string → raw key)', () => {
    expect(otuKey('')).toBe('cabinet:reauth:otu:')
    expect(otuKey('  spaces  ')).toBe('cabinet:reauth:otu:  spaces  ')
  })
})
