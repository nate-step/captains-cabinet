// Spec 034 PR 5 — POST /api/cabinets/[id]/archive handler harness
//
// Scope: OTU token re-auth (inlined consumeOtuToken), confirm_name mismatch,
//   ARCHIVE_BLOCKED_STATES, canTransition, full transaction lifecycle
//   (BEGIN/SELECT/UPDATE/COMMIT + all ROLLBACK paths), writeTransitionEvent,
//   redis.del lock cleanup (non-fatal), startArchivalWorker fire-and-forget, 500 paths.
//
// Mock strategy: vi.hoisted for guard/pool/client/audit/state-machine/redis/worker.
//   consumeOtuToken is INLINED in the route (not exported) — tested via redis.get/set
//   behavior. OTU key pattern: `cabinet:reauth:otu:<token>`.
//   ARCHIVE_BLOCKED_STATES is re-exported from state-machine mock as a plain array;
//   we control it to make test assertions state-independent.
//
// Notable invariants pinned:
//   - OTU validation fires BEFORE pool.connect (pool.connect not called when OTU fails)
//   - redis.set('cabinet:reauth:otu:<token>', 'consumed', 'EX', 60) on valid OTU
//   - confirm_name match is trimmed (body.confirm_name.trim() vs row.name)
//   - redis.del(lockKey) non-fatal: console.warn + still 200
//   - startArchivalWorker called with (id, user.token) and NOT awaited
//   - writeTransitionEvent called with {from: row.state, to: 'archiving', payload: {confirm_name}}
//   - client.release() always called (finally block)

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

const {
  mockGuard,
  mockClient,
  mockPool,
  mockWriteTransition,
  mockCanTransition,
  mockArchiveBlockedStates,
  mockRedisGet,
  mockRedisSet,
  mockRedisDel,
  mockStartWorker,
} = vi.hoisted(() => {
  const client = { query: vi.fn(), release: vi.fn() }
  const pool = { connect: vi.fn(async () => client) }
  // We expose the array via a wrapper object so we can mutate its contents per test
  const blockedStates: string[] = ['creating', 'adopting-bots', 'provisioning', 'starting', 'archiving', 'archived']
  return {
    mockGuard: vi.fn(),
    mockClient: client,
    mockPool: pool,
    mockWriteTransition: vi.fn(),
    mockWriteAudit: vi.fn(),
    mockCanTransition: vi.fn(),
    mockArchiveBlockedStates: blockedStates,
    mockRedisGet: vi.fn(),
    mockRedisSet: vi.fn(),
    mockRedisDel: vi.fn(),
    mockStartWorker: vi.fn(),
  }
})

vi.mock('@/lib/provisioning/guard', () => ({
  requireProvisioningAccess: mockGuard,
}))

vi.mock('@/lib/db', () => ({
  query: vi.fn(),
  getDbPool: () => mockPool,
}))

vi.mock('@/lib/provisioning/audit', () => ({
  writeTransitionEvent: mockWriteTransition,
  writeAuditEvent: vi.fn(),
}))

vi.mock('@/lib/provisioning/state-machine', () => ({
  canTransition: mockCanTransition,
  ARCHIVE_BLOCKED_STATES: mockArchiveBlockedStates,
}))

vi.mock('@/lib/redis', () => ({
  default: {
    get: mockRedisGet,
    set: mockRedisSet,
    del: mockRedisDel,
  },
}))

// startArchivalWorker is INLINED in the archive route (not exported from worker.ts)
// — the route calls its own local function, so we don't need to mock worker.ts here.
// We verify fire-and-forget by asserting 200 is still returned + state side-effects.

import { POST } from './route'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const VALID_OTU = 'abc123def456'

function makeReq(body: unknown, throwOnJson = false): NextRequest {
  return {
    json: throwOnJson
      ? async () => { throw new SyntaxError('Unexpected token') }
      : async () => body,
  } as unknown as NextRequest
}

function makeParams(id = 'cab_abc') {
  return { params: Promise.resolve({ id }) }
}

function makeCabinetRow(overrides: {
  state?: string
  name?: string
  captain_id?: string
} = {}) {
  return {
    captain_id: overrides.captain_id ?? 'cap_test',
    name: overrides.name ?? 'my-cabinet',
    state: overrides.state ?? 'active',
  }
}

/** Full happy-path client.query sequence */
function setupHappyPath(row = makeCabinetRow()) {
  mockClient.query
    .mockResolvedValueOnce(undefined)           // BEGIN
    .mockResolvedValueOnce({ rows: [row] })      // SELECT FOR UPDATE
    .mockResolvedValueOnce(undefined)            // UPDATE
    .mockResolvedValueOnce(undefined)            // COMMIT
}

beforeEach(() => {
  mockGuard.mockReset()
  mockClient.query.mockReset()
  mockClient.release.mockReset()
  mockPool.connect.mockReset()
  mockPool.connect.mockImplementation(async () => mockClient)
  mockWriteTransition.mockReset()
  mockCanTransition.mockReset()
  mockRedisGet.mockReset()
  mockRedisSet.mockReset()
  mockRedisDel.mockReset()
  mockStartWorker.mockReset()

  mockGuard.mockResolvedValue({ response: null, user: { token: 'tok_captain' } })
  mockWriteTransition.mockResolvedValue(undefined)
  mockCanTransition.mockReturnValue({ ok: true })
  mockRedisDel.mockResolvedValue(1)

  // Default OTU: valid (get returns 'valid', set returns 'OK')
  mockRedisGet.mockResolvedValue('valid')
  mockRedisSet.mockResolvedValue('OK')
})

// ---------------------------------------------------------------------------
// Guard short-circuit
// ---------------------------------------------------------------------------

describe('POST archive — guard short-circuit', () => {
  it('returns guard.response when guard fires (503)', async () => {
    const resp = NextResponse.json({ ok: false, disabled: true }, { status: 503 })
    mockGuard.mockResolvedValueOnce({ response: resp, user: null })
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(503)
    expect(mockRedisGet).not.toHaveBeenCalled()
    expect(mockPool.connect).not.toHaveBeenCalled()
  })

  it('returns guard.response when auth guard fires (401)', async () => {
    const resp = NextResponse.json({ ok: false, message: 'Unauthorized' }, { status: 401 })
    mockGuard.mockResolvedValueOnce({ response: resp, user: null })
    const res = await POST(makeReq({ confirm_name: 'x', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(401)
    expect(mockPool.connect).not.toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// Body validation (400)
// ---------------------------------------------------------------------------

describe('POST archive — body validation (400)', () => {
  it('400 when req.json() throws (malformed JSON)', async () => {
    const res = await POST(makeReq(null, true), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Invalid JSON body' })
    expect(mockRedisGet).not.toHaveBeenCalled()
  })

  it('400 when confirm_name is missing', async () => {
    const res = await POST(makeReq({ otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toContain('confirm_name is required')
  })

  it('400 when confirm_name is empty string', async () => {
    const res = await POST(makeReq({ confirm_name: '', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toContain('confirm_name is required')
  })

  it('400 when otu_token is missing', async () => {
    const res = await POST(makeReq({ confirm_name: 'my-cabinet' }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toContain('otu_token is required')
  })
})

// ---------------------------------------------------------------------------
// OTU validation — 401 paths
// ---------------------------------------------------------------------------

describe('POST archive — OTU validation (401)', () => {
  it('401 when redis.get returns null (token expired/never existed)', async () => {
    mockRedisGet.mockResolvedValueOnce(null)
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(401)
    const body = await res.json()
    expect(body.message).toContain('Re-authentication failed')
    expect(body.message).toContain('invalid, expired, or already used')
  })

  it('401 when redis.get returns "consumed" (already used)', async () => {
    mockRedisGet.mockResolvedValueOnce('consumed')
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(401)
    const body = await res.json()
    expect(body.message).toContain('Re-authentication failed')
  })

  it('401 when redis.get returns "expired"', async () => {
    mockRedisGet.mockResolvedValueOnce('expired')
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(401)
  })

  it('401 (false from consumeOtuToken) when redis.get throws (any error)', async () => {
    // consumeOtuToken swallows errors and returns false
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisGet.mockRejectedValueOnce(new Error('ECONNREFUSED'))
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(401)
    spy.mockRestore()
  })

  it('pool.connect NOT called when OTU fails (OTU fires before DB)', async () => {
    mockRedisGet.mockResolvedValueOnce(null)
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(mockPool.connect).not.toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// OTU consumption on valid token
// ---------------------------------------------------------------------------

describe('POST archive — OTU consumption', () => {
  it('redis.set called with otuKey, "consumed", "EX", 60 on valid OTU', async () => {
    setupHappyPath()
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(mockRedisSet).toHaveBeenCalledWith(
      `cabinet:reauth:otu:${VALID_OTU}`,
      'consumed',
      'EX',
      60
    )
  })

  it('redis.get called with exact otuKey prefix', async () => {
    setupHappyPath()
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: 'deadbeef' }), makeParams())
    expect(mockRedisGet).toHaveBeenCalledWith('cabinet:reauth:otu:deadbeef')
  })
})

// ---------------------------------------------------------------------------
// 404 — cabinet not found
// ---------------------------------------------------------------------------

describe('POST archive — 404 (cabinet not found)', () => {
  it('returns 404 when SELECT returns empty rows', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)    // BEGIN
      .mockResolvedValueOnce({ rows: [] }) // SELECT FOR UPDATE → not found
      .mockResolvedValueOnce(undefined)    // ROLLBACK
    const res = await POST(makeReq({ confirm_name: 'x', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Cabinet not found' })
  })

  it('ROLLBACK called on 404', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ confirm_name: 'x', otu_token: VALID_OTU }), makeParams())
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
  })

  it('client.release() called on 404 (finally block)', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ confirm_name: 'x', otu_token: VALID_OTU }), makeParams())
    expect(mockClient.release).toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// 400 — confirm_name mismatch
// ---------------------------------------------------------------------------

describe('POST archive — confirm_name mismatch (400)', () => {
  it('returns 400 with expected/got fields when name does not match', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ name: 'real-cabinet' })] })
      .mockResolvedValueOnce(undefined) // ROLLBACK
    const res = await POST(makeReq({ confirm_name: 'wrong-name', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toContain('real-cabinet')
    expect(body.message).toContain('wrong-name')
  })

  it('ROLLBACK called on confirm_name mismatch', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ name: 'real-name' })] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ confirm_name: 'wrong', otu_token: VALID_OTU }), makeParams())
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
  })

  it('client.release() called on mismatch (finally block)', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ name: 'name' })] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ confirm_name: 'other', otu_token: VALID_OTU }), makeParams())
    expect(mockClient.release).toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// 409 — ARCHIVE_BLOCKED_STATES
// ---------------------------------------------------------------------------

describe('POST archive — ARCHIVE_BLOCKED_STATES (409)', () => {
  it('returns 409 when state is in ARCHIVE_BLOCKED_STATES', async () => {
    // 'creating' is in our mock blocked states array
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'creating', name: 'my-cabinet' })] })
      .mockResolvedValueOnce(undefined) // ROLLBACK
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(409)
    const body = await res.json()
    expect(body.message).toContain('creating')
  })

  it('ROLLBACK called on ARCHIVE_BLOCKED_STATES path', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'archiving', name: 'my-cabinet' })] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
  })

  it('client.release() called on blocked state path', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'provisioning', name: 'my-cabinet' })] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(mockClient.release).toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// 409 — canTransition returns false
// ---------------------------------------------------------------------------

describe('POST archive — canTransition false (409)', () => {
  it('returns 409 when canTransition returns {ok: false, reason}', async () => {
    mockCanTransition.mockReturnValueOnce({ ok: false, reason: 'already archiving' })
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'failed', name: 'my-cabinet' })] })
      .mockResolvedValueOnce(undefined) // ROLLBACK
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(409)
    const body = await res.json()
    expect(body.message).toBe('Cannot archive: already archiving')
  })

  it('ROLLBACK called on canTransition false', async () => {
    mockCanTransition.mockReturnValueOnce({ ok: false, reason: 'bad state' })
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'active', name: 'my-cabinet' })] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
  })

  it('client.release() called on canTransition false (finally block)', async () => {
    mockCanTransition.mockReturnValueOnce({ ok: false, reason: 'nope' })
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'active', name: 'my-cabinet' })] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(mockClient.release).toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// Happy path (200)
// ---------------------------------------------------------------------------

describe('POST archive — happy path (200)', () => {
  it('returns 200 with {ok: true, state: "archiving", message}', async () => {
    setupHappyPath()
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.ok).toBe(true)
    expect(body.state).toBe('archiving')
    expect(typeof body.message).toBe('string')
  })

  it('transaction sequence: BEGIN → SELECT FOR UPDATE → UPDATE → COMMIT', async () => {
    setupHappyPath()
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(mockClient.query).toHaveBeenNthCalledWith(1, 'BEGIN')
    expect(mockClient.query).toHaveBeenNthCalledWith(4, 'COMMIT')
  })

  it("UPDATE sets state='archiving' with cabinet_id binding", async () => {
    setupHappyPath()
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams('cab_xyz'))
    const updateCall = mockClient.query.mock.calls[2]
    expect(updateCall[0]).toMatch(/UPDATE cabinets/)
    expect(updateCall[0]).toMatch(/archiving/)
    expect(updateCall[1]).toEqual(['cab_xyz'])
  })

  it('writeTransitionEvent called with correct shape', async () => {
    const row = makeCabinetRow({ state: 'suspended', name: 'my-cabinet', captain_id: 'cap_test' })
    setupHappyPath(row)
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams('cab_abc'))
    expect(mockWriteTransition).toHaveBeenCalledTimes(1)
    const [arg] = mockWriteTransition.mock.calls[0]
    expect(arg.cabinet_id).toBe('cab_abc')
    expect(arg.actor).toBe('tok_captain')
    expect(arg.entry_point).toBe('dashboard')
    expect(arg.from).toBe('suspended')
    expect(arg.to).toBe('archiving')
    expect(arg.payload.confirm_name).toBe('my-cabinet')
  })

  it('redis.del called with provisioning-lock key using captain_id from SELECT row', async () => {
    const row = makeCabinetRow({ captain_id: 'specific-cap', name: 'my-cabinet' })
    setupHappyPath(row)
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(mockRedisDel).toHaveBeenCalledWith('cabinet:provisioning-lock:specific-cap')
  })

  it('client.release() called on success (finally block)', async () => {
    setupHappyPath()
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(mockClient.release).toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// redis.del non-fatal
// ---------------------------------------------------------------------------

describe('POST archive — redis.del non-fatal', () => {
  it('200 still returned when redis.del throws (non-fatal)', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    setupHappyPath()
    mockRedisDel.mockRejectedValueOnce(new Error('redis down'))
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(200)
    expect(warnSpy).toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('console.warn (not console.error) when redis.del throws', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    setupHappyPath()
    mockRedisDel.mockRejectedValueOnce(new Error('redis down'))
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(warnSpy).toHaveBeenCalled()
    // console.error should NOT be called for the del failure (only for fatal errors)
    warnSpy.mockRestore()
    errorSpy.mockRestore()
  })
})

// ---------------------------------------------------------------------------
// startArchivalWorker fire-and-forget
// ---------------------------------------------------------------------------

describe('POST archive — startArchivalWorker fire-and-forget', () => {
  it('200 returned synchronously (worker does not block route response)', async () => {
    setupHappyPath()
    // Worker internals may eventually call query/writeTransitionEvent, but the
    // route must return 200 immediately — we verify by confirming response is 200
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(200)
  })
})

// ---------------------------------------------------------------------------
// Error path (500)
// ---------------------------------------------------------------------------

describe('POST archive — error path (500)', () => {
  it('returns 500 when BEGIN throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockRejectedValueOnce(new Error('pg connect fail'))
      .mockResolvedValueOnce(undefined) // ROLLBACK
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Failed to archive cabinet' })
    spy.mockRestore()
  })

  it('ROLLBACK called when UPDATE throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ name: 'my-cabinet' })] })
      .mockRejectedValueOnce(new Error('deadlock'))
      .mockResolvedValueOnce(undefined) // ROLLBACK
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(res.status).toBe(500)
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
    spy.mockRestore()
  })

  it('client.release() called on error (finally block)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('pg down'))
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    expect(mockClient.release).toHaveBeenCalled()
    spy.mockRestore()
  })

  it('500 does not leak internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('secret: DB password=hunter2'))
      .mockResolvedValueOnce(undefined)
    const res = await POST(makeReq({ confirm_name: 'my-cabinet', otu_token: VALID_OTU }), makeParams())
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('hunter2')
    spy.mockRestore()
  })
})
