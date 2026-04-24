// PATCH /api/library/records/:recordId/status — route handler harness.
//
// First test in the src/app/api/** tree — establishes the pattern for the
// remaining 22 untested route handlers:
//   - vi.mock('@/lib/library') to stub the DB boundary (no pg-pool setup)
//   - minimal NextRequest shape: only .json() is called by PATCH
//   - params delivered as a Promise<{ recordId }> per Next.js 15 async params
//
// Coverage: all 6 response paths the route emits.
//   - 503 migration gate (AC #24 v3.2 — set before auth/DB reads)
//   - 400 body-validation (missing status + invalid status)
//   - 409 invalid_transition (AC #16 v3.2 — shape: from/to/allowed_transitions)
//   - 404 record-not-found
//   - 200 success
//   - 500 exception path
// Plus: supersededByRecordId pass-through, env-var truthy-only-for-'1'.

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import type { NextRequest } from 'next/server'

// vi.mock is hoisted to top-of-file; use vi.hoisted so the shared mock fn
// survives hoisting and we can assert on it from each test.
const { mockUpdate } = vi.hoisted(() => ({ mockUpdate: vi.fn() }))

vi.mock('@/lib/library', () => ({
  updateRecordStatus: mockUpdate,
}))

// Import AFTER vi.mock so the route picks up the mock.
import { PATCH } from './route'

function makeReq(body: unknown): NextRequest {
  return {
    json: async () => body,
  } as unknown as NextRequest
}

function makeParams(recordId: string) {
  return { params: Promise.resolve({ recordId }) }
}

beforeEach(() => {
  mockUpdate.mockReset()
  delete process.env.LIBRARY_MIGRATION_IN_PROGRESS
})

afterEach(() => {
  delete process.env.LIBRARY_MIGRATION_IN_PROGRESS
})

describe('PATCH status — migration gate (AC #24)', () => {
  it('returns 503 with retry_after_seconds when LIBRARY_MIGRATION_IN_PROGRESS=1', async () => {
    process.env.LIBRARY_MIGRATION_IN_PROGRESS = '1'
    const res = await PATCH(makeReq({ status: 'approved' }), makeParams('42'))
    expect(res.status).toBe(503)
    const body = await res.json()
    expect(body).toEqual({ error: 'migration_in_progress', retry_after_seconds: 300 })
  })

  it('does NOT call updateRecordStatus when migration gate fires', async () => {
    process.env.LIBRARY_MIGRATION_IN_PROGRESS = '1'
    await PATCH(makeReq({ status: 'approved' }), makeParams('42'))
    expect(mockUpdate).not.toHaveBeenCalled()
  })

  it('migration gate only triggers on exact "1" (not "0" / "true" / "")', async () => {
    for (const falsy of ['0', 'true', 'yes', '', 'false']) {
      process.env.LIBRARY_MIGRATION_IN_PROGRESS = falsy
      mockUpdate.mockResolvedValueOnce({ ok: true })
      const res = await PATCH(makeReq({ status: 'approved' }), makeParams('42'))
      expect(res.status, `gate should NOT fire on "${falsy}"`).not.toBe(503)
    }
  })
})

describe('PATCH status — body validation (400)', () => {
  it('400 when status field is missing from body', async () => {
    const res = await PATCH(makeReq({}), makeParams('42'))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toContain('status must be one of')
    expect(body.error).toContain('draft')
    expect(body.error).toContain('superseded')
  })

  it('400 when status is empty string', async () => {
    const res = await PATCH(makeReq({ status: '' }), makeParams('42'))
    expect(res.status).toBe(400)
  })

  it('400 when status is not a valid RecordStatus', async () => {
    const res = await PATCH(makeReq({ status: 'published' }), makeParams('42'))
    expect(res.status).toBe(400)
    expect(mockUpdate).not.toHaveBeenCalled()
  })

  it('400 error lists all 5 valid statuses', async () => {
    const res = await PATCH(makeReq({ status: 'bogus' }), makeParams('42'))
    const body = await res.json()
    for (const s of ['draft', 'in_review', 'approved', 'implemented', 'superseded']) {
      expect(body.error).toContain(s)
    }
  })

  it('accepts all 5 valid statuses (no 400 before reaching updateRecordStatus)', async () => {
    for (const s of ['draft', 'in_review', 'approved', 'implemented', 'superseded']) {
      mockUpdate.mockResolvedValueOnce({ ok: true })
      const res = await PATCH(makeReq({ status: s }), makeParams('42'))
      expect(res.status, `${s} should pass validation`).not.toBe(400)
    }
  })
})

describe('PATCH status — invalid transition (409, AC #16)', () => {
  it('returns 409 with exact {error, from, to, allowed_transitions} shape', async () => {
    mockUpdate.mockResolvedValueOnce({
      ok: false,
      error: 'Invalid status transition',
      current_status: 'draft',
      allowed_transitions: ['in_review', 'superseded'],
    })
    const res = await PATCH(makeReq({ status: 'approved' }), makeParams('42'))
    expect(res.status).toBe(409)
    const body = await res.json()
    expect(body).toEqual({
      error: 'invalid_transition',
      from: 'draft',
      to: 'approved',
      allowed_transitions: ['in_review', 'superseded'],
    })
  })

  it('passes recordId through to updateRecordStatus', async () => {
    mockUpdate.mockResolvedValueOnce({ ok: true })
    await PATCH(makeReq({ status: 'approved' }), makeParams('12345'))
    expect(mockUpdate).toHaveBeenCalledWith('12345', 'approved', undefined)
  })

  it('passes superseded_by_record_id through as 3rd arg', async () => {
    mockUpdate.mockResolvedValueOnce({ ok: true })
    await PATCH(
      makeReq({ status: 'superseded', superseded_by_record_id: '999' }),
      makeParams('42')
    )
    expect(mockUpdate).toHaveBeenCalledWith('42', 'superseded', '999')
  })

  it('409 even when allowed_transitions is empty (e.g. superseded terminal)', async () => {
    mockUpdate.mockResolvedValueOnce({
      ok: false,
      error: 'Invalid status transition',
      current_status: 'superseded',
      allowed_transitions: [],
    })
    const res = await PATCH(makeReq({ status: 'draft' }), makeParams('42'))
    expect(res.status).toBe(409)
    const body = await res.json()
    expect(body.from).toBe('superseded')
    expect(body.allowed_transitions).toEqual([])
  })
})

describe('PATCH status — not found (404)', () => {
  it('returns 404 when updateRecordStatus returns ok:false without current_status', async () => {
    mockUpdate.mockResolvedValueOnce({
      ok: false,
      error: 'Record not found or already superseded',
    })
    const res = await PATCH(makeReq({ status: 'approved' }), makeParams('9999'))
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body.error).toBe('Record not found or already superseded')
  })

  it('returns 404 for unreachable-target path (ok:false + no current_status)', async () => {
    // updateRecordStatus returns this shape when reachableFrom.length === 0
    mockUpdate.mockResolvedValueOnce({
      ok: false,
      error: 'No valid transition to approved',
    })
    const res = await PATCH(makeReq({ status: 'approved' }), makeParams('42'))
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body.error).toBe('No valid transition to approved')
  })
})

describe('PATCH status — success (200)', () => {
  it('returns 200 with {ok: true} on success', async () => {
    mockUpdate.mockResolvedValueOnce({ ok: true })
    const res = await PATCH(makeReq({ status: 'approved' }), makeParams('42'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ ok: true })
  })

  it('200 body does NOT include error or current_status', async () => {
    mockUpdate.mockResolvedValueOnce({ ok: true })
    const res = await PATCH(makeReq({ status: 'implemented' }), makeParams('42'))
    const body = await res.json()
    expect(body).not.toHaveProperty('error')
    expect(body).not.toHaveProperty('current_status')
  })
})

describe('PATCH status — exception path (500)', () => {
  it('returns 500 when updateRecordStatus throws', async () => {
    mockUpdate.mockRejectedValueOnce(new Error('pg connection refused'))
    // Silence expected console.error during the test
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const res = await PATCH(makeReq({ status: 'approved' }), makeParams('42'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ error: 'Status update failed' })
    spy.mockRestore()
  })

  it('returns 500 when req.json() throws (malformed body)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const badReq = {
      json: async () => {
        throw new SyntaxError('Unexpected token < in JSON at position 0')
      },
    } as unknown as NextRequest
    const res = await PATCH(badReq, makeParams('42'))
    expect(res.status).toBe(500)
    spy.mockRestore()
  })

  it('500 never leaks internal error detail to client', async () => {
    mockUpdate.mockRejectedValueOnce(new Error('secret: DB password=hunter2'))
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const res = await PATCH(makeReq({ status: 'approved' }), makeParams('42'))
    const body = await res.json()
    expect(body.error).toBe('Status update failed')
    expect(JSON.stringify(body)).not.toContain('hunter2')
    expect(JSON.stringify(body)).not.toContain('secret')
    spy.mockRestore()
  })
})
