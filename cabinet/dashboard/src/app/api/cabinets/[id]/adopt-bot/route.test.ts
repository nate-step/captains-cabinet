// Spec 034 — POST /api/cabinets/[id]/adopt-bot handler harness
//
// Scope: validates bot token regex, officer slot logic (new/update/orphan),
//   full transaction lifecycle (BEGIN/SELECT/UPDATE/COMMIT + ROLLBACK paths),
//   writeAuditEvent for adopt_bot and orphan_bot events, startProvisioningRun
//   fire-and-forget when all slots filled, and 500 error path.
//
// Mock strategy: vi.hoisted for client/pool/guard/audit/worker mocks.
//   getDbPool() returns a pool whose .connect() returns a client with .query()
//   returning {rows:[...]}. canTransition IS imported in route.ts but NEVER
//   called in this handler — not mocked here.
//
// Notable invariants pinned:
//   - BOT_TOKEN_RE: /^[0-9]{8,12}:[a-zA-Z0-9_-]{35}$/ (8-12 digits, exactly 35 alpha)
//   - officer_slots null/non-array defaults to [] without throw
//   - orphan audit event fires only when existing slot has DIFFERENT bot_token
//   - startProvisioningRun called only when every slot has non-null bot_token
//   - client.release() always called (finally block), even on throw

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

const {
  mockGuard,
  mockClient,
  mockPool,
  mockWriteAudit,
  mockStartRun,
} = vi.hoisted(() => {
  const client = { query: vi.fn(), release: vi.fn() }
  const pool = { connect: vi.fn(async () => client) }
  return {
    mockGuard: vi.fn(),
    mockClient: client,
    mockPool: pool,
    mockWriteAudit: vi.fn(),
    mockStartRun: vi.fn(),
  }
})

vi.mock('@/lib/provisioning/guard', () => ({
  requireProvisioningAccess: mockGuard,
}))

vi.mock('@/lib/db', () => ({
  query: vi.fn(),
  getDbPool: () => mockPool,
}))

vi.mock('@/lib/provisioning/audit', () => ({
  writeAuditEvent: mockWriteAudit,
}))

vi.mock('@/lib/provisioning/worker', () => ({
  startProvisioningRun: mockStartRun,
}))

vi.mock('@/lib/provisioning/state-machine', () => ({
  canTransition: vi.fn(() => ({ ok: true })),
}))

import { POST } from './route'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** 35-char secret for use in all tokens below */
const SECRET35 = 'ABCDEFGHIJabcdefghij_-1234567890123'
/** Minimal valid bot token: exactly 8 digits + colon + exactly 35 alphanumeric/underscore/hyphen */
const VALID_TOKEN = `12345678:${SECRET35}`
/** 8 digits exactly (lower bound of regex) */
const TOKEN_8_DIGITS = `12345678:${SECRET35}`
/** 12 digits exactly (upper bound of regex) */
const TOKEN_12_DIGITS = `123456789012:${SECRET35}`

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

type SlotRow = { role: string; bot_token: string | null; adopted_at: string | null }

function makeCabinetRow(overrides: {
  state?: string
  officer_slots?: SlotRow[] | null | string
} = {}) {
  return {
    state: overrides.state ?? 'adopting-bots',
    officer_slots: overrides.officer_slots !== undefined ? overrides.officer_slots : [],
  }
}

/** Setup client.query for a full happy-path transaction */
function setupHappyPath(row = makeCabinetRow()) {
  mockClient.query
    .mockResolvedValueOnce(undefined)           // BEGIN
    .mockResolvedValueOnce({ rows: [row] })      // SELECT FOR UPDATE
    .mockResolvedValueOnce(undefined)            // UPDATE
    .mockResolvedValueOnce(undefined)            // COMMIT
}

beforeEach(() => {
  mockGuard.mockReset()
  mockClient.query.mockReset()
  mockClient.release.mockReset()
  mockPool.connect.mockReset()
  mockPool.connect.mockImplementation(async () => mockClient)
  mockWriteAudit.mockReset()
  mockStartRun.mockReset()

  mockGuard.mockResolvedValue({ response: null, user: { token: 'tok_captain' } })
  mockWriteAudit.mockResolvedValue(undefined)
  mockStartRun.mockReturnValue(undefined)
})

// ---------------------------------------------------------------------------
// Guard short-circuit
// ---------------------------------------------------------------------------

describe('POST adopt-bot — guard short-circuit', () => {
  it('returns guard.response when guard fires (503 feature-flag)', async () => {
    const resp = NextResponse.json({ ok: false, disabled: true }, { status: 503 })
    mockGuard.mockResolvedValueOnce({ response: resp, user: null })
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(res.status).toBe(503)
    expect(mockPool.connect).not.toHaveBeenCalled()
  })

  it('returns guard.response when auth guard fires (401)', async () => {
    const resp = NextResponse.json({ ok: false, message: 'Unauthorized' }, { status: 401 })
    mockGuard.mockResolvedValueOnce({ response: resp, user: null })
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(res.status).toBe(401)
    expect(mockPool.connect).not.toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// Body validation (400)
// ---------------------------------------------------------------------------

describe('POST adopt-bot — body validation (400)', () => {
  it('400 when req.json() throws (malformed JSON)', async () => {
    const res = await POST(makeReq(null, true), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Invalid JSON body' })
    expect(mockPool.connect).not.toHaveBeenCalled()
  })

  it('400 when officer is missing', async () => {
    const res = await POST(makeReq({ bot_token: VALID_TOKEN }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('officer is required')
  })

  it('400 when officer is empty string', async () => {
    const res = await POST(makeReq({ officer: '', bot_token: VALID_TOKEN }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('officer is required')
  })

  it('400 when officer is whitespace-only', async () => {
    const res = await POST(makeReq({ officer: '   ', bot_token: VALID_TOKEN }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('officer is required')
  })

  it('400 when bot_token is missing', async () => {
    const res = await POST(makeReq({ officer: 'cos' }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('bot_token is required')
  })

  it('400 when bot_token is empty string', async () => {
    const res = await POST(makeReq({ officer: 'cos', bot_token: '' }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toBe('bot_token is required')
  })

  it('400 when bot_token has too-few digits (7 digits)', async () => {
    const res = await POST(makeReq({ officer: 'cos', bot_token: `1234567:${SECRET35}` }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toContain('bot_token format is invalid')
  })

  it('400 when bot_token has too-many digits (13 digits)', async () => {
    const res = await POST(makeReq({ officer: 'cos', bot_token: `1234567890123:${SECRET35}` }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toContain('bot_token format is invalid')
  })

  it('400 when bot_token uses wrong separator (underscore instead of colon)', async () => {
    const res = await POST(makeReq({ officer: 'cos', bot_token: `12345678_${SECRET35}` }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toContain('bot_token format is invalid')
  })

  it('400 when secret part is too short (34 chars instead of 35)', async () => {
    const res = await POST(makeReq({ officer: 'cos', bot_token: `12345678:${SECRET35.slice(0, 34)}` }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toContain('bot_token format is invalid')
  })

  it('400 when secret part is too long (36 chars)', async () => {
    const res = await POST(makeReq({ officer: 'cos', bot_token: `12345678:${SECRET35}X` }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toContain('bot_token format is invalid')
  })

  it('400 when bot_token has trailing characters after valid format', async () => {
    const res = await POST(makeReq({ officer: 'cos', bot_token: `${VALID_TOKEN}XY` }), makeParams())
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.message).toContain('bot_token format is invalid')
  })

  it('boundary: exactly 8 digits passes regex (lower bound)', async () => {
    // 8-digit token with exactly 35-char secret
    setupHappyPath()
    const res = await POST(makeReq({ officer: 'cos', bot_token: TOKEN_8_DIGITS }), makeParams())
    expect(res.status).not.toBe(400)
  })

  it('boundary: exactly 12 digits passes regex (upper bound)', async () => {
    setupHappyPath()
    const res = await POST(makeReq({ officer: 'cos', bot_token: TOKEN_12_DIGITS }), makeParams())
    expect(res.status).not.toBe(400)
  })
})

// ---------------------------------------------------------------------------
// 404 — cabinet not found
// ---------------------------------------------------------------------------

describe('POST adopt-bot — 404 (cabinet not found)', () => {
  it('returns 404 when SELECT returns empty rows', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)         // BEGIN
      .mockResolvedValueOnce({ rows: [] })       // SELECT FOR UPDATE (not found)
      .mockResolvedValueOnce(undefined)          // ROLLBACK
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Cabinet not found' })
  })

  it('ROLLBACK called on 404', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
  })

  it('client.release() called on 404 (finally block)', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(mockClient.release).toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// 409 — wrong state
// ---------------------------------------------------------------------------

describe('POST adopt-bot — 409 (wrong state)', () => {
  it.each(['active', 'suspended', 'archived'])(
    'returns 409 when state is "%s"',
    async (state) => {
      mockClient.query
        .mockResolvedValueOnce(undefined)
        .mockResolvedValueOnce({ rows: [makeCabinetRow({ state })] })
        .mockResolvedValueOnce(undefined)
      const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
      expect(res.status).toBe(409)
      const body = await res.json()
      expect(body.message).toContain(state)
      expect(body.message).toContain("adopting-bots")
    }
  )

  it('ROLLBACK called on 409 wrong state', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'active' })] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
  })

  it('client.release() called on 409 (finally block)', async () => {
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockResolvedValueOnce({ rows: [makeCabinetRow({ state: 'suspended' })] })
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(mockClient.release).toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// Happy path — new slot
// ---------------------------------------------------------------------------

describe('POST adopt-bot — happy path (new slot)', () => {
  it('returns 200 with ok, officer, slot_count, all_bots_adopted', async () => {
    setupHappyPath()
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.ok).toBe(true)
    expect(body.officer).toBe('cos')
    expect(body.slot_count).toBe(1)
    expect(body.all_bots_adopted).toBe(true) // only slot, has token
  })

  it('no orphan_warning when new slot', async () => {
    setupHappyPath()
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    const body = await res.json()
    expect(body.orphan_warning).toBeUndefined()
  })

  it('transaction sequence: BEGIN → SELECT FOR UPDATE → UPDATE → COMMIT', async () => {
    setupHappyPath()
    await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(mockClient.query).toHaveBeenNthCalledWith(1, 'BEGIN')
    expect(mockClient.query).toHaveBeenNthCalledWith(4, 'COMMIT')
  })

  it('writeAuditEvent called with adopt_bot event shape', async () => {
    setupHappyPath()
    await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams('cab_xyz'))
    expect(mockWriteAudit).toHaveBeenCalledTimes(1)
    const [arg] = mockWriteAudit.mock.calls[0]
    expect(arg.cabinet_id).toBe('cab_xyz')
    expect(arg.actor).toBe('tok_captain')
    expect(arg.entry_point).toBe('dashboard')
    expect(arg.event_type).toBe('adopt_bot')
    expect(arg.payload.officer).toBe('cos')
    expect(arg.payload.slot_count).toBe(1)
  })

  it('client.release() called on success (finally block)', async () => {
    setupHappyPath()
    await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(mockClient.release).toHaveBeenCalled()
  })

  it('startProvisioningRun called when all slots have tokens', async () => {
    setupHappyPath()
    await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams('cab_abc'))
    expect(mockStartRun).toHaveBeenCalledWith('cab_abc', 'tok_captain')
  })
})

// ---------------------------------------------------------------------------
// Happy path — existing slot (same token, no orphan)
// ---------------------------------------------------------------------------

describe('POST adopt-bot — existing slot same token', () => {
  it('updates in-place with no orphan event when token matches', async () => {
    const existingSlot = { role: 'cos', bot_token: VALID_TOKEN, adopted_at: '2024-01-01T00:00:00Z' }
    setupHappyPath(makeCabinetRow({ officer_slots: [existingSlot] }))
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.orphan_warning).toBeUndefined()
    // Only one audit event (adopt_bot, no orphan_bot)
    expect(mockWriteAudit).toHaveBeenCalledTimes(1)
    const [arg] = mockWriteAudit.mock.calls[0]
    expect(arg.event_type).toBe('adopt_bot')
  })
})

// ---------------------------------------------------------------------------
// Happy path — existing slot different token (orphan)
// ---------------------------------------------------------------------------

describe('POST adopt-bot — existing slot different token (orphan)', () => {
  const OLD_TOKEN = `11111111:BBBBBBGHIJbbbbbbbbbb_-1234567890123`

  it('captures orphanToken and fires second writeAuditEvent with event_type orphan_bot', async () => {
    const existingSlot = { role: 'cos', bot_token: OLD_TOKEN, adopted_at: '2024-01-01T00:00:00Z' }
    setupHappyPath(makeCabinetRow({ officer_slots: [existingSlot] }))
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams('cab_abc'))
    expect(res.status).toBe(200)
    expect(mockWriteAudit).toHaveBeenCalledTimes(2)
    const orphanCall = mockWriteAudit.mock.calls[1][0]
    expect(orphanCall.event_type).toBe('orphan_bot')
    expect(orphanCall.payload.officer).toBe('cos')
  })

  it('orphan_warning field present in response when orphan occurs', async () => {
    const existingSlot = { role: 'cos', bot_token: OLD_TOKEN, adopted_at: '2024-01-01T00:00:00Z' }
    setupHappyPath(makeCabinetRow({ officer_slots: [existingSlot] }))
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    const body = await res.json()
    expect(typeof body.orphan_warning).toBe('string')
    expect(body.orphan_warning).toContain('cos')
  })
})

// ---------------------------------------------------------------------------
// all_bots_adopted logic
// ---------------------------------------------------------------------------

describe('POST adopt-bot — all_bots_adopted logic', () => {
  it('all_bots_adopted=false when some existing slots have null bot_token', async () => {
    const slots: SlotRow[] = [
      { role: 'cpo', bot_token: VALID_TOKEN, adopted_at: '2024-01-01T00:00:00Z' },
      { role: 'coo', bot_token: null, adopted_at: null },
    ]
    setupHappyPath(makeCabinetRow({ officer_slots: slots }))
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    const body = await res.json()
    // New slot added → slots are [cpo(token), coo(null), cos(token)] → not all filled
    expect(body.all_bots_adopted).toBe(false)
    expect(mockStartRun).not.toHaveBeenCalled()
  })

  it('all_bots_adopted=true and startProvisioningRun called when all filled', async () => {
    const slots: SlotRow[] = [
      { role: 'cpo', bot_token: VALID_TOKEN, adopted_at: '2024-01-01T00:00:00Z' },
    ]
    setupHappyPath(makeCabinetRow({ officer_slots: slots }))
    await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams('cab_abc'))
    // After adding cos, slots are [cpo(token), cos(token)] → all filled
    expect(mockStartRun).toHaveBeenCalledWith('cab_abc', 'tok_captain')
  })
})

// ---------------------------------------------------------------------------
// officer_slots non-array defaults
// ---------------------------------------------------------------------------

describe('POST adopt-bot — officer_slots non-array defaults to []', () => {
  it.each([null, 'not-an-array', 42])(
    'officer_slots=%s defaults to [] without throw',
    async (badSlots) => {
      setupHappyPath(makeCabinetRow({ officer_slots: badSlots as never }))
      const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
      expect(res.status).toBe(200)
      const body = await res.json()
      expect(body.slot_count).toBe(1) // started from [] → pushed one slot
    }
  )
})

// ---------------------------------------------------------------------------
// Error path (500)
// ---------------------------------------------------------------------------

describe('POST adopt-bot — error path (500)', () => {
  it('returns 500 when BEGIN throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockRejectedValueOnce(new Error('pg connect fail'))   // BEGIN throws
      .mockResolvedValueOnce(undefined)                       // ROLLBACK
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Failed to adopt bot' })
    spy.mockRestore()
  })

  it('ROLLBACK called when UPDATE throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)              // BEGIN
      .mockResolvedValueOnce({ rows: [makeCabinetRow()] }) // SELECT
      .mockRejectedValueOnce(new Error('deadlock')) // UPDATE throws
      .mockResolvedValueOnce(undefined)             // ROLLBACK
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(res.status).toBe(500)
    expect(mockClient.query).toHaveBeenCalledWith('ROLLBACK')
    spy.mockRestore()
  })

  it('client.release() called on error (finally block)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('pg down'))
      .mockResolvedValueOnce(undefined)
    await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    expect(mockClient.release).toHaveBeenCalled()
    spy.mockRestore()
  })

  it('500 does not leak internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockClient.query
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('secret: DB password=hunter2'))
      .mockResolvedValueOnce(undefined)
    const res = await POST(makeReq({ officer: 'cos', bot_token: VALID_TOKEN }), makeParams())
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('hunter2')
    spy.mockRestore()
  })
})
