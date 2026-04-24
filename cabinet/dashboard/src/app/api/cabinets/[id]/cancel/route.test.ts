// Spec 034 — POST /api/cabinets/[id]/cancel handler harness
//
// Quirk notes:
//   - cancel uses HARD-CODED state check (state !== 'adopting-bots') instead of
//     canTransition() — there is NO state-machine import here. 409 check is manual.
//   - The transition goes to 'failed' (not 'cancelled') per state-machine mapping.
//   - writeAuditEvent (NOT writeTransitionEvent) is called: event_type='cancel'
//     plus per-orphan event_type='orphan_bot' calls.
//   - redis.del(lockKey) called AFTER COMMIT using captain_id from the SELECT row.
//   - Redis del failure is console.warn (not error) and does NOT fail the request.
//   - officer_slots from SELECT row: if state='adopting-bots', some may have
//     bot_token set (adoptedSlots) — those get orphan audit events.
//   - Response body: {ok, message, orphaned_bots: slot.role[]}

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

const {
  mockGuard,
  mockQuery,
  mockClient,
  mockPool,
  mockWriteAudit,
  mockRedisGet,
  mockRedisSet,
  mockRedisDel,
} = vi.hoisted(() => {
  const client = { query: vi.fn(), release: vi.fn() }
  const pool = { connect: vi.fn(async () => client) }
  return {
    mockGuard: vi.fn(),
    mockQuery: vi.fn(),
    mockClient: client,
    mockPool: pool,
    mockWriteAudit: vi.fn(),
    mockRedisGet: vi.fn(),
    mockRedisSet: vi.fn(),
    mockRedisDel: vi.fn(),
  }
})

vi.mock('@/lib/provisioning/guard', () => ({
  requireProvisioningAccess: mockGuard,
}))

vi.mock('@/lib/db', () => ({
  query: mockQuery,
  getDbPool: () => mockPool,
}))

vi.mock('@/lib/provisioning/audit', () => ({
  writeAuditEvent: mockWriteAudit,
}))

vi.mock('@/lib/redis', () => ({
  default: { get: mockRedisGet, set: mockRedisSet, del: mockRedisDel },
}))

import { POST } from './route'

function makeReq(): NextRequest {
  return {} as unknown as NextRequest
}

function makeParams(id: string) {
  return { params: Promise.resolve({ id }) }
}

/** Default SELECT row: cabinet in adopting-bots state with no adopted slots */
function makeCabinetRow(overrides: {
  state?: string
  officer_slots?: Array<{ role: string; bot_token: string | null; adopted_at: string | null }>
  captain_id?: string
} = {}) {
  return {
    captain_id: overrides.captain_id ?? 'captain',
    state: overrides.state ?? 'adopting-bots',
    officer_slots: overrides.officer_slots ?? [],
  }
}

/** Sets up happy-path client.query: BEGIN / SELECT / UPDATE / COMMIT */
function setupHappyPath(row = makeCabinetRow()) {
  mockClient.query
    .mockResolvedValueOnce(undefined)              // BEGIN
    .mockResolvedValueOnce({ rows: [row] })         // SELECT FOR UPDATE
    .mockResolvedValueOnce(undefined)              // UPDATE
    .mockResolvedValueOnce(undefined)              // COMMIT
}

beforeEach(() => {
  mockGuard.mockReset()
  mockClient.query.mockReset()
  mockClient.release.mockReset()
  mockPool.connect.mockReset()
  mockPool.connect.mockImplementation(async () => mockClient)
  mockWriteAudit.mockReset()
  mockRedisGet.mockReset()
  mockRedisSet.mockReset()
  mockRedisDel.mockReset()

  mockGuard.mockResolvedValue({ response: null, user: { token: 'captain' } })
  mockWriteAudit.mockResolvedValue(undefined)
  mockRedisDel.mockResolvedValue(1)
})

describe('POST /api/cabinets/[id]/cancel — guard short-circuit', () => {
  it('returns guard.response directly when guard fires (503)', async () => {
    const flagResp = NextResponse.json({ ok: false, disabled: true }, { status: 503 })
    mockGuard.mockResolvedValueOnce({ response: flagResp, user: null })
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(503)
    expect(mockClient.query).not.toHaveBeenCalled()
  })

  it('returns guard.response directly when auth guard fires (401)', async () => {
    const authResp = NextResponse.json({ ok: false, message: 'Unauthorized' }, { status: 401 })
    mockGuard.mockResolvedValueOnce({ response: authResp, user: null })
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(401)
    expect(mockClient.query).not.toHaveBeenCalled()
  })
})

describe('POST /api/cabinets/[id]/cancel — 404 (cabinet not found)', () => {
  it('returns 404 when SELECT returns empty rows', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce(undefined) // ROLLBACK
    const res = await POST(makeReq(), makeParams('cab_nonexistent'))
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Cabinet not found' })
  })

  it('ROLLBACK called on 404', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq(), makeParams('cab_nonexistent'))
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
  })

  it('client.release() called on 404 (finally block)', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq(), makeParams('cab_nonexistent'))
    expect(mockClient.release).toHaveBeenCalled()
  })
})

describe('POST /api/cabinets/[id]/cancel — 409 (wrong state)', () => {
  it('returns 409 when state is not "adopting-bots" (e.g. active)', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'active' })] })
      .mockResolvedValueOnce(undefined) // ROLLBACK
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(409)
    const body = await res.json()
    expect(body.message).toContain("Cancel is only valid in 'adopting-bots' state")
    expect(body.message).toContain("Current state: 'active'")
  })

  it('returns 409 when state is "creating"', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'creating' })] })
      .mockResolvedValueOnce(undefined)
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(409)
  })

  it('returns 409 when state is "provisioning"', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'provisioning' })] })
      .mockResolvedValueOnce(undefined)
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(409)
  })

  it('ROLLBACK called on 409 state mismatch', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'active' })] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
  })

  it('client.release() called on 409 (finally block)', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'suspended' })] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.release).toHaveBeenCalled()
  })
})

describe('POST /api/cabinets/[id]/cancel — happy path (200), no adopted slots', () => {
  it('returns 200 with ok, message, and empty orphaned_bots', async () => {
    setupHappyPath()
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.ok).toBe(true)
    expect(body.message).toBe('Cabinet cancelled and moved to failed state')
    expect(body.orphaned_bots).toEqual([])
  })

  it('UPDATE sets state="failed" (cancellation maps to failed in state machine)', async () => {
    setupHappyPath()
    await POST(makeReq(), makeParams('cab_abc'))
    const updateCall = mockClient.query.mock.calls[2]
    expect(updateCall[0]).toMatch(/UPDATE cabinets/)
    expect(updateCall[0]).toMatch(/state = 'failed'/)
    expect(updateCall[1]).toEqual(['cab_abc'])
  })

  it('transaction sequence: BEGIN → SELECT FOR UPDATE → UPDATE → COMMIT', async () => {
    setupHappyPath()
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.query).toHaveBeenNthCalledWith(1, 'BEGIN')
    expect(mockClient.query).toHaveBeenNthCalledWith(4, 'COMMIT')
  })

  it('writeAuditEvent called with cancel event shape', async () => {
    setupHappyPath()
    await POST(makeReq(), makeParams('cab_abc'))
    const cancelCall = mockWriteAudit.mock.calls[0][0]
    expect(cancelCall.cabinet_id).toBe('cab_abc')
    expect(cancelCall.actor).toBe('captain')
    expect(cancelCall.entry_point).toBe('dashboard')
    expect(cancelCall.event_type).toBe('cancel')
    expect(cancelCall.state_before).toBe('adopting-bots')
    expect(cancelCall.state_after).toBe('failed')
    expect(cancelCall.payload.reason).toBe('captain-cancelled')
    expect(cancelCall.payload.partially_adopted_count).toBe(0)
  })

  it('redis.del(lockKey) called with captain_id from SELECT row', async () => {
    setupHappyPath(makeCabinetRow({ captain_id: 'specific-captain' }))
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockRedisDel).toHaveBeenCalledWith('cabinet:provisioning-lock:specific-captain')
  })

  it('client.release() called on success (finally block)', async () => {
    setupHappyPath()
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.release).toHaveBeenCalled()
  })
})

describe('POST /api/cabinets/[id]/cancel — happy path with adopted slots', () => {
  it('orphaned_bots contains roles of slots with bot_token set', async () => {
    const slots = [
      { role: 'cos', bot_token: '123:abc', adopted_at: '2024-01-01T00:00:00Z' },
      { role: 'cto', bot_token: null, adopted_at: null },
      { role: 'cpo', bot_token: '456:def', adopted_at: '2024-01-01T00:00:00Z' },
    ]
    setupHappyPath(makeCabinetRow({ officer_slots: slots }))
    const res = await POST(makeReq(), makeParams('cab_abc'))
    const body = await res.json()
    expect(body.orphaned_bots).toEqual(['cos', 'cpo'])
  })

  it('writeAuditEvent called per orphaned slot (event_type="orphan_bot")', async () => {
    const slots = [
      { role: 'cos', bot_token: '123:abc', adopted_at: '2024-01-01T00:00:00Z' },
      { role: 'cto', bot_token: '456:def', adopted_at: '2024-01-01T00:00:00Z' },
    ]
    setupHappyPath(makeCabinetRow({ officer_slots: slots }))
    await POST(makeReq(), makeParams('cab_abc'))
    // First call is cancel event, then one per orphaned slot
    const orphanCalls = mockWriteAudit.mock.calls.filter(
      ([arg]) => arg.event_type === 'orphan_bot'
    )
    expect(orphanCalls).toHaveLength(2)
    const roles = orphanCalls.map(([arg]) => arg.payload.officer)
    expect(roles).toContain('cos')
    expect(roles).toContain('cto')
  })

  it('partially_adopted_count in cancel event matches adopted slot count', async () => {
    const slots = [
      { role: 'cos', bot_token: '111:aaa', adopted_at: '2024-01-01' },
      { role: 'cto', bot_token: null, adopted_at: null },
    ]
    setupHappyPath(makeCabinetRow({ officer_slots: slots }))
    await POST(makeReq(), makeParams('cab_abc'))
    const [cancelArg] = mockWriteAudit.mock.calls[0]
    expect(cancelArg.payload.partially_adopted_count).toBe(1)
  })

  it('no orphan_bot events when no slots have bot_token', async () => {
    const slots = [
      { role: 'cos', bot_token: null, adopted_at: null },
      { role: 'cto', bot_token: null, adopted_at: null },
    ]
    setupHappyPath(makeCabinetRow({ officer_slots: slots }))
    await POST(makeReq(), makeParams('cab_abc'))
    const orphanCalls = mockWriteAudit.mock.calls.filter(
      ([arg]) => arg.event_type === 'orphan_bot'
    )
    expect(orphanCalls).toHaveLength(0)
  })
})

describe('POST /api/cabinets/[id]/cancel — Redis lock cleanup', () => {
  it('redis.del failure is non-fatal (console.warn, request still succeeds)', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    setupHappyPath()
    mockRedisDel.mockRejectedValueOnce(new Error('redis down'))
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(200)
    expect(warnSpy).toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('lock key uses captain_id from SELECT (not from guard.user)', async () => {
    // captain_id in SELECT row may differ from guard token (future multi-tenant)
    setupHappyPath(makeCabinetRow({ captain_id: 'row-captain' }))
    await POST(makeReq(), makeParams('cab_abc'))
    const [delKey] = mockRedisDel.mock.calls[0]
    expect(delKey).toBe('cabinet:provisioning-lock:row-captain')
  })
})

describe('POST /api/cabinets/[id]/cancel — error path (500)', () => {
  it('returns 500 when client.query throws mid-transaction', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('pg deadlock'))
      .mockResolvedValueOnce(undefined) // ROLLBACK
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Failed to cancel cabinet' })
    spy.mockRestore()
  })

  it('ROLLBACK called on unexpected error', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('connection reset'))
      .mockResolvedValueOnce(undefined)
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
    spy.mockRestore()
  })

  it('client.release() called on error (finally block)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('pg down'))
      .mockResolvedValueOnce(undefined)
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.release).toHaveBeenCalled()
    spy.mockRestore()
  })

  it('500 does not leak internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('secret: PGPASSWORD=hunter2'))
      .mockResolvedValueOnce(undefined)
    const res = await POST(makeReq(), makeParams('cab_abc'))
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('hunter2')
    spy.mockRestore()
  })
})
