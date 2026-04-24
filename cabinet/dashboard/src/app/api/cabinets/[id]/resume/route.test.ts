// Spec 034 — POST /api/cabinets/[id]/resume handler harness
//
// Mirrors suspend harness structure. Key differences vs. suspend:
//   - canTransition target is 'starting' (not 'suspended')
//   - 409 message prefix is 'Cannot resume:' (not 'Cannot suspend:')
//   - UPDATE sets state='starting' (not 'suspended')
//   - Response body: {ok: true, state: 'starting'}
//   - writeTransitionEvent: to='starting'
//
// No Redis in this handler — pure pg transaction.

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
function setupHappyPath(state = 'suspended') {
  mockClient.query
    .mockResolvedValueOnce(undefined)                          // BEGIN
    .mockResolvedValueOnce({ rows: [{ state }] })              // SELECT FOR UPDATE
    .mockResolvedValueOnce(undefined)                          // UPDATE
    .mockResolvedValueOnce(undefined)                          // COMMIT
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

describe('POST /api/cabinets/[id]/resume — guard short-circuit', () => {
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

describe('POST /api/cabinets/[id]/resume — 404 (cabinet not found)', () => {
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

describe('POST /api/cabinets/[id]/resume — 409 (invalid state transition)', () => {
  it('returns 409 when canTransition returns {ok: false, reason}', async () => {
    mockCanTransition.mockReturnValueOnce({ ok: false, reason: 'state is active, not suspended' })
    mockClient.query
      .mockResolvedValueOnce(undefined)                             // BEGIN
      .mockResolvedValueOnce({ rows: [{ state: 'active' }] })      // SELECT
      .mockResolvedValueOnce(undefined)                             // ROLLBACK
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(409)
    const body = await res.json()
    expect(body.message).toBe('Cannot resume: state is active, not suspended')
  })

  it('message prefix is "Cannot resume:" (not "Cannot suspend:")', async () => {
    mockCanTransition.mockReturnValueOnce({ ok: false, reason: 'wrong state' })
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [{ state: 'active' }] })
      .mockResolvedValueOnce(undefined)
    const res = await POST(makeReq(), makeParams('cab_abc'))
    const body = await res.json()
    expect(body.message).toMatch(/^Cannot resume:/)
    expect(body.message).not.toMatch(/suspend/)
  })

  it('ROLLBACK called on 409', async () => {
    mockCanTransition.mockReturnValueOnce({ ok: false, reason: 'bad state' })
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [{ state: 'failed' }] })
      .mockResolvedValueOnce(undefined) // ROLLBACK
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
  })

  it('client.release() called on 409 (finally block)', async () => {
    mockCanTransition.mockReturnValueOnce({ ok: false, reason: 'no' })
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [{ state: 'creating' }] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.release).toHaveBeenCalled()
  })
})

describe('POST /api/cabinets/[id]/resume — happy path (200)', () => {
  it('returns 200 with {ok: true, state: "starting"}', async () => {
    setupHappyPath('suspended')
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ ok: true, state: 'starting' })
  })

  it('transaction sequence: BEGIN → SELECT FOR UPDATE → UPDATE → COMMIT', async () => {
    setupHappyPath('suspended')
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.query).toHaveBeenNthCalledWith(1, 'BEGIN')
    expect(mockClient.query).toHaveBeenNthCalledWith(4, 'COMMIT')
  })

  it('UPDATE sets state="starting" (not "active" or "suspended")', async () => {
    setupHappyPath('suspended')
    await POST(makeReq(), makeParams('cab_abc'))
    const updateCall = mockClient.query.mock.calls[2]
    expect(updateCall[0]).toMatch(/UPDATE cabinets/)
    expect(updateCall[0]).toMatch(/state = 'starting'/)
  })

  it('UPDATE uses cabinet_id binding', async () => {
    setupHappyPath('suspended')
    await POST(makeReq(), makeParams('cab_specific'))
    const updateCall = mockClient.query.mock.calls[2]
    expect(updateCall[1]).toEqual(['cab_specific'])
  })

  it('writeTransitionEvent called with to="starting"', async () => {
    setupHappyPath('suspended')
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockWriteTransition).toHaveBeenCalledTimes(1)
    const [arg] = mockWriteTransition.mock.calls[0]
    expect(arg.cabinet_id).toBe('cab_abc')
    expect(arg.actor).toBe('captain')
    expect(arg.entry_point).toBe('dashboard')
    expect(arg.from).toBe('suspended')
    expect(arg.to).toBe('starting')
  })

  it('canTransition called with current state and "starting" target', async () => {
    setupHappyPath('suspended')
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockCanTransition).toHaveBeenCalledWith('suspended', 'starting')
  })

  it('client.release() always called on success (finally block)', async () => {
    setupHappyPath('suspended')
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.release).toHaveBeenCalled()
  })
})

describe('POST /api/cabinets/[id]/resume — error path (500)', () => {
  it('returns 500 when client.query throws mid-transaction', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('pg deadlock'))
      .mockResolvedValueOnce(undefined) // ROLLBACK
    const res = await POST(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Failed to resume cabinet' })
    spy.mockRestore()
  })

  it('ROLLBACK called on unexpected error', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('pg down'))
      .mockResolvedValueOnce(undefined)
    await POST(makeReq(), makeParams('cab_abc'))
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
    spy.mockRestore()
  })

  it('client.release() called on error (finally block)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('connection reset'))
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
