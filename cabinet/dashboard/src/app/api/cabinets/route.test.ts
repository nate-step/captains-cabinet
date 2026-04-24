// Spec 034 — GET /api/cabinets + POST /api/cabinets handler harness
//
// Quirk notes:
//   - Redis lock branch: the handler casts redis to `any` and tests
//     `typeof r.set === 'function'`. Since our mock provides a vi.fn(),
//     it always takes the ioredis 5-arg path: set(key,'1','NX','EX',1800).
//   - Lock fail-open: when redis.set throws, lockAcquired=true (route explicitly
//     comments this as intentional — allow creation but log). Pin this behavior.
//   - Conflict (empty INSERT result): redis.del(lockKey) called before 409 return.
//   - cabinet_id format: `cab_` + 16 hex chars from crypto.randomBytes(8).
//   - startProvisioningJob is fire-and-forget (no await) — just assert it's called.
//   - capacity defaults to preset when body.capacity absent.
//   - name/preset are trim()ed before use; capacity = (body.capacity || preset).trim().

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

const {
  mockGuard,
  mockQuery,
  mockRedisGet,
  mockRedisSet,
  mockRedisDel,
  mockWriteAudit,
  mockStartJob,
} = vi.hoisted(() => ({
  mockGuard: vi.fn(),
  mockQuery: vi.fn(),
  mockRedisGet: vi.fn(),
  mockRedisSet: vi.fn(),
  mockRedisDel: vi.fn(),
  mockWriteAudit: vi.fn(),
  mockStartJob: vi.fn(),
}))

vi.mock('@/lib/provisioning/guard', () => ({
  requireProvisioningAccess: mockGuard,
}))

vi.mock('@/lib/db', () => ({
  query: mockQuery,
}))

vi.mock('@/lib/redis', () => ({
  default: { get: mockRedisGet, set: mockRedisSet, del: mockRedisDel },
}))

vi.mock('@/lib/provisioning/audit', () => ({
  writeAuditEvent: mockWriteAudit,
}))

vi.mock('@/lib/provisioning/worker', () => ({
  startProvisioningJob: mockStartJob,
}))

import { GET, POST } from './route'

function makePostReq(body: unknown): NextRequest {
  return { json: async () => body } as unknown as NextRequest
}

function makeThrowingPostReq(): NextRequest {
  return {
    json: async () => {
      throw new SyntaxError('Unexpected token')
    },
  } as unknown as NextRequest
}

beforeEach(() => {
  mockGuard.mockReset()
  mockQuery.mockReset()
  mockRedisGet.mockReset()
  mockRedisSet.mockReset()
  mockRedisDel.mockReset()
  mockWriteAudit.mockReset()
  mockStartJob.mockReset()

  // Default: guard passes
  mockGuard.mockResolvedValue({ response: null, user: { token: 'captain' } })
  // Default: redis ops succeed
  mockRedisSet.mockResolvedValue('OK')
  mockRedisDel.mockResolvedValue(1)
  // Default: audit + worker succeed
  mockWriteAudit.mockResolvedValue(undefined)
  mockStartJob.mockReturnValue(undefined) // fire-and-forget
})

// =============================================================================
// GET /api/cabinets
// =============================================================================

describe('GET /api/cabinets — guard short-circuit', () => {
  it('returns guard.response directly when guard fires (503 feature-flag)', async () => {
    const flagResp = NextResponse.json(
      { ok: false, disabled: true },
      { status: 503 }
    )
    mockGuard.mockResolvedValueOnce({ response: flagResp, user: null })
    const res = await GET()
    expect(res.status).toBe(503)
    expect(mockQuery).not.toHaveBeenCalled()
  })

  it('returns guard.response directly when auth guard fires (401)', async () => {
    const authResp = NextResponse.json({ ok: false, message: 'Unauthorized' }, { status: 401 })
    mockGuard.mockResolvedValueOnce({ response: authResp, user: null })
    const res = await GET()
    expect(res.status).toBe(401)
    expect(mockQuery).not.toHaveBeenCalled()
  })
})

describe('GET /api/cabinets — happy path (200)', () => {
  it('returns 200 with {ok: true, cabinets}', async () => {
    const rows = [
      {
        cabinet_id: 'cab_abc',
        captain_id: 'captain',
        name: 'my-cabinet',
        preset: 'work',
        capacity: 'work',
        state: 'active',
        state_entered_at: '2024-01-01T00:00:00Z',
        officer_slots: [],
        retry_count: 0,
        created_at: '2024-01-01T00:00:00Z',
      },
    ]
    mockQuery.mockResolvedValueOnce(rows)
    const res = await GET()
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ ok: true, cabinets: rows })
  })

  it('returns empty array when no cabinets exist', async () => {
    mockQuery.mockResolvedValueOnce([])
    const res = await GET()
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.cabinets).toEqual([])
  })

  it('SQL query uses ORDER BY created_at DESC (pin ordering)', async () => {
    mockQuery.mockResolvedValueOnce([])
    await GET()
    const [sql] = mockQuery.mock.calls[0]
    expect(sql).toMatch(/ORDER BY created_at DESC/)
  })

  it('SQL query selects from cabinets table (pin table name)', async () => {
    mockQuery.mockResolvedValueOnce([])
    await GET()
    const [sql] = mockQuery.mock.calls[0]
    expect(sql).toMatch(/FROM cabinets/)
  })
})

describe('GET /api/cabinets — error path (500)', () => {
  it('returns 500 with {ok: false, message} when query throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockQuery.mockRejectedValueOnce(new Error('pg down'))
    const res = await GET()
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Failed to list cabinets' })
    spy.mockRestore()
  })

  it('500 does not leak internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockQuery.mockRejectedValueOnce(new Error('secret: PGPASSWORD=hunter2'))
    const res = await GET()
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('hunter2')
    expect(JSON.stringify(body)).not.toContain('PGPASSWORD')
    spy.mockRestore()
  })
})

// =============================================================================
// POST /api/cabinets
// =============================================================================

describe('POST /api/cabinets — guard short-circuit', () => {
  it('returns guard.response directly when guard fires (503)', async () => {
    const flagResp = NextResponse.json({ ok: false, disabled: true }, { status: 503 })
    mockGuard.mockResolvedValueOnce({ response: flagResp, user: null })
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(res.status).toBe(503)
    expect(mockQuery).not.toHaveBeenCalled()
    expect(mockRedisSet).not.toHaveBeenCalled()
  })

  it('returns guard.response directly when auth guard fires (401)', async () => {
    const authResp = NextResponse.json({ ok: false, message: 'Unauthorized' }, { status: 401 })
    mockGuard.mockResolvedValueOnce({ response: authResp, user: null })
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(res.status).toBe(401)
    expect(mockQuery).not.toHaveBeenCalled()
  })
})

describe('POST /api/cabinets — body validation (400)', () => {
  it('400 when req.json() throws (Invalid JSON body)', async () => {
    const res = await POST(makeThrowingPostReq())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Invalid JSON body' })
    expect(mockRedisSet).not.toHaveBeenCalled()
  })

  it('400 when name is missing', async () => {
    const res = await POST(makePostReq({ preset: 'work' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('name is required')
  })

  it('400 when name is empty string', async () => {
    const res = await POST(makePostReq({ name: '', preset: 'work' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('name is required')
  })

  it('400 when name is whitespace-only', async () => {
    const res = await POST(makePostReq({ name: '   ', preset: 'work' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('name is required')
    expect(mockRedisSet).not.toHaveBeenCalled()
  })

  it('400 when name fails SLUG_RE: "Bad Name" (uppercase + spaces)', async () => {
    const res = await POST(makePostReq({ name: 'Bad Name', preset: 'work' }))
    expect(res.status).toBe(400)
    expect(mockRedisSet).not.toHaveBeenCalled()
  })

  it('400 when name fails SLUG_RE: "UPPERCASE"', async () => {
    const res = await POST(makePostReq({ name: 'UPPERCASE', preset: 'work' }))
    expect(res.status).toBe(400)
  })

  it('400 when name fails SLUG_RE: "-starts-with-dash"', async () => {
    const res = await POST(makePostReq({ name: '-starts-with-dash', preset: 'work' }))
    expect(res.status).toBe(400)
  })

  it('400 when name fails SLUG_RE: single char (too short)', async () => {
    const res = await POST(makePostReq({ name: 'a', preset: 'work' }))
    expect(res.status).toBe(400)
  })

  it('400 when name fails SLUG_RE: 49 chars (too long)', async () => {
    // SLUG_RE allows [a-z0-9][a-z0-9-]{1,47} → max 48 chars total
    const res = await POST(makePostReq({ name: 'a'.repeat(49), preset: 'work' }))
    expect(res.status).toBe(400)
  })

  it('valid name at exactly 48 chars passes slug validation', async () => {
    // Should proceed past validation (lock attempt happens)
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockResolvedValueOnce([{ cabinet_id: 'cab_abc' }])
    const res = await POST(makePostReq({ name: 'a'.repeat(48), preset: 'work' }))
    // Not 400 (passes slug check — only OK or 409/202 depending on DB)
    expect(res.status).not.toBe(400)
  })

  it('400 when preset is missing', async () => {
    const res = await POST(makePostReq({ name: 'my-cabinet' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('preset is required')
    expect(mockRedisSet).not.toHaveBeenCalled()
  })

  it('400 when preset is empty string', async () => {
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: '' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('preset is required')
  })

  it('400 when preset is whitespace-only', async () => {
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: '   ' }))
    expect(res.status).toBe(400)
  })
})

describe('POST /api/cabinets — Redis lock (NX)', () => {
  it('calls redis.set with (lockKey, "1", "NX", "EX", 1800) — ioredis 5-arg signature', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockResolvedValueOnce([{ cabinet_id: 'cab_abc' }])
    await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(mockRedisSet).toHaveBeenCalledWith(
      expect.stringContaining('cabinet:provisioning-lock:'),
      '1',
      'NX',
      'EX',
      1800
    )
  })

  it('lock key is cabinet:provisioning-lock:<captain_id>', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockResolvedValueOnce([{ cabinet_id: 'cab_abc' }])
    await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    const [lockKey] = mockRedisSet.mock.calls[0]
    expect(lockKey).toBe('cabinet:provisioning-lock:captain')
  })

  it('lock TTL is exactly 1800 seconds (30 minutes)', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockResolvedValueOnce([{ cabinet_id: 'cab_abc' }])
    await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    const args = mockRedisSet.mock.calls[0]
    expect(args[4]).toBe(1800)
  })

  it('409 when lock returns non-OK (another creation in flight)', async () => {
    mockRedisSet.mockResolvedValueOnce(null) // lock taken
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(res.status).toBe(409)
    const body = await res.json()
    expect(body.message).toContain('Another cabinet creation is already in flight')
    expect(mockQuery).not.toHaveBeenCalled()
  })

  it('fail-open: when redis.set throws, lockAcquired=true (creation proceeds)', async () => {
    // Route explicitly fails open on Redis errors — pin this behavior
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisSet.mockRejectedValueOnce(new Error('ECONNREFUSED'))
    mockQuery.mockResolvedValueOnce([{ cabinet_id: 'cab_abc' }])
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    // Should NOT be 409 — fails open allows creation to proceed
    expect(res.status).not.toBe(409)
    spy.mockRestore()
  })
})

describe('POST /api/cabinets — slug conflict (409)', () => {
  it('409 when INSERT returns empty array (ON CONFLICT DO NOTHING)', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockResolvedValueOnce([]) // conflict: no rows returned
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(res.status).toBe(409)
    const body = await res.json()
    expect(body.message).toBe("Cabinet 'my-cabinet' already exists")
  })

  it('redis.del(lockKey) called on slug conflict to release lock', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockResolvedValueOnce([]) // conflict
    await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(mockRedisDel).toHaveBeenCalledWith('cabinet:provisioning-lock:captain')
  })

  it('conflict 409 message contains the cabinet name', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockResolvedValueOnce([])
    const res = await POST(makePostReq({ name: 'specific-name', preset: 'work' }))
    const body = await res.json()
    expect(body.message).toContain('specific-name')
  })
})

describe('POST /api/cabinets — happy path (202)', () => {
  it('returns 202 with {ok: true, cabinet_id}', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockResolvedValueOnce([{ cabinet_id: 'cab_abcdef0123456789' }])
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(res.status).toBe(202)
    const body = await res.json()
    expect(body.ok).toBe(true)
    expect(typeof body.cabinet_id).toBe('string')
  })

  it('cabinet_id matches /^cab_[0-9a-f]{16}$/ (16 hex chars)', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    // The handler generates its own cabinet_id — we return a matching one from the DB
    mockQuery.mockImplementationOnce(async (_sql: string, params: string[]) => {
      return [{ cabinet_id: params[0] }] // echo back the generated id
    })
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    const body = await res.json()
    expect(body.cabinet_id).toMatch(/^cab_[0-9a-f]{16}$/)
  })

  it('writeAuditEvent called with correct shape', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockImplementationOnce(async (_sql: string, params: string[]) => [{ cabinet_id: params[0] }])
    await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(mockWriteAudit).toHaveBeenCalledTimes(1)
    const [auditArg] = mockWriteAudit.mock.calls[0]
    expect(auditArg.actor).toBe('captain')
    expect(auditArg.entry_point).toBe('dashboard')
    expect(auditArg.event_type).toBe('state_transition')
    expect(auditArg.state_before).toBeNull()
    expect(auditArg.state_after).toBe('creating')
    expect(auditArg.payload).toEqual({ name: 'my-cabinet', preset: 'work', capacity: 'work' })
    expect(auditArg.cabinet_id).toMatch(/^cab_[0-9a-f]{16}$/)
  })

  it('startProvisioningJob called with correct shape', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockImplementationOnce(async (_sql: string, params: string[]) => [{ cabinet_id: params[0] }])
    await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(mockStartJob).toHaveBeenCalledTimes(1)
    const [jobArg] = mockStartJob.mock.calls[0]
    expect(jobArg.actor).toBe('captain')
    expect(jobArg.name).toBe('my-cabinet')
    expect(jobArg.preset).toBe('work')
    expect(jobArg.capacity).toBe('work')
    expect(jobArg.captain_id).toBe('captain')
    expect(jobArg.cabinet_id).toMatch(/^cab_[0-9a-f]{16}$/)
  })

  it('capacity defaults to preset when body.capacity absent', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockImplementationOnce(async (_sql: string, params: string[]) => [{ cabinet_id: params[0] }])
    await POST(makePostReq({ name: 'my-cabinet', preset: 'startup' }))
    const [jobArg] = mockStartJob.mock.calls[0]
    expect(jobArg.capacity).toBe('startup')
  })

  it('capacity uses body.capacity when provided', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockImplementationOnce(async (_sql: string, params: string[]) => [{ cabinet_id: params[0] }])
    await POST(makePostReq({ name: 'my-cabinet', preset: 'work', capacity: 'enterprise' }))
    const [jobArg] = mockStartJob.mock.calls[0]
    expect(jobArg.capacity).toBe('enterprise')
  })

  it('name and preset are trim()ed before use', async () => {
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockImplementationOnce(async (_sql: string, params: string[]) => [{ cabinet_id: params[0] }])
    await POST(makePostReq({ name: '  my-cabinet  ', preset: '  work  ' }))
    const [auditArg] = mockWriteAudit.mock.calls[0]
    expect(auditArg.payload.name).toBe('my-cabinet')
    expect(auditArg.payload.preset).toBe('work')
  })

  it('two consecutive calls produce different cabinet_ids', async () => {
    mockRedisSet.mockResolvedValue('OK')
    mockQuery.mockImplementation(async (_sql: string, params: string[]) => [{ cabinet_id: params[0] }])
    const r1 = await POST(makePostReq({ name: 'cabinet-a', preset: 'work' }))
    const r2 = await POST(makePostReq({ name: 'cabinet-b', preset: 'work' }))
    const b1 = await r1.json()
    const b2 = await r2.json()
    expect(b1.cabinet_id).not.toBe(b2.cabinet_id)
  })
})

describe('POST /api/cabinets — unexpected error path (500)', () => {
  it('500 with {ok: false, message} when query throws unexpectedly', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockRejectedValueOnce(new Error('pg connection lost'))
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Failed to create cabinet' })
    spy.mockRestore()
  })

  it('redis.del(lockKey) called on unexpected error (lock cleanup)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockRejectedValueOnce(new Error('pg down'))
    await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(mockRedisDel).toHaveBeenCalledWith('cabinet:provisioning-lock:captain')
    spy.mockRestore()
  })

  it('500 returned even when redis.del itself throws during cleanup', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockRejectedValueOnce(new Error('pg down'))
    mockRedisDel.mockRejectedValueOnce(new Error('redis also down'))
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    expect(res.status).toBe(500)
    spy.mockRestore()
  })

  it('500 body does not leak internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisSet.mockResolvedValueOnce('OK')
    mockQuery.mockRejectedValueOnce(new Error('secret: PGPASSWORD=hunter2'))
    const res = await POST(makePostReq({ name: 'my-cabinet', preset: 'work' }))
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('hunter2')
    expect(JSON.stringify(body)).not.toContain('PGPASSWORD')
    spy.mockRestore()
  })
})
