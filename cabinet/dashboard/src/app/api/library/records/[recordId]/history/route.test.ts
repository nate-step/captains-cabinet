// GET /api/library/records/:recordId/history — record history handler.
//
// Tiny 18-LOC handler with two response paths:
//   - 200 with {history} array on success
//   - 500 on throw
//
// Pattern: simple lib-mock (vi.hoisted + vi.mock('@/lib/library')).
// No body parsing — _req is never read, only params is consumed.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { NextRequest } from 'next/server'

const { mockGetRecordHistory } = vi.hoisted(() => ({
  mockGetRecordHistory: vi.fn(),
}))

vi.mock('@/lib/library', () => ({
  getRecordHistory: mockGetRecordHistory,
}))

import { GET } from './route'

function makeReq(): NextRequest {
  return {} as unknown as NextRequest
}

function makeParams(recordId: string) {
  return { params: Promise.resolve({ recordId }) }
}

beforeEach(() => {
  mockGetRecordHistory.mockReset()
})

describe('GET /api/library/records/:recordId/history — success (200)', () => {
  it('200 with {history} array on success', async () => {
    const hist = [
      { id: 1, changed_at: '2024-01-01', changed_by: 'cto', changes: {} },
      { id: 2, changed_at: '2024-01-02', changed_by: 'cos', changes: {} },
    ]
    mockGetRecordHistory.mockResolvedValueOnce(hist)
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ history: hist })
  })

  it('200 with empty {history: []} when no history exists', async () => {
    mockGetRecordHistory.mockResolvedValueOnce([])
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ history: [] })
  })

  it('passes recordId through to getRecordHistory', async () => {
    mockGetRecordHistory.mockResolvedValueOnce([])
    await GET(makeReq(), makeParams('record-xyz'))
    expect(mockGetRecordHistory).toHaveBeenCalledWith('record-xyz')
  })

  it('passes numeric-string recordId unchanged (no parseInt)', async () => {
    mockGetRecordHistory.mockResolvedValueOnce([])
    await GET(makeReq(), makeParams('12345'))
    expect(mockGetRecordHistory).toHaveBeenCalledWith('12345')
  })
})

describe('GET /api/library/records/:recordId/history — error path (500)', () => {
  it('500 when getRecordHistory throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockGetRecordHistory.mockRejectedValueOnce(new Error('pg down'))
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ error: 'Failed to get history' })
    spy.mockRestore()
  })

  it('500 never leaks internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockGetRecordHistory.mockRejectedValueOnce(new Error('secret: conn=pg://u:pw@host'))
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(body.error).toBe('Failed to get history')
    expect(JSON.stringify(body)).not.toContain('pw@host')
    spy.mockRestore()
  })

  it('500 body has exactly {error} key (no extra fields)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockGetRecordHistory.mockRejectedValueOnce(new Error('oops'))
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(Object.keys(body)).toEqual(['error'])
    spy.mockRestore()
  })
})
