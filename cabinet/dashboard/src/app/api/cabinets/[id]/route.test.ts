// Spec 034 — GET /api/cabinets/[id] handler harness
//
// Uses Next.js 15 async params pattern: {params: Promise.resolve({id})}
// query<T>() returns T[] directly (not {rows}).

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

const { mockGuard, mockQuery } = vi.hoisted(() => ({
  mockGuard: vi.fn(),
  mockQuery: vi.fn(),
}))

vi.mock('@/lib/provisioning/guard', () => ({
  requireProvisioningAccess: mockGuard,
}))

vi.mock('@/lib/db', () => ({
  query: mockQuery,
}))

import { GET } from './route'

function makeReq(): NextRequest {
  return {} as unknown as NextRequest
}

function makeParams(id: string) {
  return { params: Promise.resolve({ id }) }
}

const mockCabinet = {
  cabinet_id: 'cab_abc0123456789def',
  captain_id: 'captain',
  name: 'my-cabinet',
  preset: 'work',
  capacity: 'work',
  state: 'active',
  state_entered_at: '2024-01-01T00:00:00Z',
  officer_slots: [],
  retry_count: 0,
  created_at: '2024-01-01T00:00:00Z',
}

beforeEach(() => {
  mockGuard.mockReset()
  mockQuery.mockReset()
  mockGuard.mockResolvedValue({ response: null, user: { token: 'captain' } })
})

describe('GET /api/cabinets/[id] — guard short-circuit', () => {
  it('returns guard.response directly when guard fires (503)', async () => {
    const flagResp = NextResponse.json({ ok: false, disabled: true }, { status: 503 })
    mockGuard.mockResolvedValueOnce({ response: flagResp, user: null })
    const res = await GET(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(503)
    expect(mockQuery).not.toHaveBeenCalled()
  })

  it('returns guard.response directly when auth guard fires (401)', async () => {
    const authResp = NextResponse.json({ ok: false, message: 'Unauthorized' }, { status: 401 })
    mockGuard.mockResolvedValueOnce({ response: authResp, user: null })
    const res = await GET(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(401)
    expect(mockQuery).not.toHaveBeenCalled()
  })
})

describe('GET /api/cabinets/[id] — 404 when not found', () => {
  it('returns 404 when query returns empty array', async () => {
    mockQuery.mockResolvedValueOnce([])
    const res = await GET(makeReq(), makeParams('cab_nonexistent'))
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Cabinet not found' })
  })

  it('query called with WHERE cabinet_id = $1 and id binding', async () => {
    mockQuery.mockResolvedValueOnce([])
    await GET(makeReq(), makeParams('cab_specific123'))
    const [sql, params] = mockQuery.mock.calls[0]
    expect(sql).toMatch(/WHERE cabinet_id = \$1/)
    expect(params).toEqual(['cab_specific123'])
  })
})

describe('GET /api/cabinets/[id] — happy path (200)', () => {
  it('returns 200 with {ok: true, cabinet: row}', async () => {
    mockQuery.mockResolvedValueOnce([mockCabinet])
    const res = await GET(makeReq(), makeParams('cab_abc0123456789def'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ ok: true, cabinet: mockCabinet })
  })

  it('returns only the first row (rows[0]) not the full array', async () => {
    const row1 = { ...mockCabinet, cabinet_id: 'cab_1' }
    const row2 = { ...mockCabinet, cabinet_id: 'cab_2' }
    mockQuery.mockResolvedValueOnce([row1, row2])
    const res = await GET(makeReq(), makeParams('cab_1'))
    const body = await res.json()
    expect(body.cabinet).toEqual(row1)
    expect(body.cabinet).not.toHaveProperty('length')
  })

  it('params Promise is awaited correctly (Next.js 15 async params)', async () => {
    mockQuery.mockResolvedValueOnce([mockCabinet])
    // Simulate a delayed params Promise
    const delayedParams = { params: new Promise<{ id: string }>((resolve) => setTimeout(() => resolve({ id: 'cab_delayed' }), 0)) }
    await GET(makeReq(), delayedParams)
    const [, params] = mockQuery.mock.calls[0]
    expect(params).toEqual(['cab_delayed'])
  })
})

describe('GET /api/cabinets/[id] — error path (500)', () => {
  it('returns 500 with {ok: false, message} when query throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockQuery.mockRejectedValueOnce(new Error('pg connection timeout'))
    const res = await GET(makeReq(), makeParams('cab_abc'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Failed to fetch cabinet' })
    spy.mockRestore()
  })

  it('500 does not leak internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockQuery.mockRejectedValueOnce(new Error('secret: PGPASSWORD=hunter2'))
    const res = await GET(makeReq(), makeParams('cab_abc'))
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('hunter2')
    expect(JSON.stringify(body)).not.toContain('PGPASSWORD')
    spy.mockRestore()
  })
})
