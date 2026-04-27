// GET /api/library/records/[recordId]/backlinks — wikilink backlink handler (Spec 045 Phase 1).
//
// Response paths:
//   - 400 when recordId is non-numeric (path-param injection guard)
//   - 200 with {backlinks: []} on empty corpus
//   - 200 with {backlinks: [...]} when source records exist
//   - 500 when the lib query throws
//
// Quirks:
//   - params is a Promise<{recordId}> per Next 15 async-params contract
//   - getBacklinks is shared with the MCP tool, so the route is a thin wrapper

import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { NextRequest } from 'next/server'

const { mockGetBacklinks } = vi.hoisted(() => ({
  mockGetBacklinks: vi.fn(),
}))

vi.mock('@/lib/wikilinks', () => ({
  getBacklinks: mockGetBacklinks,
}))

import { GET } from './route'

function makeReq(): NextRequest {
  return {} as unknown as NextRequest
}

function makeParams(recordId: string): { params: Promise<{ recordId: string }> } {
  return { params: Promise.resolve({ recordId }) }
}

beforeEach(() => {
  mockGetBacklinks.mockReset()
})

describe('GET /api/library/records/[recordId]/backlinks — recordId validation', () => {
  it('400 when recordId is alphabetic', async () => {
    const res = await GET(makeReq(), makeParams('abc'))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toBe('invalid recordId')
    expect(mockGetBacklinks).not.toHaveBeenCalled()
  })

  it('400 when recordId is empty', async () => {
    const res = await GET(makeReq(), makeParams(''))
    expect(res.status).toBe(400)
    expect(mockGetBacklinks).not.toHaveBeenCalled()
  })

  it('400 when recordId has trailing whitespace', async () => {
    const res = await GET(makeReq(), makeParams('123 '))
    expect(res.status).toBe(400)
    expect(mockGetBacklinks).not.toHaveBeenCalled()
  })

  it('400 when recordId has SQL-injection shape', async () => {
    const res = await GET(makeReq(), makeParams("1; DROP TABLE users;--"))
    expect(res.status).toBe(400)
    expect(mockGetBacklinks).not.toHaveBeenCalled()
  })

  it('400 when recordId is negative', async () => {
    const res = await GET(makeReq(), makeParams('-5'))
    expect(res.status).toBe(400)
    expect(mockGetBacklinks).not.toHaveBeenCalled()
  })
})

describe('GET /api/library/records/[recordId]/backlinks — happy path', () => {
  it('200 with empty backlinks array', async () => {
    mockGetBacklinks.mockResolvedValueOnce([])
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ backlinks: [] })
    expect(mockGetBacklinks).toHaveBeenCalledWith('42')
  })

  it('200 with populated backlinks', async () => {
    const backlinks = [
      {
        source_record_id: '7',
        source_title: 'Linking Record',
        source_space_id: '1',
        source_space_name: 'Briefs',
        link_text: 'Target',
        link_context: '…before [[Target]] after…',
        link_position: 0,
      },
    ]
    mockGetBacklinks.mockResolvedValueOnce(backlinks)
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.backlinks).toEqual(backlinks)
  })

  it('passes recordId verbatim to lib (no transformation)', async () => {
    mockGetBacklinks.mockResolvedValueOnce([])
    await GET(makeReq(), makeParams('999999999999'))
    expect(mockGetBacklinks).toHaveBeenCalledWith('999999999999')
  })
})

describe('GET /api/library/records/[recordId]/backlinks — error path', () => {
  it('500 when lib throws', async () => {
    mockGetBacklinks.mockRejectedValueOnce(new Error('db down'))
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('failed to load backlinks')
  })

  it('500 when lib throws non-Error value', async () => {
    mockGetBacklinks.mockRejectedValueOnce('string error')
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('failed to load backlinks')
  })
})
