// POST /api/library/search — library search handler.
//
// Response paths:
//   - 400 when query missing or empty/whitespace
//   - 200 with {results} on success
//   - 500 on throw
//
// Quirks: query is trimmed before searchRecords call; limit defaults to 10 (?? coalesce);
// space_id and labels pass through as-is (no transformation).

import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { NextRequest } from 'next/server'

const { mockSearchRecords } = vi.hoisted(() => ({
  mockSearchRecords: vi.fn(),
}))

vi.mock('@/lib/library', () => ({
  searchRecords: mockSearchRecords,
}))

import { POST } from './route'

function makeReq(body: unknown): NextRequest {
  return {
    json: async () => body,
  } as unknown as NextRequest
}

function makeBadJsonReq(): NextRequest {
  return {
    json: async () => {
      throw new SyntaxError('Unexpected token < in JSON')
    },
  } as unknown as NextRequest
}

beforeEach(() => {
  mockSearchRecords.mockReset()
})

describe('POST /api/library/search — body validation (400)', () => {
  it('400 when query is missing', async () => {
    const res = await POST(makeReq({ space_id: 'abc' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toBe('query is required')
  })

  it('400 when query is empty string', async () => {
    const res = await POST(makeReq({ query: '' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toBe('query is required')
    expect(mockSearchRecords).not.toHaveBeenCalled()
  })

  it('400 when query is whitespace only', async () => {
    const res = await POST(makeReq({ query: '   ' }))
    expect(res.status).toBe(400)
    expect(mockSearchRecords).not.toHaveBeenCalled()
  })

  it('400 when body is empty object (null query)', async () => {
    const res = await POST(makeReq({}))
    expect(res.status).toBe(400)
  })
})

describe('POST /api/library/search — query pass-through', () => {
  it('trims query before passing to searchRecords', async () => {
    mockSearchRecords.mockResolvedValueOnce([])
    await POST(makeReq({ query: '  spec 037  ' }))
    expect(mockSearchRecords).toHaveBeenCalledWith(
      expect.objectContaining({ query: 'spec 037' })
    )
  })

  it('limit defaults to 10 when absent (?? coalesce)', async () => {
    mockSearchRecords.mockResolvedValueOnce([])
    await POST(makeReq({ query: 'test' }))
    expect(mockSearchRecords).toHaveBeenCalledWith(
      expect.objectContaining({ limit: 10 })
    )
  })

  it('passes explicit limit through', async () => {
    mockSearchRecords.mockResolvedValueOnce([])
    await POST(makeReq({ query: 'test', limit: 25 }))
    expect(mockSearchRecords).toHaveBeenCalledWith(
      expect.objectContaining({ limit: 25 })
    )
  })

  it('passes space_id through when provided', async () => {
    mockSearchRecords.mockResolvedValueOnce([])
    await POST(makeReq({ query: 'test', space_id: 'space-abc' }))
    expect(mockSearchRecords).toHaveBeenCalledWith(
      expect.objectContaining({ space_id: 'space-abc' })
    )
  })

  it('space_id undefined when not provided', async () => {
    mockSearchRecords.mockResolvedValueOnce([])
    await POST(makeReq({ query: 'test' }))
    expect(mockSearchRecords).toHaveBeenCalledWith(
      expect.objectContaining({ space_id: undefined })
    )
  })

  it('passes labels array through', async () => {
    mockSearchRecords.mockResolvedValueOnce([])
    await POST(makeReq({ query: 'test', labels: ['spec', 'research'] }))
    expect(mockSearchRecords).toHaveBeenCalledWith(
      expect.objectContaining({ labels: ['spec', 'research'] })
    )
  })

  it('labels undefined when not provided', async () => {
    mockSearchRecords.mockResolvedValueOnce([])
    await POST(makeReq({ query: 'test' }))
    expect(mockSearchRecords).toHaveBeenCalledWith(
      expect.objectContaining({ labels: undefined })
    )
  })

  it('full arg object matches expected shape', async () => {
    mockSearchRecords.mockResolvedValueOnce([])
    await POST(makeReq({ query: '  find me  ', space_id: 's1', labels: ['a'], limit: 5 }))
    expect(mockSearchRecords).toHaveBeenCalledWith({
      query: 'find me',
      space_id: 's1',
      labels: ['a'],
      limit: 5,
    })
  })
})

describe('POST /api/library/search — success (200)', () => {
  it('200 with {results} on success', async () => {
    const rows = [
      { id: '1', title: 'Spec 037', score: 0.9 },
      { id: '2', title: 'Spec 038', score: 0.8 },
    ]
    mockSearchRecords.mockResolvedValueOnce(rows)
    const res = await POST(makeReq({ query: 'spec' }))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ results: rows })
  })

  it('200 with empty results array', async () => {
    mockSearchRecords.mockResolvedValueOnce([])
    const res = await POST(makeReq({ query: 'zzznonexistent' }))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ results: [] })
  })
})

describe('POST /api/library/search — error paths (500)', () => {
  it('500 when searchRecords throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockSearchRecords.mockRejectedValueOnce(new Error('pgvector error'))
    const res = await POST(makeReq({ query: 'test' }))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Search failed')
    spy.mockRestore()
  })

  it('500 when req.json() throws (malformed body)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const res = await POST(makeBadJsonReq())
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Search failed')
    spy.mockRestore()
  })

  it('500 never leaks internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockSearchRecords.mockRejectedValueOnce(new Error('secret: db=pg://u:pw@host/db'))
    const res = await POST(makeReq({ query: 'test' }))
    const body = await res.json()
    expect(body.error).toBe('Search failed')
    expect(JSON.stringify(body)).not.toContain('pw@host')
    spy.mockRestore()
  })
})
