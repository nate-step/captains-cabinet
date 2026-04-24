// GET /api/cabinets/[id]/provisioning-status — Spec 034 PR 5 SSE stream harness
//
// Scope: requireProvisioningAccess guard, cabinet existence check (404), initial
//   snapshot frame, historical event replay (Last-Event-ID header), terminal-state
//   early close (active|archived|failed), Redis Pub/Sub path (subscribe, message
//   handler, terminal auto-close, error/reject cleanup), polling fallback,
//   keep-alive ping, AbortSignal cleanup, response headers.
//
// Mock strategy:
//   - @/lib/provisioning/guard: requireProvisioningAccess → vi.hoisted mockGuard
//   - @/lib/db: query → vi.hoisted mockQuery (top-level DB calls pre-stream)
//   - @/lib/provisioning/audit: getAuditEvents → vi.hoisted mockGetAuditEvents
//   - ioredis: dynamic import mock → vi.mock('ioredis')
//
// SSE stream pattern: read N frames from ReadableStream then cancel reader.
//   Frame format: optional `id: N\n` + `data: {...}\n\n`
//
// Next.js 15 async params: { params: Promise.resolve({ id: 'cab_abc' }) }

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import type { NextRequest } from 'next/server'

// ---------------------------------------------------------------------------
// Hoisted mocks
// ---------------------------------------------------------------------------

const {
  mockGuard,
  mockQuery,
  mockGetAuditEvents,
} = vi.hoisted(() => ({
  mockGuard: vi.fn(),
  mockQuery: vi.fn(),
  mockGetAuditEvents: vi.fn(),
}))

vi.mock('@/lib/provisioning/guard', () => ({
  requireProvisioningAccess: mockGuard,
}))

vi.mock('@/lib/db', () => ({
  query: mockQuery,
}))

vi.mock('@/lib/provisioning/audit', () => ({
  getAuditEvents: mockGetAuditEvents,
}))

const { mockRedisInstance, mockIoredisDefault } = vi.hoisted(() => {
  const instance = {
    subscribe: vi.fn().mockResolvedValue(undefined),
    unsubscribe: vi.fn(),
    on: vi.fn(),
    quit: vi.fn().mockResolvedValue(undefined),
    disconnect: vi.fn(),
  }
  // Must be a real function (not arrow) so `new Redis(url)` works as a constructor.
  function RedisMock(this: unknown) { return instance }
  const mock = vi.fn().mockImplementation(RedisMock)
  return {
    mockRedisInstance: instance,
    mockIoredisDefault: mock,
  }
})

vi.mock('ioredis', () => ({ default: mockIoredisDefault }))

import { GET } from './route'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeParams(id = 'cab_abc') {
  return { params: Promise.resolve({ id }) }
}

function makeReq(options: {
  signal?: AbortSignal
  lastEventId?: string
} = {}): NextRequest {
  const headers: Record<string, string> = {}
  if (options.lastEventId !== undefined) {
    headers['Last-Event-ID'] = options.lastEventId
  }
  const controller = new AbortController()
  return {
    signal: options.signal ?? controller.signal,
    headers: {
      get: (name: string) => headers[name.toLowerCase()] ?? headers[name] ?? null,
    },
  } as unknown as NextRequest
}

function makeAbortableReq(options: { lastEventId?: string } = {}): {
  req: NextRequest
  controller: AbortController
} {
  const controller = new AbortController()
  const headers: Record<string, string> = {}
  if (options.lastEventId !== undefined) {
    headers['Last-Event-ID'] = options.lastEventId
  }
  return {
    req: {
      signal: controller.signal,
      headers: {
        get: (name: string) => headers[name.toLowerCase()] ?? headers[name] ?? null,
      },
    } as unknown as NextRequest,
    controller,
  }
}

function makeCabinetRow(state = 'provisioning', stateEnteredAt = '2024-01-01T00:00:00.000Z') {
  return { state, state_entered_at: stateEnteredAt }
}

function makeAuditEvent(overrides: Partial<{
  event_id: number
  cabinet_id: string
  event_type: string
  state_before: string | null
  state_after: string | null
  timestamp: string
  error: string | null
  actor: string
  entry_point: string
  payload: Record<string, unknown>
}> = {}) {
  return {
    event_id: overrides.event_id ?? 1,
    cabinet_id: overrides.cabinet_id ?? 'cab_abc',
    event_type: overrides.event_type ?? 'state_transition',
    state_before: overrides.state_before ?? null,
    state_after: overrides.state_after ?? 'provisioning',
    timestamp: overrides.timestamp ?? '2024-01-01T00:00:00.000Z',
    error: overrides.error ?? null,
    actor: overrides.actor ?? 'captain',
    entry_point: overrides.entry_point ?? 'dashboard',
    payload: overrides.payload ?? {},
  }
}

/** Drain microtask queue multiple times to let async stream setup code run. */
async function flushMicrotasks(rounds = 5): Promise<void> {
  for (let i = 0; i < rounds; i++) {
    await new Promise(resolve => setImmediate ? setImmediate(resolve) : setTimeout(resolve, 0))
  }
}

/**
 * Start reading a stream, return the reader + first frame, and flush async
 * setup (Redis import/subscribe) so mock assertions fire reliably.
 */
async function startStreamAndFlush(body: ReadableStream<Uint8Array>): Promise<{
  reader: ReadableStreamDefaultReader<Uint8Array>
  firstFrame: string
}> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  const { value } = await reader.read()
  const firstFrame = decoder.decode(value!)
  await flushMicrotasks(10)
  return { reader, firstFrame }
}

/** Read up to N SSE frames from a ReadableStream, then cancel. */
async function readFrames(body: ReadableStream<Uint8Array>, count: number): Promise<string[]> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  const frames: string[] = []
  try {
    while (frames.length < count) {
      const { value, done } = await reader.read()
      if (done) break
      const text = decoder.decode(value)
      // Split on double newline to separate frames (each frame ends with \n\n)
      // A single read may contain multiple frames
      const split = text.split('\n\n').filter(Boolean)
      for (const s of split) {
        frames.push(s + '\n\n')
        if (frames.length >= count) break
      }
    }
  } finally {
    await reader.cancel()
  }
  return frames
}

/** Parse a single SSE frame (may have id: line, event: line, data: line). */
function parseFrame(frame: string): { id?: string; event?: string; data?: unknown } {
  const lines = frame.split('\n').filter(Boolean)
  const result: { id?: string; event?: string; data?: unknown } = {}
  for (const line of lines) {
    if (line.startsWith('id: ')) result.id = line.slice(4)
    if (line.startsWith('event: ')) result.event = line.slice(7)
    if (line.startsWith('data: ')) {
      try { result.data = JSON.parse(line.slice(6)) } catch { result.data = line.slice(6) }
    }
  }
  return result
}

// ---------------------------------------------------------------------------
// Default setup
// ---------------------------------------------------------------------------

beforeEach(() => {
  mockGuard.mockReset()
  mockQuery.mockReset()
  mockGetAuditEvents.mockReset()
  mockRedisInstance.subscribe.mockReset()
  mockRedisInstance.unsubscribe.mockReset()
  mockRedisInstance.on.mockReset()
  mockRedisInstance.quit.mockReset()
  mockRedisInstance.disconnect.mockReset()
  mockIoredisDefault.mockReset()

  // Default: guard passes
  mockGuard.mockResolvedValue({ response: null, user: { token: 'tok_captain' } })
  // Default: cabinet found in non-terminal state
  mockQuery.mockResolvedValue([makeCabinetRow('provisioning')])
  // Default: no audit events for replay
  mockGetAuditEvents.mockResolvedValue([])
  // Default: ioredis works (proper constructor-compatible mock)
  mockRedisInstance.subscribe.mockResolvedValue(undefined)
  mockRedisInstance.quit.mockResolvedValue(undefined)
  function RedisMock(this: unknown) { return mockRedisInstance }
  mockIoredisDefault.mockImplementation(RedisMock)
  // Default: Redis URL set
  process.env.REDIS_URL = 'redis://localhost:6379'
})

afterEach(() => {
  delete process.env.REDIS_URL
  vi.restoreAllMocks()
})

// ---------------------------------------------------------------------------
// Guard short-circuit
// ---------------------------------------------------------------------------

describe('GET provisioning-status — guard short-circuit', () => {
  it('returns guard.response when guard fires (503)', async () => {
    const { NextResponse } = await import('next/server')
    const resp = NextResponse.json({ ok: false, disabled: true }, { status: 503 })
    mockGuard.mockResolvedValueOnce({ response: resp, user: null })
    const res = await GET(makeReq(), makeParams())
    expect(res.status).toBe(503)
    expect(mockQuery).not.toHaveBeenCalled()
  })

  it('returns guard.response when auth guard fires (401)', async () => {
    const { NextResponse } = await import('next/server')
    const resp = NextResponse.json({ ok: false, message: 'Unauthorized' }, { status: 401 })
    mockGuard.mockResolvedValueOnce({ response: resp, user: null })
    const res = await GET(makeReq(), makeParams())
    expect(res.status).toBe(401)
  })
})

// ---------------------------------------------------------------------------
// Cabinet existence check
// ---------------------------------------------------------------------------

describe('GET provisioning-status — cabinet existence', () => {
  it('returns 404 JSON when query returns empty rows', async () => {
    mockQuery.mockResolvedValueOnce([])
    const res = await GET(makeReq(), makeParams('cab_missing'))
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body).toEqual({ ok: false, message: 'Cabinet not found' })
  })

  it('returns 404 JSON when query rejects (falls through .catch(() => null))', async () => {
    mockQuery.mockRejectedValueOnce(new Error('DB timeout'))
    const res = await GET(makeReq(), makeParams())
    expect(res.status).toBe(404)
  })
})

// ---------------------------------------------------------------------------
// Response headers
// ---------------------------------------------------------------------------

describe('GET provisioning-status — response headers', () => {
  it('Content-Type is text/event-stream', async () => {
    const res = await GET(makeReq(), makeParams())
    expect(res.headers.get('Content-Type')).toBe('text/event-stream')
  })

  it('Cache-Control contains no-cache', async () => {
    const res = await GET(makeReq(), makeParams())
    expect(res.headers.get('Cache-Control')).toContain('no-cache')
  })

  it('X-Accel-Buffering is no', async () => {
    const res = await GET(makeReq(), makeParams())
    expect(res.headers.get('X-Accel-Buffering')).toBe('no')
  })

  it('Transfer-Encoding is chunked', async () => {
    const res = await GET(makeReq(), makeParams())
    expect(res.headers.get('Transfer-Encoding')).toBe('chunked')
  })

  it('Connection is keep-alive', async () => {
    const res = await GET(makeReq(), makeParams())
    expect(res.headers.get('Connection')).toBe('keep-alive')
  })
})

// ---------------------------------------------------------------------------
// Initial snapshot frame
// ---------------------------------------------------------------------------

describe('GET provisioning-status — initial snapshot', () => {
  it('first frame is snapshot type with cabinet state', async () => {
    const res = await GET(makeReq(), makeParams('cab_abc'))
    const frames = await readFrames(res.body!, 1)
    expect(frames.length).toBe(1)
    const parsed = parseFrame(frames[0])
    const data = parsed.data as Record<string, unknown>
    expect(data.type).toBe('snapshot')
    expect(data.cabinet_id).toBe('cab_abc')
    expect(data.state).toBe('provisioning')
  })

  it('snapshot carries state_entered_at from query result', async () => {
    mockQuery.mockResolvedValueOnce([makeCabinetRow('provisioning', '2024-06-01T10:00:00.000Z')])
    const res = await GET(makeReq(), makeParams())
    const frames = await readFrames(res.body!, 1)
    const data = parseFrame(frames[0]).data as Record<string, unknown>
    expect(data.state_entered_at).toBe('2024-06-01T10:00:00.000Z')
  })

  it('snapshot carries event_count (0 when no replay events)', async () => {
    const res = await GET(makeReq(), makeParams())
    const frames = await readFrames(res.body!, 1)
    const data = parseFrame(frames[0]).data as Record<string, unknown>
    expect(data.event_count).toBe(0)
  })

  it('snapshot carries last_event_id=null when no replay events', async () => {
    const res = await GET(makeReq(), makeParams())
    const frames = await readFrames(res.body!, 1)
    const data = parseFrame(frames[0]).data as Record<string, unknown>
    expect(data.last_event_id).toBeNull()
  })

  it('snapshot carries last_event_id from last replay event when events present', async () => {
    mockGetAuditEvents.mockResolvedValueOnce([
      makeAuditEvent({ event_id: 5 }),
      makeAuditEvent({ event_id: 10 }),
    ])
    const res = await GET(makeReq(), makeParams())
    const frames = await readFrames(res.body!, 1)
    const data = parseFrame(frames[0]).data as Record<string, unknown>
    expect(data.last_event_id).toBe(10)
    expect(data.event_count).toBe(2)
  })
})

// ---------------------------------------------------------------------------
// Last-Event-ID header / replay
// ---------------------------------------------------------------------------

describe('GET provisioning-status — Last-Event-ID / replay', () => {
  it('passes sinceEventId parsed from Last-Event-ID header to getAuditEvents', async () => {
    const res = await GET(makeReq({ lastEventId: '7' }), makeParams('cab_abc'))
    await readFrames(res.body!, 1)
    expect(mockGetAuditEvents).toHaveBeenCalledWith('cab_abc', 7)
  })

  it('passes sinceEventId=undefined when Last-Event-ID header absent', async () => {
    const res = await GET(makeReq(), makeParams('cab_abc'))
    await readFrames(res.body!, 1)
    expect(mockGetAuditEvents).toHaveBeenCalledWith('cab_abc', undefined)
  })

  it('emits one replay event frame per audit event', async () => {
    mockGetAuditEvents.mockResolvedValueOnce([
      makeAuditEvent({ event_id: 1, event_type: 'state_transition' }),
      makeAuditEvent({ event_id: 2, event_type: 'adopt_bot' }),
    ])
    const res = await GET(makeReq(), makeParams('cab_abc'))
    // 1 snapshot + 2 replay events
    const frames = await readFrames(res.body!, 3)
    expect(frames.length).toBe(3)
    const replayFrame1 = parseFrame(frames[1])
    const replayFrame2 = parseFrame(frames[2])
    expect((replayFrame1.data as Record<string, unknown>).type).toBe('event')
    expect((replayFrame1.data as Record<string, unknown>).event_type).toBe('state_transition')
    expect((replayFrame2.data as Record<string, unknown>).event_type).toBe('adopt_bot')
  })

  it('replay event frame includes id: line with event_id', async () => {
    mockGetAuditEvents.mockResolvedValueOnce([
      makeAuditEvent({ event_id: 42 }),
    ])
    const res = await GET(makeReq(), makeParams('cab_abc'))
    const frames = await readFrames(res.body!, 2)
    const replayFrame = parseFrame(frames[1])
    expect(replayFrame.id).toBe('42')
  })

  it('replay event frame carries full payload fields', async () => {
    mockGetAuditEvents.mockResolvedValueOnce([
      makeAuditEvent({
        event_id: 3,
        event_type: 'state_transition',
        state_before: 'creating',
        state_after: 'adopting-bots',
        timestamp: '2024-01-02T12:00:00.000Z',
        error: null,
      }),
    ])
    const res = await GET(makeReq(), makeParams('cab_abc'))
    const frames = await readFrames(res.body!, 2)
    const data = parseFrame(frames[1]).data as Record<string, unknown>
    expect(data.event_type).toBe('state_transition')
    expect(data.state_before).toBe('creating')
    expect(data.state_after).toBe('adopting-bots')
    expect(data.timestamp).toBe('2024-01-02T12:00:00.000Z')
    expect(data.error).toBeNull()
  })

  it('falls back to empty replay when getAuditEvents throws', async () => {
    mockGetAuditEvents.mockRejectedValueOnce(new Error('DB error'))
    const res = await GET(makeReq(), makeParams('cab_abc'))
    // Should still get the snapshot frame; no crash
    const frames = await readFrames(res.body!, 1)
    const data = parseFrame(frames[0]).data as Record<string, unknown>
    expect(data.type).toBe('snapshot')
    expect(data.event_count).toBe(0)
  })
})

// ---------------------------------------------------------------------------
// Terminal state auto-close
// ---------------------------------------------------------------------------

describe('GET provisioning-status — terminal state auto-close', () => {
  for (const terminalState of ['active', 'archived', 'failed']) {
    it(`closes stream immediately after replay for terminal state "${terminalState}"`, async () => {
      mockQuery.mockResolvedValueOnce([makeCabinetRow(terminalState)])
      const res = await GET(makeReq(), makeParams('cab_abc'))
      // Should get: snapshot + done, then stream ends (done = true on next read)
      const reader = res.body!.getReader()
      const decoder = new TextDecoder()
      const allText: string[] = []
      while (true) {
        const { value, done } = await reader.read()
        if (done) break
        allText.push(decoder.decode(value))
      }
      const combined = allText.join('')
      // Must include type:done
      expect(combined).toContain('"type":"done"')
      // Redis subscribe must NOT be called (terminal = no live sub needed)
      expect(mockRedisInstance.subscribe).not.toHaveBeenCalled()
    })
  }

  it('done event carries the terminal state and cabinet_id', async () => {
    mockQuery.mockResolvedValueOnce([makeCabinetRow('active')])
    const res = await GET(makeReq(), makeParams('cab_abc'))
    const reader = res.body!.getReader()
    const decoder = new TextDecoder()
    const allText: string[] = []
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      allText.push(decoder.decode(value))
    }
    const combined = allText.join('')
    const frames = combined.split('\n\n').filter(Boolean).map(f => f + '\n\n')
    const doneFrame = frames.find(f => f.includes('"type":"done"'))
    expect(doneFrame).toBeDefined()
    const data = parseFrame(doneFrame!).data as Record<string, unknown>
    expect(data.state).toBe('active')
    expect(data.cabinet_id).toBe('cab_abc')
  })
})

// ---------------------------------------------------------------------------
// Redis Pub/Sub — non-terminal state
// ---------------------------------------------------------------------------

describe('GET provisioning-status — Redis Pub/Sub', () => {
  it('calls ioredis constructor with REDIS_URL', async () => {
    const res = await GET(makeReq(), makeParams())
    const { reader } = await startStreamAndFlush(res.body!)
    expect(mockIoredisDefault).toHaveBeenCalledWith('redis://localhost:6379')
    await reader.cancel()
  })

  it('subscribes to cabinet:events:<id> channel', async () => {
    const res = await GET(makeReq(), makeParams('cab_xyz'))
    const { reader } = await startStreamAndFlush(res.body!)
    expect(mockRedisInstance.subscribe).toHaveBeenCalledWith('cabinet:events:cab_xyz')
    await reader.cancel()
  })

  it('registers message and error handlers on sub', async () => {
    const res = await GET(makeReq(), makeParams())
    const { reader } = await startStreamAndFlush(res.body!)
    const events = mockRedisInstance.on.mock.calls.map(c => c[0])
    expect(events).toContain('message')
    expect(events).toContain('error')
    await reader.cancel()
  })

  it('message handler emits event frame with parsed payload', async () => {
    const res = await GET(makeReq(), makeParams('cab_abc'))
    const decoder = new TextDecoder()
    const { reader } = await startStreamAndFlush(res.body!)

    // Simulate Redis pub/sub message
    const msgHandler = mockRedisInstance.on.mock.calls.find(c => c[0] === 'message')?.[1]
    expect(msgHandler).toBeDefined()

    const pubPayload = JSON.stringify({
      cabinet_id: 'cab_abc',
      event_type: 'state_transition',
      state_before: 'creating',
      state_after: 'adopting-bots',
      error: null,
      timestamp: '2024-01-01T10:00:00.000Z',
    })
    msgHandler!('cabinet:events:cab_abc', pubPayload)

    const { value } = await reader.read()
    await reader.cancel()

    const frameText = decoder.decode(value)
    const data = parseFrame(frameText).data as Record<string, unknown>
    expect(data.type).toBe('event')
    expect(data.event_type).toBe('state_transition')
    expect(data.state_before).toBe('creating')
    expect(data.state_after).toBe('adopting-bots')
    expect(data.cabinet_id).toBe('cab_abc')
  })

  it('message handler auto-closes stream on terminal state_after', async () => {
    const res = await GET(makeReq(), makeParams('cab_abc'))
    const decoder = new TextDecoder()
    const { reader } = await startStreamAndFlush(res.body!)

    const msgHandler = mockRedisInstance.on.mock.calls.find(c => c[0] === 'message')?.[1]
    expect(msgHandler).toBeDefined()

    const pubPayload = JSON.stringify({
      cabinet_id: 'cab_abc',
      event_type: 'state_transition',
      state_before: 'provisioning',
      state_after: 'active',
      error: null,
      timestamp: '2024-01-01T10:00:00.000Z',
    })
    msgHandler!('cabinet:events:cab_abc', pubPayload)

    // Should get: event frame + done frame, then stream ends
    const allText: string[] = []
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      allText.push(decoder.decode(value))
    }
    const combined = allText.join('')
    expect(combined).toContain('"type":"done"')
  })

  it('subscribe reject triggers cleanup', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockRedisInstance.subscribe.mockRejectedValueOnce(new Error('subscribe failed'))
    const res = await GET(makeReq(), makeParams())
    const { reader } = await startStreamAndFlush(res.body!)
    await flushMicrotasks(5)
    expect(mockRedisInstance.unsubscribe).toHaveBeenCalled()
    await reader.cancel()
    errorSpy.mockRestore()
  })

  it('error handler triggers cleanup', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const res = await GET(makeReq(), makeParams())
    const { reader } = await startStreamAndFlush(res.body!)

    const errorHandler = mockRedisInstance.on.mock.calls.find(c => c[0] === 'error')?.[1]
    expect(errorHandler).toBeDefined()
    errorHandler!(new Error('Redis dropped'))

    await flushMicrotasks(3)
    expect(mockRedisInstance.unsubscribe).toHaveBeenCalled()
    await reader.cancel()
    warnSpy.mockRestore()
  })

  it('does NOT subscribe when ioredis import throws', async () => {
    function ThrowingMock(this: unknown): never { throw new Error('no module') }
    mockIoredisDefault.mockImplementationOnce(ThrowingMock)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const res = await GET(makeReq(), makeParams())
    const { reader } = await startStreamAndFlush(res.body!)
    expect(mockRedisInstance.subscribe).not.toHaveBeenCalled()
    await reader.cancel()
    warnSpy.mockRestore()
  })
})

// ---------------------------------------------------------------------------
// Polling fallback
// ---------------------------------------------------------------------------

describe('GET provisioning-status — polling fallback (no Redis)', () => {
  it('does NOT call ioredis when REDIS_URL is unset', async () => {
    delete process.env.REDIS_URL
    const res = await GET(makeReq(), makeParams())
    const { reader } = await startStreamAndFlush(res.body!)
    expect(mockIoredisDefault).not.toHaveBeenCalled()
    await reader.cancel()
  })

  it('does NOT subscribe when REDIS_URL is unset', async () => {
    delete process.env.REDIS_URL
    const res = await GET(makeReq(), makeParams())
    const { reader } = await startStreamAndFlush(res.body!)
    expect(mockRedisInstance.subscribe).not.toHaveBeenCalled()
    await reader.cancel()
  })

  it('emits state_transition event when polling detects a state change', async () => {
    delete process.env.REDIS_URL

    // First poll: same state; second poll: state changed
    mockQuery
      .mockResolvedValueOnce([makeCabinetRow('provisioning')]) // initial existence check
      .mockResolvedValueOnce([makeCabinetRow('provisioning')]) // poll 1: no change
      .mockResolvedValueOnce([makeCabinetRow('adopting-bots', '2024-01-02T00:00:00.000Z')]) // poll 2: changed

    // Use fake timers so we can advance the poll interval
    vi.useFakeTimers()

    const res = await GET(makeReq(), makeParams('cab_abc'))
    const reader = res.body!.getReader()
    const decoder = new TextDecoder()

    // Read snapshot
    await reader.read()

    // Advance past first poll (no change)
    await vi.advanceTimersByTimeAsync(3_000)
    // Advance past second poll (state change)
    await vi.advanceTimersByTimeAsync(3_000)

    const { value } = await reader.read()
    const text = decoder.decode(value)
    const data = parseFrame(text).data as Record<string, unknown>
    expect(data.type).toBe('event')
    expect(data.event_type).toBe('state_transition')
    expect(data.state_after).toBe('adopting-bots')

    await reader.cancel()
    vi.useRealTimers()
  })

  it('closes stream when polling detects cabinet deleted (0 rows)', async () => {
    delete process.env.REDIS_URL
    vi.useFakeTimers()

    mockQuery
      .mockResolvedValueOnce([makeCabinetRow('provisioning')])
      .mockResolvedValueOnce([]) // poll: 0 rows = cabinet deleted

    const res = await GET(makeReq(), makeParams('cab_abc'))
    const reader = res.body!.getReader()

    // Read snapshot
    await reader.read()

    // Advance timers to trigger the poll interval, then flush microtasks
    await vi.advanceTimersByTimeAsync(3_000)
    // Use real microtask drain to let async DB poll and close() run
    await vi.runAllTimersAsync()

    // Stream should now be closed — the next read returns done:true
    const { done } = await reader.read()
    expect(done).toBe(true)

    vi.useRealTimers()
  })

  it('polling detects terminal state → emits done + closes', async () => {
    delete process.env.REDIS_URL
    vi.useFakeTimers()

    mockQuery
      .mockResolvedValueOnce([makeCabinetRow('provisioning')])
      .mockResolvedValueOnce([makeCabinetRow('active')]) // poll: terminal state

    const res = await GET(makeReq(), makeParams('cab_abc'))
    const reader = res.body!.getReader()
    const decoder = new TextDecoder()

    // Read snapshot
    await reader.read()

    await vi.advanceTimersByTimeAsync(3_000)

    const allText: string[] = []
    while (true) {
      const { value, done } = await reader.read()
      if (done) break
      allText.push(decoder.decode(value))
      // Collected the state_transition + done frames? Stop.
      if (allText.join('').includes('"type":"done"')) break
    }
    const combined = allText.join('')
    expect(combined).toContain('"type":"done"')

    await reader.cancel()
    vi.useRealTimers()
  })
})

// ---------------------------------------------------------------------------
// AbortSignal cleanup
// ---------------------------------------------------------------------------

describe('GET provisioning-status — AbortSignal cleanup', () => {
  it('calls unsubscribe on client disconnect', async () => {
    const { req, controller } = makeAbortableReq()
    const res = await GET(req, makeParams())
    const { reader } = await startStreamAndFlush(res.body!)

    controller.abort()
    await flushMicrotasks(3)

    expect(mockRedisInstance.unsubscribe).toHaveBeenCalled()
    await reader.cancel()
  })
})

// ---------------------------------------------------------------------------
// Next.js 15 async params
// ---------------------------------------------------------------------------

describe('GET provisioning-status — Next.js 15 async params', () => {
  it('resolves cabinet id from Promise params', async () => {
    const res = await GET(makeReq(), { params: Promise.resolve({ id: 'cab_async_test' }) })
    // If params resolved correctly, query would be called with the right id
    const frames = await readFrames(res.body!, 1)
    const data = parseFrame(frames[0]).data as Record<string, unknown>
    expect(data.cabinet_id).toBe('cab_async_test')
  })
})

// ---------------------------------------------------------------------------
// ReadableStream body type
// ---------------------------------------------------------------------------

describe('GET provisioning-status — response body type', () => {
  it('body is an instance of ReadableStream', async () => {
    const res = await GET(makeReq(), makeParams())
    expect(res.body).toBeInstanceOf(ReadableStream)
  })
})
