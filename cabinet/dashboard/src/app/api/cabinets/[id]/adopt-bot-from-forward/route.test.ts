// Spec 034 PR 3 — POST /api/cabinets/[id]/adopt-bot-from-forward handler harness
//
// Scope: read-only extraction endpoint — guard, body validation, raw_text length
//   boundary, extractTokenFromForward delegation, and response shape.
//
// Mock strategy: vi.hoisted for guard + extractTokenFromForward. No DB or Redis
//   (this handler is fully stateless — no mutations).
//
// Notable invariants pinned:
//   - raw_text=4096 passes; raw_text=4097 fails (exact boundary)
//   - raw_text passed to extractTokenFromForward unchanged (no trim/mutation)
//   - Response always includes full token (intentional per spec §3 — client needs it)
//   - confirmation_message shape: "Got token ending ...{lastFour} — adopt{label}?"
//   - officer label: ` as "{officer}"` suffix when officer present, empty otherwise
//   - guard short-circuit fires BEFORE body parse (pool.connect never called)

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

const { mockGuard, mockExtract } = vi.hoisted(() => ({
  mockGuard: vi.fn(),
  mockExtract: vi.fn(),
}))

vi.mock('@/lib/provisioning/guard', () => ({
  requireProvisioningAccess: mockGuard,
}))

vi.mock('@/lib/botfather', () => ({
  extractTokenFromForward: mockExtract,
}))

import { POST } from './route'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeReq(body: unknown, throwOnJson = false): NextRequest {
  return {
    json: throwOnJson
      ? async () => { throw new SyntaxError('Unexpected token') }
      : async () => body,
  } as unknown as NextRequest
}

function makeParams(id = 'cab_abc') {
  return { params: Promise.resolve({ id }) }
}

const MOCK_EXTRACT_RESULT = { token: '12345678:ABCDEFabcdef_-12345678901234567', lastFour: '4567' }

beforeEach(() => {
  mockGuard.mockReset()
  mockExtract.mockReset()
  mockGuard.mockResolvedValue({ response: null, user: { token: 'tok_captain' } })
  mockExtract.mockReturnValue(MOCK_EXTRACT_RESULT)
})

// ---------------------------------------------------------------------------
// Guard short-circuit
// ---------------------------------------------------------------------------

describe('POST adopt-bot-from-forward — guard short-circuit', () => {
  it('returns guard.response when guard fires (503 feature-flag)', async () => {
    const resp = NextResponse.json({ ok: false, disabled: true }, { status: 503 })
    mockGuard.mockResolvedValueOnce({ response: resp, user: null })
    const res = await POST(makeReq({ raw_text: 'anything' }), makeParams())
    expect(res.status).toBe(503)
    expect(mockExtract).not.toHaveBeenCalled()
  })

  it('returns guard.response when auth guard fires (401)', async () => {
    const resp = NextResponse.json({ ok: false, message: 'Unauthorized' }, { status: 401 })
    mockGuard.mockResolvedValueOnce({ response: resp, user: null })
    const res = await POST(makeReq({ raw_text: 'anything' }), makeParams())
    expect(res.status).toBe(401)
    expect(mockExtract).not.toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// Body validation (400)
// ---------------------------------------------------------------------------

describe('POST adopt-bot-from-forward — body validation (400)', () => {
  it('400 when req.json() throws (malformed JSON)', async () => {
    const res = await POST(makeReq(null, true), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Invalid JSON body' })
    expect(mockExtract).not.toHaveBeenCalled()
  })

  it('400 when raw_text is missing', async () => {
    const res = await POST(makeReq({}), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('raw_text is required')
  })

  it('400 when raw_text is null', async () => {
    const res = await POST(makeReq({ raw_text: null }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('raw_text is required')
  })

  it('400 when raw_text is a number (not a string)', async () => {
    const res = await POST(makeReq({ raw_text: 12345 }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('raw_text is required')
  })

  it('400 when raw_text is exactly 4097 characters (over limit)', async () => {
    const res = await POST(makeReq({ raw_text: 'x'.repeat(4097) }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('raw_text exceeds maximum length of 4096 characters')
  })

  it('boundary: raw_text exactly 4096 characters passes length check', async () => {
    const res = await POST(makeReq({ raw_text: 'x'.repeat(4096) }), makeParams())
    // extractTokenFromForward returns MOCK_EXTRACT_RESULT → should be 200
    expect(res.status).toBe(200)
  })
})

// ---------------------------------------------------------------------------
// 422 — no token found
// ---------------------------------------------------------------------------

describe('POST adopt-bot-from-forward — 422 (no token found)', () => {
  it('returns 422 when extractTokenFromForward returns null', async () => {
    mockExtract.mockReturnValueOnce(null)
    const res = await POST(makeReq({ raw_text: 'hello world no token here' }), makeParams())
    expect(res.status).toBe(422)
    const body = await res.json()
    expect(body.ok).toBe(false)
    expect(body.message).toContain('No valid bot token found')
  })
})

// ---------------------------------------------------------------------------
// extractTokenFromForward delegation
// ---------------------------------------------------------------------------

describe('POST adopt-bot-from-forward — extractTokenFromForward call contract', () => {
  it('called with exactly raw_text from body (no trim/mutation)', async () => {
    const rawText = '  raw with spaces  '
    await POST(makeReq({ raw_text: rawText }), makeParams())
    expect(mockExtract).toHaveBeenCalledWith(rawText)
    expect(mockExtract).toHaveBeenCalledTimes(1)
  })
})

// ---------------------------------------------------------------------------
// Happy path — no officer
// ---------------------------------------------------------------------------

describe('POST adopt-bot-from-forward — happy path without officer', () => {
  it('returns 200 with ok, last_four, token, confirmation_message', async () => {
    const res = await POST(makeReq({ raw_text: 'some forward text' }), makeParams())
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.ok).toBe(true)
    expect(body.last_four).toBe('4567')
    expect(body.token).toBe('12345678:ABCDEFabcdef_-12345678901234567')
    expect(body.confirmation_message).toBe('Got token ending ...4567 — adopt?')
  })

  it('confirmation_message has no " as \"...\"" suffix when officer absent', async () => {
    const res = await POST(makeReq({ raw_text: 'text' }), makeParams())
    const body = await res.json()
    expect(body.confirmation_message).not.toContain(' as "')
  })
})

// ---------------------------------------------------------------------------
// Happy path — with officer
// ---------------------------------------------------------------------------

describe('POST adopt-bot-from-forward — happy path with officer', () => {
  it('confirmation_message includes ` as "cos"` when officer is provided', async () => {
    const res = await POST(makeReq({ raw_text: 'some forward text', officer: 'cos' }), makeParams())
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.confirmation_message).toBe('Got token ending ...4567 — adopt as "cos"?')
  })

  it('last_four matches mock return value', async () => {
    const res = await POST(makeReq({ raw_text: 'text', officer: 'cto' }), makeParams())
    const body = await res.json()
    expect(body.last_four).toBe('4567')
  })

  it('token field present and matches full extracted token', async () => {
    const res = await POST(makeReq({ raw_text: 'text', officer: 'cpo' }), makeParams())
    const body = await res.json()
    expect(body.token).toBe(MOCK_EXTRACT_RESULT.token)
  })
})
