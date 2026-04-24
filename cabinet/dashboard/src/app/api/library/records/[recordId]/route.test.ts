// GET / PATCH / DELETE /api/library/records/:recordId — record CRUD handler.
//
// Companion to the status-PATCH harness (sibling route). Same mock pattern:
// stub @/lib/library, feed params as Promise<{ recordId }> per Next.js 15
// async-params. No DB / pg-pool setup required.
//
// Coverage (all 10 response paths):
//   GET
//     - 200 with {record} body
//     - 404 when getRecord returns null
//     - 404 when getRecord returns undefined
//     - 500 on throw
//     - recordId pass-through
//   PATCH
//     - 400 missing / empty / whitespace title
//     - title trimmed before hitting updateRecord
//     - content_markdown defaults to '' when absent (??  coalesce)
//     - content_markdown + schema_data + labels pass-through
//     - 200 with {record}
//     - 404 when error message includes 'not found'
//     - 500 on generic throw
//     - 500 on body-parse throw (malformed JSON)
//     - recordId pass-through
//   DELETE
//     - 200 {ok: true} on success
//     - 404 when deleteRecord returns false
//     - 404 when deleteRecord returns null/undefined (truthy check)
//     - 500 on throw
//     - recordId pass-through

import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { NextRequest } from 'next/server'

const { mockGetRecord, mockUpdateRecord, mockDeleteRecord } = vi.hoisted(() => ({
  mockGetRecord: vi.fn(),
  mockUpdateRecord: vi.fn(),
  mockDeleteRecord: vi.fn(),
}))

vi.mock('@/lib/library', () => ({
  getRecord: mockGetRecord,
  updateRecord: mockUpdateRecord,
  deleteRecord: mockDeleteRecord,
}))

import { GET, PATCH, DELETE } from './route'

function makeReq(body?: unknown): NextRequest {
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

function makeParams(recordId: string) {
  return { params: Promise.resolve({ recordId }) }
}

beforeEach(() => {
  mockGetRecord.mockReset()
  mockUpdateRecord.mockReset()
  mockDeleteRecord.mockReset()
})

describe('GET /api/library/records/:recordId', () => {
  it('200 with {record} on success', async () => {
    const rec = { id: '42', title: 'T' }
    mockGetRecord.mockResolvedValueOnce(rec)
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ record: rec })
  })

  it('404 when getRecord returns null', async () => {
    mockGetRecord.mockResolvedValueOnce(null)
    const res = await GET(makeReq(), makeParams('9999'))
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body.error).toBe('Record not found')
  })

  it('404 when getRecord returns undefined', async () => {
    mockGetRecord.mockResolvedValueOnce(undefined)
    const res = await GET(makeReq(), makeParams('9999'))
    expect(res.status).toBe(404)
  })

  it('passes recordId through to getRecord', async () => {
    mockGetRecord.mockResolvedValueOnce({ id: 'x' })
    await GET(makeReq(), makeParams('abc-123'))
    expect(mockGetRecord).toHaveBeenCalledWith('abc-123')
  })

  it('500 when getRecord throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockGetRecord.mockRejectedValueOnce(new Error('pg down'))
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to get record')
    spy.mockRestore()
  })

  it('500 does not leak internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockGetRecord.mockRejectedValueOnce(new Error('secret: key=abc123'))
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('abc123')
    spy.mockRestore()
  })
})

describe('PATCH /api/library/records/:recordId — body validation (400)', () => {
  it('400 when title missing', async () => {
    const res = await PATCH(makeReq({ content_markdown: 'x' }), makeParams('42'))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toBe('title is required')
  })

  it('400 when title is empty string', async () => {
    const res = await PATCH(
      makeReq({ title: '', content_markdown: 'x' }),
      makeParams('42')
    )
    expect(res.status).toBe(400)
  })

  it('400 when title is whitespace only', async () => {
    const res = await PATCH(
      makeReq({ title: '   ', content_markdown: 'x' }),
      makeParams('42')
    )
    expect(res.status).toBe(400)
    expect(mockUpdateRecord).not.toHaveBeenCalled()
  })
})

describe('PATCH /api/library/records/:recordId — pass-through', () => {
  it('title is trimmed before updateRecord call', async () => {
    mockUpdateRecord.mockResolvedValueOnce({ id: '42', title: 'Hello' })
    await PATCH(
      makeReq({ title: '  Hello  ', content_markdown: 'x' }),
      makeParams('42')
    )
    const [, updates] = mockUpdateRecord.mock.calls[0]
    expect(updates.title).toBe('Hello')
  })

  it('content_markdown defaults to "" when absent (?? coalesce)', async () => {
    mockUpdateRecord.mockResolvedValueOnce({ id: '42' })
    await PATCH(makeReq({ title: 'T' }), makeParams('42'))
    const [, updates] = mockUpdateRecord.mock.calls[0]
    expect(updates.content_markdown).toBe('')
  })

  it('content_markdown preserved when explicit empty string', async () => {
    mockUpdateRecord.mockResolvedValueOnce({ id: '42' })
    await PATCH(
      makeReq({ title: 'T', content_markdown: '' }),
      makeParams('42')
    )
    const [, updates] = mockUpdateRecord.mock.calls[0]
    expect(updates.content_markdown).toBe('')
  })

  it('content_markdown preserved when null (?? falls through to default)', async () => {
    mockUpdateRecord.mockResolvedValueOnce({ id: '42' })
    await PATCH(
      makeReq({ title: 'T', content_markdown: null }),
      makeParams('42')
    )
    const [, updates] = mockUpdateRecord.mock.calls[0]
    // ?? treats null as unset — expect '' default
    expect(updates.content_markdown).toBe('')
  })

  it('schema_data pass-through', async () => {
    mockUpdateRecord.mockResolvedValueOnce({ id: '42' })
    await PATCH(
      makeReq({
        title: 'T',
        content_markdown: 'x',
        schema_data: { key: 'val', nested: { x: 1 } },
      }),
      makeParams('42')
    )
    const [, updates] = mockUpdateRecord.mock.calls[0]
    expect(updates.schema_data).toEqual({ key: 'val', nested: { x: 1 } })
  })

  it('labels pass-through', async () => {
    mockUpdateRecord.mockResolvedValueOnce({ id: '42' })
    await PATCH(
      makeReq({ title: 'T', content_markdown: 'x', labels: ['a', 'b'] }),
      makeParams('42')
    )
    const [, updates] = mockUpdateRecord.mock.calls[0]
    expect(updates.labels).toEqual(['a', 'b'])
  })

  it('schema_data + labels undefined when not provided', async () => {
    mockUpdateRecord.mockResolvedValueOnce({ id: '42' })
    await PATCH(
      makeReq({ title: 'T', content_markdown: 'x' }),
      makeParams('42')
    )
    const [, updates] = mockUpdateRecord.mock.calls[0]
    expect(updates.schema_data).toBeUndefined()
    expect(updates.labels).toBeUndefined()
  })

  it('passes recordId as first arg to updateRecord', async () => {
    mockUpdateRecord.mockResolvedValueOnce({ id: '12345' })
    await PATCH(
      makeReq({ title: 'T', content_markdown: 'x' }),
      makeParams('12345')
    )
    expect(mockUpdateRecord).toHaveBeenCalledWith('12345', expect.any(Object))
  })
})

describe('PATCH /api/library/records/:recordId — success + error paths', () => {
  it('200 with {record} on success', async () => {
    const updated = { id: '42', title: 'New Title' }
    mockUpdateRecord.mockResolvedValueOnce(updated)
    const res = await PATCH(
      makeReq({ title: 'New Title', content_markdown: 'x' }),
      makeParams('42')
    )
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ record: updated })
  })

  it('404 when error message includes "not found"', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockUpdateRecord.mockRejectedValueOnce(new Error('Record 42 not found in space'))
    const res = await PATCH(
      makeReq({ title: 'T', content_markdown: 'x' }),
      makeParams('42')
    )
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body.error).toContain('not found')
    spy.mockRestore()
  })

  it('500 on generic error (no "not found" match)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockUpdateRecord.mockRejectedValueOnce(new Error('pg deadlock'))
    const res = await PATCH(
      makeReq({ title: 'T', content_markdown: 'x' }),
      makeParams('42')
    )
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to update record')
    spy.mockRestore()
  })

  it('500 on non-Error throw', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockUpdateRecord.mockRejectedValueOnce('string thrown')
    const res = await PATCH(
      makeReq({ title: 'T', content_markdown: 'x' }),
      makeParams('42')
    )
    expect(res.status).toBe(500)
    spy.mockRestore()
  })

  it('500 when req.json() throws (malformed body)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const res = await PATCH(makeBadJsonReq(), makeParams('42'))
    expect(res.status).toBe(500)
    spy.mockRestore()
  })

  it('500 never leaks internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockUpdateRecord.mockRejectedValueOnce(new Error('secret token=sk-xxx'))
    const res = await PATCH(
      makeReq({ title: 'T', content_markdown: 'x' }),
      makeParams('42')
    )
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('sk-xxx')
    spy.mockRestore()
  })
})

describe('DELETE /api/library/records/:recordId', () => {
  it('200 with {ok: true} on success', async () => {
    mockDeleteRecord.mockResolvedValueOnce(true)
    const res = await DELETE(makeReq(), makeParams('42'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ ok: true })
  })

  it('404 when deleteRecord returns false', async () => {
    mockDeleteRecord.mockResolvedValueOnce(false)
    const res = await DELETE(makeReq(), makeParams('9999'))
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body.error).toBe('Record not found or already deleted')
  })

  it('404 when deleteRecord returns null (falsy)', async () => {
    mockDeleteRecord.mockResolvedValueOnce(null)
    const res = await DELETE(makeReq(), makeParams('9999'))
    expect(res.status).toBe(404)
  })

  it('404 when deleteRecord returns undefined (falsy)', async () => {
    mockDeleteRecord.mockResolvedValueOnce(undefined)
    const res = await DELETE(makeReq(), makeParams('9999'))
    expect(res.status).toBe(404)
  })

  it('passes recordId through to deleteRecord', async () => {
    mockDeleteRecord.mockResolvedValueOnce(true)
    await DELETE(makeReq(), makeParams('record-to-del'))
    expect(mockDeleteRecord).toHaveBeenCalledWith('record-to-del')
  })

  it('500 when deleteRecord throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockDeleteRecord.mockRejectedValueOnce(new Error('fk_constraint'))
    const res = await DELETE(makeReq(), makeParams('42'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to delete record')
    spy.mockRestore()
  })

  it('500 does not leak internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockDeleteRecord.mockRejectedValueOnce(new Error('constraint violation: pw=hunter2'))
    const res = await DELETE(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('hunter2')
    spy.mockRestore()
  })
})
