// Spec 034 — POST /api/cabinets/[id]/suspend handler harness
//
// Transaction pattern: client.query returns {rows} (NOT raw array).
// query<T>() (lib/db standalone) returns T[] directly — different API.
// Here we only use getDbPool/client.query (transactional handler).
//
// Transaction sequence: BEGIN → SELECT FOR UPDATE → UPDATE → COMMIT
// 404 and 409 both issue ROLLBACK before returning.
// client.release() is ALWAYS called via finally block.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

const {
  mockGuard,
  mockQuery,
  mockClient,
  mockPool,
  mockCanTransition,
  mockWriteTransition,
} = vi.hoisted(() => {
  const client = { query: vi.fn(), release: vi.fn() }
  const pool = { connect: vi.fn(async () => client) }
  return {
    mockGuard: vi.fn(),
    mockQuery: vi.fn(),
    mockClient: client,
    mockPool: pool,
    mockCanTransition: vi.fn(),
    mockWriteTransition: vi.fn(),
  }
})

vi.mock('@/lib/provisioning/guard', () => ({
  requireProvisioningAccess: mockGuard,
}))

vi.mock('@/lib/db', () => ({
  query: mockQuery,
  getDbPool: () => mockPool,
}))

vi.mock('@/lib/provisioning/state-machine', () => ({
  canTransition: mockCanTransition,
}))

vi.mock('@/lib/provisioning/audit', () => ({
  writeTransitionEvent: mockWriteTransition,
}))

import { POST } from './route'

function makeReq(): NextRequest {
  return {} as unknown as NextRequest
}

function makeParams(id: string) {
  return { params: Promise.resolve({ id }) }
}

/** Sets up happy-path client.query sequence: BEGIN / SELECT / UPDATE / COMMIT */
function setupHappyPath(state = 'active') {
  mockClient.query
    .mockResolvedValueOnce(undefined)                         // BEGIN
    .mockResolvedValueOnce({ rows: [{ state }] })             // SELECT FOR UPDATE
    .mockResolvedValueOnce(undefined)                         // UPDATE
    .mockResolvedValueOnce(undefined)                         // COMMIT
}

beforeEach(() => {
  mockGuard.mockReset()
  mockClient.query.mockReset()
  mockClient.release.mockReset()
  mockPool.connect.mockReset()
  mockPool.connect.mockImplementation(async () => mockClient)
  mockCanTransition.mockReset()
  mockWriteTransition.mockReset()

  mockGuard.mockResolvedValue({ response: null, user: { token: 'captain' } })
  mockCanTransition.mockReturnValue({ ok: true })
  mockWriteTransition.mockResolvedValue(undefined)
})

describe('POST /api/cabinets/[id]/suspend — guard short-circuit', () => {
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

describe('POST /api/cabinets/[id]/suspend — 404 (cabinet not found)', () => {
  it('returns 404 when SELECT returns empty rows', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)        // BEGIN
      .mockResolvedValueOnce({ rows: [] })      // SELECT FOR UPDATE → not found
      .mockResolvedValueOnce(undefined)         // ROLLBACK
    const res = await POST(makeReq(), makeParams('cab_nonexistent'))
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Cabinet not found' })
  })

  it('ROLLBACK called on 404', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce(undefined) // ROLLBACK
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

describe('POST /api/cabinets/[id]/suspend — 409 (invalid state transition)', () => {
  it('returns 409 when canTransition returns {ok: false, reason}', async () => {
    mockCanTransition.mockReturnValueOnce({ ok: false, reason: 'state is creating, not active' })
    mockClient.query
      .mockResolvedValueOnce(undefined)                              // BEGIN
      .mockResolvedValueOnce({ rows: [{ state: 'creating' }] })     // SELECT
      .mockResolvedValueOnce(undefined)                              // ROLLBACK
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(409)
    const body = await res.json()
    expect(body.message).toBe('Cannot suspend: state is creating, not active')
  })

  it('ROLLBACK called on 409 invalid transition', async () => {
    mockCanTransition.mockReturnValueOnce({ ok: false, reason: 'bad state' })
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [{ state: 'failed' }] })
      .mockResolvedValueOnce(undefined) // ROLLBACK
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
  })

  it('client.release() called on 409 (finally block)', async () => {
    mockCanTransition.mockReturnValueOnce({ ok: false, reason: 'not ok' })
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [{ state: 'suspended' }] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.release).toHaveBeenCalled()
  })
})

describe('POST /api/cabinets/[id]/suspend — happy path (200)', () => {
  it('returns 200 with {ok: true, state: "suspended"}', async () => {
    setupHappyPath('active')
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ ok: true, state: 'suspended' })
  })

  it('transaction sequence: BEGIN → SELECT FOR UPDATE → UPDATE → COMMIT', async () => {
    setupHappyPath('active')
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.query).toHaveBeenNthCalledWith(1, 'BEGIN')
    expect(mockClient.query).toHaveBeenNthCalledWith(4, 'COMMIT')
  })

  it('UPDATE sets state="suspended" with cabinet_id binding', async () => {
    setupHappyPath('active')
    await POST(makeReq(), makeParams('cab_specific'))
    const updateCall = mockClient.query.mock.calls[2]
    expect(updateCall[0]).toMatch(/UPDATE cabinets/)
    expect(updateCall[0]).toMatch(/state = 'suspended'/)
    expect(updateCall[1]).toEqual(['cab_specific'])
  })

  it('writeTransitionEvent called with correct shape', async () => {
    setupHappyPath('active')
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockWriteTransition).toHaveBeenCalledTimes(1)
    const [arg] = mockWriteTransition.mock.calls[0]
    expect(arg.cabinet_id).toBe('cab_abc')
    expect(arg.actor).toBe('captain')
    expect(arg.entry_point).toBe('dashboard')
    expect(arg.from).toBe('active')
    expect(arg.to).toBe('suspended')
  })

  it('client.release() always called on success (finally block)', async () => {
    setupHappyPath('active')
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.release).toHaveBeenCalled()
  })

  it('canTransition called with current state and "suspended" target', async () => {
    setupHappyPath('active')
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockCanTransition).toHaveBeenCalledWith('active', 'suspended')
  })
})

describe('POST /api/cabinets/[id]/suspend — error path (500)', () => {
  it('returns 500 when client.query throws mid-transaction', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)                        // BEGIN
      .mockRejectedValueOnce(new Error('pg deadlock'))         // SELECT throws
      .mockResolvedValueOnce(undefined)                        // ROLLBACK
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Failed to suspend cabinet' })
    spy.mockRestore()
  })

  it('ROLLBACK called on unexpected error', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('connection reset'))
      .mockResolvedValueOnce(undefined) // ROLLBACK
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
