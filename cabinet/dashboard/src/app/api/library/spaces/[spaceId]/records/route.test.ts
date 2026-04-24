// GET + POST /api/library/spaces/:spaceId/records — space records list + create.
//
// Two verbs, each with response paths:
//   GET
//     - 200 with {records} on success
//     - labels parsed from ?labels=a,b,c (comma-split, trim, filter empty)
//     - limit defaults to 50, offset defaults to 0 (Number() coerce)
//     - 500 on throw
//   POST
//     - 400 when title missing/empty/whitespace
//     - 201 with {record} on success
//     - title trimmed; content_markdown/schema_data/labels/created_by_officer pass-through
//     - spaceId from params injected as space_id
//     - 500 on throw
//
// Quirk: GET uses req.nextUrl.searchParams (not new URL(req.url)).
// The mock must supply `nextUrl: { searchParams: new URLSearchParams(...) }`.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { NextRequest } from 'next/server'

const { mockListRecords, mockCreateRecord } = vi.hoisted(() => ({
  mockListRecords: vi.fn(),
  mockCreateRecord: vi.fn(),
}))

vi.mock('@/lib/library', () => ({
  listRecords: mockListRecords,
  createRecord: mockCreateRecord,
}))

import { GET, POST } from './route'

function makeGetReq(queryString = ''): NextRequest {
  return {
    nextUrl: {
      searchParams: new URLSearchParams(queryString),
    },
  } as unknown as NextRequest
}

function makePostReq(body: unknown): NextRequest {
  return {
    nextUrl: { searchParams: new URLSearchParams() },
    json: async () => body,
  } as unknown as NextRequest
}

function makeBadJsonReq(): NextRequest {
  return {
    nextUrl: { searchParams: new URLSearchParams() },
    json: async () => {
      throw new SyntaxError('Unexpected token < in JSON')
    },
  } as unknown as NextRequest
}

function makeParams(spaceId: string) {
  return { params: Promise.resolve({ spaceId }) }
}

beforeEach(() => {
  mockListRecords.mockReset()
  mockCreateRecord.mockReset()
})

describe('GET /api/library/spaces/:spaceId/records — success (200)', () => {
  it('200 with {records} array on success', async () => {
    const records = [
      { id: 'r1', title: 'Spec A', space_id: 'sp1' },
      { id: 'r2', title: 'Spec B', space_id: 'sp1' },
    ]
    mockListRecords.mockResolvedValueOnce(records)
    const res = await GET(makeGetReq(), makeParams('sp1'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ records })
  })

  it('200 with empty {records: []}', async () => {
    mockListRecords.mockResolvedValueOnce([])
    const res = await GET(makeGetReq(), makeParams('sp1'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ records: [] })
  })

  it('passes spaceId through as first arg to listRecords', async () => {
    mockListRecords.mockResolvedValueOnce([])
    await GET(makeGetReq(), makeParams('space-abc'))
    expect(mockListRecords).toHaveBeenCalledWith('space-abc', expect.any(Object))
  })
})

describe('GET /api/library/spaces/:spaceId/records — query params', () => {
  it('defaults limit to 50 when absent', async () => {
    mockListRecords.mockResolvedValueOnce([])
    await GET(makeGetReq(), makeParams('sp1'))
    expect(mockListRecords).toHaveBeenCalledWith(
      'sp1',
      expect.objectContaining({ limit: 50 })
    )
  })

  it('defaults offset to 0 when absent', async () => {
    mockListRecords.mockResolvedValueOnce([])
    await GET(makeGetReq(), makeParams('sp1'))
    expect(mockListRecords).toHaveBeenCalledWith(
      'sp1',
      expect.objectContaining({ offset: 0 })
    )
  })

  it('passes explicit limit and offset through', async () => {
    mockListRecords.mockResolvedValueOnce([])
    await GET(makeGetReq('limit=25&offset=50'), makeParams('sp1'))
    expect(mockListRecords).toHaveBeenCalledWith(
      'sp1',
      expect.objectContaining({ limit: 25, offset: 50 })
    )
  })

  it('parses labels from ?labels=a,b,c (comma-split)', async () => {
    mockListRecords.mockResolvedValueOnce([])
    await GET(makeGetReq('labels=spec,research,draft'), makeParams('sp1'))
    expect(mockListRecords).toHaveBeenCalledWith(
      'sp1',
      expect.objectContaining({ labels: ['spec', 'research', 'draft'] })
    )
  })

  it('trims whitespace from each label', async () => {
    mockListRecords.mockResolvedValueOnce([])
    await GET(makeGetReq('labels=spec+1, research , draft'), makeParams('sp1'))
    const [, opts] = mockListRecords.mock.calls[0]
    expect(opts.labels?.every((l: string) => l === l.trim())).toBe(true)
  })

  it('filters empty labels after split (e.g. trailing comma)', async () => {
    mockListRecords.mockResolvedValueOnce([])
    await GET(makeGetReq('labels=spec,,draft,'), makeParams('sp1'))
    const [, opts] = mockListRecords.mock.calls[0]
    expect(opts.labels).not.toContain('')
    expect(opts.labels).toEqual(['spec', 'draft'])
  })

  it('labels undefined when ?labels param absent', async () => {
    mockListRecords.mockResolvedValueOnce([])
    await GET(makeGetReq(), makeParams('sp1'))
    const [, opts] = mockListRecords.mock.calls[0]
    expect(opts.labels).toBeUndefined()
  })

  it('single label becomes a one-element array', async () => {
    mockListRecords.mockResolvedValueOnce([])
    await GET(makeGetReq('labels=research'), makeParams('sp1'))
    const [, opts] = mockListRecords.mock.calls[0]
    expect(opts.labels).toEqual(['research'])
  })
})

describe('GET /api/library/spaces/:spaceId/records — error path (500)', () => {
  it('500 when listRecords throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockListRecords.mockRejectedValueOnce(new Error('pg down'))
    const res = await GET(makeGetReq(), makeParams('sp1'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to list records')
    spy.mockRestore()
  })

  it('500 never leaks internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockListRecords.mockRejectedValueOnce(new Error('secret: key=abc123'))
    const res = await GET(makeGetReq(), makeParams('sp1'))
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('abc123')
    spy.mockRestore()
  })
})

describe('POST /api/library/spaces/:spaceId/records — body validation (400)', () => {
  it('400 when title is missing', async () => {
    const res = await POST(makePostReq({ content_markdown: 'x' }), makeParams('sp1'))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toBe('title is required')
  })

  it('400 when title is empty string', async () => {
    const res = await POST(makePostReq({ title: '' }), makeParams('sp1'))
    expect(res.status).toBe(400)
    expect(mockCreateRecord).not.toHaveBeenCalled()
  })

  it('400 when title is whitespace only', async () => {
    const res = await POST(makePostReq({ title: '   ' }), makeParams('sp1'))
    expect(res.status).toBe(400)
    expect(mockCreateRecord).not.toHaveBeenCalled()
  })
})

describe('POST /api/library/spaces/:spaceId/records — pass-through', () => {
  it('title trimmed before createRecord', async () => {
    mockCreateRecord.mockResolvedValueOnce({ id: 'r1' })
    await POST(makePostReq({ title: '  My Record  ' }), makeParams('sp1'))
    expect(mockCreateRecord).toHaveBeenCalledWith(
      expect.objectContaining({ title: 'My Record' })
    )
  })

  it('space_id injected from params (not body)', async () => {
    mockCreateRecord.mockResolvedValueOnce({ id: 'r1' })
    await POST(makePostReq({ title: 'T' }), makeParams('space-xyz'))
    expect(mockCreateRecord).toHaveBeenCalledWith(
      expect.objectContaining({ space_id: 'space-xyz' })
    )
  })

  it('content_markdown pass-through', async () => {
    mockCreateRecord.mockResolvedValueOnce({ id: 'r1' })
    await POST(makePostReq({ title: 'T', content_markdown: '# Hello\n\nWorld.' }), makeParams('sp1'))
    expect(mockCreateRecord).toHaveBeenCalledWith(
      expect.objectContaining({ content_markdown: '# Hello\n\nWorld.' })
    )
  })

  it('schema_data pass-through', async () => {
    const schema = { priority: 1, tags: ['urgent'] }
    mockCreateRecord.mockResolvedValueOnce({ id: 'r1' })
    await POST(makePostReq({ title: 'T', schema_data: schema }), makeParams('sp1'))
    expect(mockCreateRecord).toHaveBeenCalledWith(
      expect.objectContaining({ schema_data: schema })
    )
  })

  it('labels pass-through', async () => {
    mockCreateRecord.mockResolvedValueOnce({ id: 'r1' })
    await POST(makePostReq({ title: 'T', labels: ['spec', 'v1'] }), makeParams('sp1'))
    expect(mockCreateRecord).toHaveBeenCalledWith(
      expect.objectContaining({ labels: ['spec', 'v1'] })
    )
  })

  it('created_by_officer pass-through', async () => {
    mockCreateRecord.mockResolvedValueOnce({ id: 'r1' })
    await POST(makePostReq({ title: 'T', created_by_officer: 'cto' }), makeParams('sp1'))
    expect(mockCreateRecord).toHaveBeenCalledWith(
      expect.objectContaining({ created_by_officer: 'cto' })
    )
  })

  it('optional fields undefined when absent', async () => {
    mockCreateRecord.mockResolvedValueOnce({ id: 'r1' })
    await POST(makePostReq({ title: 'T' }), makeParams('sp1'))
    expect(mockCreateRecord).toHaveBeenCalledWith({
      space_id: 'sp1',
      title: 'T',
      content_markdown: undefined,
      schema_data: undefined,
      labels: undefined,
      created_by_officer: undefined,
    })
  })
})

describe('POST /api/library/spaces/:spaceId/records — success (201)', () => {
  it('201 with {record} on success', async () => {
    const record = { id: 'r1', title: 'My Record', space_id: 'sp1', status: 'draft' }
    mockCreateRecord.mockResolvedValueOnce(record)
    const res = await POST(makePostReq({ title: 'My Record' }), makeParams('sp1'))
    expect(res.status).toBe(201)
    const body = await res.json()
    expect(body).toEqual({ record })
  })
})

describe('POST /api/library/spaces/:spaceId/records — error paths (500)', () => {
  it('500 when createRecord throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockCreateRecord.mockRejectedValueOnce(new Error('fk violation: space not found'))
    const res = await POST(makePostReq({ title: 'T' }), makeParams('sp1'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to create record')
    spy.mockRestore()
  })

  it('500 when req.json() throws (malformed body)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const res = await POST(makeBadJsonReq(), makeParams('sp1'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to create record')
    spy.mockRestore()
  })

  it('500 never leaks internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockCreateRecord.mockRejectedValueOnce(new Error('secret: conn=pg://u:pw@host'))
    const res = await POST(makePostReq({ title: 'T' }), makeParams('sp1'))
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('pw@host')
    spy.mockRestore()
  })
})
