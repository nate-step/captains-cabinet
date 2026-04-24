// GET /api/library/records/typeahead — wikilink autocomplete handler.
//
// Spec 037 A1. Title-prefix ILIKE match via typeaheadRecords (@/lib/wikilinks).
// Tiny 31-LOC handler but has three behavioral invariants worth pinning:
//   - short-circuit on empty/whitespace `q` (no DB hit)
//   - `q` trimmed before passing to lib
//   - `limit` clamped at 20, defaulted to 10, parseInt normalization

import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { NextRequest } from 'next/server'

const { mockTypeahead } = vi.hoisted(() => ({ mockTypeahead: vi.fn() }))

vi.mock('@/lib/wikilinks', () => ({
  typeaheadRecords: mockTypeahead,
}))

import { GET } from './route'

function makeReq(url: string): NextRequest {
  return { url } as unknown as NextRequest
}

beforeEach(() => {
  mockTypeahead.mockReset()
})

describe('GET typeahead — empty query short-circuit', () => {
  it('empty q returns {results: []} without calling typeaheadRecords', async () => {
    const res = await GET(makeReq('http://localhost/api/library/records/typeahead?q='))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ results: [] })
    expect(mockTypeahead).not.toHaveBeenCalled()
  })

  it('missing q returns {results: []} (?? "" coalesce)', async () => {
    const res = await GET(makeReq('http://localhost/api/library/records/typeahead'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ results: [] })
    expect(mockTypeahead).not.toHaveBeenCalled()
  })

  it('whitespace-only q returns {results: []} (trim check)', async () => {
    const res = await GET(
      makeReq('http://localhost/api/library/records/typeahead?q=%20%20%20')
    )
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ results: [] })
    expect(mockTypeahead).not.toHaveBeenCalled()
  })
})

describe('GET typeahead — query pass-through', () => {
  it('trims q before passing to typeaheadRecords', async () => {
    mockTypeahead.mockResolvedValueOnce([])
    await GET(
      makeReq('http://localhost/api/library/records/typeahead?q=%20%20spec%20%20')
    )
    expect(mockTypeahead).toHaveBeenCalledWith('spec', expect.any(Object))
  })

  it('passes spaceId when provided', async () => {
    mockTypeahead.mockResolvedValueOnce([])
    await GET(
      makeReq(
        'http://localhost/api/library/records/typeahead?q=test&spaceId=space-42'
      )
    )
    expect(mockTypeahead).toHaveBeenCalledWith('test', {
      spaceId: 'space-42',
      limit: 10,
    })
  })

  it('spaceId undefined when absent', async () => {
    mockTypeahead.mockResolvedValueOnce([])
    await GET(makeReq('http://localhost/api/library/records/typeahead?q=test'))
    expect(mockTypeahead).toHaveBeenCalledWith('test', {
      spaceId: undefined,
      limit: 10,
    })
  })
})

describe('GET typeahead — limit parsing', () => {
  it('defaults limit to 10 when absent', async () => {
    mockTypeahead.mockResolvedValueOnce([])
    await GET(makeReq('http://localhost/api/library/records/typeahead?q=x'))
    const [, opts] = mockTypeahead.mock.calls[0]
    expect(opts.limit).toBe(10)
  })

  it('respects limit when under the cap', async () => {
    mockTypeahead.mockResolvedValueOnce([])
    await GET(makeReq('http://localhost/api/library/records/typeahead?q=x&limit=5'))
    const [, opts] = mockTypeahead.mock.calls[0]
    expect(opts.limit).toBe(5)
  })

  it('caps limit at 20 (Math.min)', async () => {
    mockTypeahead.mockResolvedValueOnce([])
    await GET(makeReq('http://localhost/api/library/records/typeahead?q=x&limit=100'))
    const [, opts] = mockTypeahead.mock.calls[0]
    expect(opts.limit).toBe(20)
  })

  it('limit=20 exactly (boundary)', async () => {
    mockTypeahead.mockResolvedValueOnce([])
    await GET(makeReq('http://localhost/api/library/records/typeahead?q=x&limit=20'))
    const [, opts] = mockTypeahead.mock.calls[0]
    expect(opts.limit).toBe(20)
  })

  it('limit=1 (min boundary — no floor check, just Math.min)', async () => {
    mockTypeahead.mockResolvedValueOnce([])
    await GET(makeReq('http://localhost/api/library/records/typeahead?q=x&limit=1'))
    const [, opts] = mockTypeahead.mock.calls[0]
    expect(opts.limit).toBe(1)
  })

  it('non-numeric limit becomes NaN → Math.min(NaN, 20) = NaN', async () => {
    // Pin handler behavior: parseInt('abc') returns NaN, Math.min(NaN, 20) = NaN.
    // This isn't great but it's the current contract — if we ever add a floor
    // check this test will need to update, signaling the contract shift.
    mockTypeahead.mockResolvedValueOnce([])
    await GET(makeReq('http://localhost/api/library/records/typeahead?q=x&limit=abc'))
    const [, opts] = mockTypeahead.mock.calls[0]
    expect(opts.limit).toBeNaN()
  })
})

describe('GET typeahead — response shape', () => {
  it('200 with {results} wrapped', async () => {
    const rows = [
      { id: '1', title: 'Spec 037', space_id: 'a' },
      { id: '2', title: 'Spec 038', space_id: 'a' },
    ]
    mockTypeahead.mockResolvedValueOnce(rows)
    const res = await GET(
      makeReq('http://localhost/api/library/records/typeahead?q=Spec')
    )
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ results: rows })
  })

  it('empty result array still 200 {results: []}', async () => {
    mockTypeahead.mockResolvedValueOnce([])
    const res = await GET(
      makeReq('http://localhost/api/library/records/typeahead?q=zzz')
    )
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ results: [] })
  })
})

describe('GET typeahead — error path (500)', () => {
  it('500 when typeaheadRecords throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockTypeahead.mockRejectedValueOnce(new Error('pg timeout'))
    const res = await GET(
      makeReq('http://localhost/api/library/records/typeahead?q=x')
    )
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Typeahead failed')
    spy.mockRestore()
  })

  it('500 never leaks internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockTypeahead.mockRejectedValueOnce(new Error('secret: conn=pg://u:p@h'))
    const res = await GET(
      makeReq('http://localhost/api/library/records/typeahead?q=x')
    )
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('p@h')
    expect(body.error).toBe('Typeahead failed')
    spy.mockRestore()
  })
})
