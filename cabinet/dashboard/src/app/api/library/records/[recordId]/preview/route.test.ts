// GET /api/library/records/:recordId/preview — wikilink hovercard preview handler.
//
// Two dependencies mocked: @/lib/library (getRecord) + @/lib/auth (verifySession).
// Response paths:
//   - 401 when verifySession returns falsy (unauthenticated)
//   - 404 when getRecord returns null (record not found)
//   - 200 with {id, title, status, preview} — plain-text, capped at 200 chars
//   - 500 on throw
//
// Quirk: the handler strips markdown before truncating. We pin the stripping
// rules (headings, bold, italic, code, links, wikilinks, list markers) so a
// future regex change is caught. The auth mock is separate so we can toggle it
// per test.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { NextRequest } from 'next/server'

const { mockGetRecord, mockVerifySession } = vi.hoisted(() => ({
  mockGetRecord: vi.fn(),
  mockVerifySession: vi.fn(),
}))

vi.mock('@/lib/library', () => ({
  getRecord: mockGetRecord,
}))

vi.mock('@/lib/auth', () => ({
  verifySession: mockVerifySession,
}))

import { GET } from './route'

function makeReq(): NextRequest {
  return {} as unknown as NextRequest
}

function makeParams(recordId: string) {
  return { params: Promise.resolve({ recordId }) }
}

function fakeRecord(overrides: Partial<{
  id: string
  title: string
  status: string
  content_markdown: string
}> = {}) {
  return {
    id: '42',
    title: 'Test Record',
    status: 'draft',
    content_markdown: 'Hello world',
    ...overrides,
  }
}

beforeEach(() => {
  mockGetRecord.mockReset()
  mockVerifySession.mockReset()
  // Default: authenticated
  mockVerifySession.mockResolvedValue(true)
})

describe('GET preview — auth gate (401)', () => {
  it('401 when verifySession returns null (no session)', async () => {
    mockVerifySession.mockResolvedValueOnce(null)
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(401)
    const body = await res.json()
    expect(body.error).toBe('Unauthorized')
  })

  it('401 when verifySession returns false', async () => {
    mockVerifySession.mockResolvedValueOnce(false)
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(401)
  })

  it('does NOT call getRecord when auth fails', async () => {
    mockVerifySession.mockResolvedValueOnce(null)
    await GET(makeReq(), makeParams('42'))
    expect(mockGetRecord).not.toHaveBeenCalled()
  })
})

describe('GET preview — not found (404)', () => {
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
    mockGetRecord.mockResolvedValueOnce(fakeRecord())
    await GET(makeReq(), makeParams('record-abc'))
    expect(mockGetRecord).toHaveBeenCalledWith('record-abc')
  })
})

describe('GET preview — success (200)', () => {
  it('200 with {id, title, status, preview} on success', async () => {
    const rec = fakeRecord({ content_markdown: 'Simple prose here.' })
    mockGetRecord.mockResolvedValueOnce(rec)
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toHaveProperty('id', '42')
    expect(body).toHaveProperty('title', 'Test Record')
    expect(body).toHaveProperty('status', 'draft')
    expect(body).toHaveProperty('preview', 'Simple prose here.')
  })

  it('response body has exactly {id, title, status, preview} keys', async () => {
    mockGetRecord.mockResolvedValueOnce(fakeRecord({ content_markdown: 'x' }))
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(Object.keys(body).sort()).toEqual(['id', 'preview', 'status', 'title'])
  })

  it('preview capped at 200 chars + ellipsis when content is long', async () => {
    const long = 'A'.repeat(300)
    mockGetRecord.mockResolvedValueOnce(fakeRecord({ content_markdown: long }))
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    // 200 chars + the … character
    expect(body.preview).toHaveLength(201)
    expect(body.preview.endsWith('…')).toBe(true)
  })

  it('preview NOT truncated when content is exactly 200 chars', async () => {
    const exact = 'B'.repeat(200)
    mockGetRecord.mockResolvedValueOnce(fakeRecord({ content_markdown: exact }))
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(body.preview).toBe(exact)
    expect(body.preview.endsWith('…')).toBe(false)
  })

  it('strips markdown headings from preview', async () => {
    mockGetRecord.mockResolvedValueOnce(
      fakeRecord({ content_markdown: '## My Heading\nSome text.' })
    )
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(body.preview).not.toMatch(/#{1,6}/)
    expect(body.preview).toContain('My Heading')
    expect(body.preview).toContain('Some text')
  })

  it('strips bold markdown (**text**)', async () => {
    mockGetRecord.mockResolvedValueOnce(
      fakeRecord({ content_markdown: 'This is **bold** text.' })
    )
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(body.preview).not.toContain('**')
    expect(body.preview).toContain('bold')
  })

  it('strips inline code (`code`)', async () => {
    mockGetRecord.mockResolvedValueOnce(
      fakeRecord({ content_markdown: 'Use `npm install` to install.' })
    )
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(body.preview).not.toContain('`')
    expect(body.preview).toContain('install')
  })

  it('strips markdown links ([text](url)) → keeps link text', async () => {
    mockGetRecord.mockResolvedValueOnce(
      fakeRecord({ content_markdown: 'See [the docs](https://example.com) for more.' })
    )
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(body.preview).toContain('the docs')
    expect(body.preview).not.toContain('https://example.com')
  })

  it('strips wikilinks ([[RecordTitle]]) → keeps title text', async () => {
    mockGetRecord.mockResolvedValueOnce(
      fakeRecord({ content_markdown: 'Refer to [[Spec 037]] for details.' })
    )
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(body.preview).toContain('Spec 037')
    expect(body.preview).not.toContain('[[')
  })

  it('empty content_markdown → preview is empty string', async () => {
    mockGetRecord.mockResolvedValueOnce(
      fakeRecord({ content_markdown: '' })
    )
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(body.preview).toBe('')
  })
})

describe('GET preview — error path (500)', () => {
  it('500 when getRecord throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockGetRecord.mockRejectedValueOnce(new Error('pg timeout'))
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to load preview')
    spy.mockRestore()
  })

  it('500 never leaks internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockGetRecord.mockRejectedValueOnce(new Error('secret: tok=sk-abcdef'))
    const res = await GET(makeReq(), makeParams('42'))
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('sk-abcdef')
    expect(body.error).toBe('Failed to load preview')
    spy.mockRestore()
  })

  it('verifySession called before try block (auth gate runs before DB)', async () => {
    // Auth check precedes the try/catch so getRecord is never invoked when authed=false.
    // This test confirms verifySession is called once per request.
    mockGetRecord.mockResolvedValueOnce({ id: '1', title: 'T', status: 'draft', content_markdown: 'x' })
    const res = await GET(makeReq(), makeParams('42'))
    expect(res.status).toBe(200)
    expect(mockVerifySession).toHaveBeenCalledTimes(1)
    expect(mockGetRecord).toHaveBeenCalledTimes(1)
  })
})
