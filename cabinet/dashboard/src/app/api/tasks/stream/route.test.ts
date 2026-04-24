// GET /api/tasks/stream — Spec 038 §4.6 SSE stream harness
//
// Scope: auth cookie guard (401), response headers, initial connected event,
//   Redis Pub/Sub path (subscribe called, message handler, error/reject cleanup),
//   polling fallback when REDIS_URL unset or ioredis throws, keep-alive ping,
//   AbortSignal cleanup, ReadableStream body type.
//
// Mock strategy:
//   - `next/headers` cookies() — dynamic import mock with per-test cookieStore
//   - ioredis — dynamic import mock via vi.mock('ioredis')
//   - REDIS_URL set/unset via process.env per test
//
// SSE stream pattern: read N frames synchronously from the ReadableStream,
//   cancel the reader to trigger cleanup. This avoids infinite keep-alive loops
//   fighting with fake timers.

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import type { NextRequest } from 'next/server'

// ---------------------------------------------------------------------------
// Hoisted mocks
// ---------------------------------------------------------------------------

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

// Per-test cookie store
let mockCookieStore: Record<string, { value: string } | undefined> = {}

vi.mock('next/headers', () => ({
  cookies: vi.fn(async () => ({
    get: (name: string) => mockCookieStore[name],
  })),
}))

import { GET } from './route'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeReq(options: {
  signal?: AbortSignal
  withSession?: boolean
} = {}): NextRequest {
  const controller = new AbortController()
  return {
    signal: options.signal ?? controller.signal,
  } as unknown as NextRequest
}

function makeAbortableReq(): { req: NextRequest; controller: AbortController } {
  const controller = new AbortController()
  return {
    req: { signal: controller.signal } as unknown as NextRequest,
    controller,
  }
}

/** Drain microtask queue multiple times to let async stream setup code run. */
async function flushMicrotasks(rounds = 5): Promise<void> {
  for (let i = 0; i < rounds; i++) {
    await new Promise(resolve => setImmediate ? setImmediate(resolve) : setTimeout(resolve, 0))
  }
}

/** Read up to N SSE frames from a ReadableStream then cancel. */
async function readFrames(body: ReadableStream<Uint8Array>, count: number): Promise<string[]> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  const frames: string[] = []
  try {
    while (frames.length < count) {
      const { value, done } = await reader.read()
      if (done) break
      frames.push(decoder.decode(value))
    }
  } finally {
    await reader.cancel()
  }
  return frames
}

/**
 * Start reading a stream and return the reader plus the first frame,
 * then flush async setup code so Redis mocks are populated.
 */
async function startStreamAndFlush(body: ReadableStream<Uint8Array>): Promise<{
  reader: ReadableStreamDefaultReader<Uint8Array>
  firstFrame: string
}> {
  const reader = body.getReader()
  const decoder = new TextDecoder()
  const { value } = await reader.read()
  const firstFrame = decoder.decode(value!)
  // Flush microtasks so the async `await import('ioredis')` block in the stream's
  // start() function has a chance to run and populate the mock instance's handlers.
  await flushMicrotasks(10)
  return { reader, firstFrame }
}

/** Extract the data payload from an SSE frame string. */
function parseFrame(frame: string): { event?: string; data?: unknown } {
  const lines = frame.split('\n').filter(Boolean)
  const result: { event?: string; data?: unknown } = {}
  for (const line of lines) {
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
  mockRedisInstance.subscribe.mockReset()
  mockRedisInstance.unsubscribe.mockReset()
  mockRedisInstance.on.mockReset()
  mockRedisInstance.quit.mockReset()
  mockRedisInstance.disconnect.mockReset()
  mockIoredisDefault.mockReset()

  mockRedisInstance.subscribe.mockResolvedValue(undefined)
  mockRedisInstance.quit.mockResolvedValue(undefined)
  function RedisMock(this: unknown) { return mockRedisInstance }
  mockIoredisDefault.mockImplementation(RedisMock)

  // Default: authenticated
  mockCookieStore = { cabinet_session: { value: 'sess_abc123' } }

  // Redis URL set by default
  process.env.REDIS_URL = 'redis://localhost:6379'
})

afterEach(() => {
  delete process.env.REDIS_URL
  vi.restoreAllMocks()
})

// ---------------------------------------------------------------------------
// Auth guard
// ---------------------------------------------------------------------------

describe('GET tasks/stream — auth guard', () => {
  it('returns 401 when cabinet_session cookie is absent', async () => {
    mockCookieStore = {}
    const res = await GET(makeReq())
    expect(res.status).toBe(401)
    const body = await res.json()
    expect(body.error).toBe('Unauthorized')
  })

  it('returns 401 when cabinet_session cookie value is undefined/empty', async () => {
    mockCookieStore = { cabinet_session: undefined }
    const res = await GET(makeReq())
    expect(res.status).toBe(401)
  })

  it('does NOT return 401 when session cookie is present', async () => {
    const res = await GET(makeReq())
    expect(res.status).not.toBe(401)
  })
})

// ---------------------------------------------------------------------------
// Response shape
// ---------------------------------------------------------------------------

describe('GET tasks/stream — response shape', () => {
  it('returns a Response with ReadableStream body', async () => {
    const res = await GET(makeReq())
    expect(res.body).toBeInstanceOf(ReadableStream)
  })

  it('Content-Type is text/event-stream', async () => {
    const res = await GET(makeReq())
    expect(res.headers.get('Content-Type')).toBe('text/event-stream')
  })

  it('Cache-Control contains no-cache', async () => {
    const res = await GET(makeReq())
    expect(res.headers.get('Cache-Control')).toContain('no-cache')
  })

  it('X-Accel-Buffering is no', async () => {
    const res = await GET(makeReq())
    expect(res.headers.get('X-Accel-Buffering')).toBe('no')
  })
})

// ---------------------------------------------------------------------------
// Initial connected event
// ---------------------------------------------------------------------------

describe('GET tasks/stream — initial connected event', () => {
  it('emits connected event as first frame with timestamp', async () => {
    const res = await GET(makeReq())
    const frames = await readFrames(res.body!, 1)
    expect(frames.length).toBeGreaterThan(0)
    const parsed = parseFrame(frames[0])
    expect(parsed.event).toBe('connected')
    expect((parsed.data as Record<string, unknown>).timestamp).toBeDefined()
  })

  it('connected event timestamp is an ISO string', async () => {
    const res = await GET(makeReq())
    const frames = await readFrames(res.body!, 1)
    const parsed = parseFrame(frames[0])
    const ts = (parsed.data as Record<string, unknown>).timestamp as string
    expect(() => new Date(ts)).not.toThrow()
    expect(new Date(ts).toISOString()).toBe(ts)
  })
})

// ---------------------------------------------------------------------------
// Redis Pub/Sub path
// ---------------------------------------------------------------------------

describe('GET tasks/stream — Redis Pub/Sub', () => {
  it('calls ioredis constructor with REDIS_URL when REDIS_URL is set', async () => {
    const res = await GET(makeReq())
    const { reader } = await startStreamAndFlush(res.body!)
    expect(mockIoredisDefault).toHaveBeenCalledWith(process.env.REDIS_URL)
    await reader.cancel()
  })

  it('calls sub.subscribe("cabinet:tasks:updated")', async () => {
    const res = await GET(makeReq())
    const { reader } = await startStreamAndFlush(res.body!)
    expect(mockRedisInstance.subscribe).toHaveBeenCalledWith('cabinet:tasks:updated')
    await reader.cancel()
  })

  it('registers message handler on sub', async () => {
    const res = await GET(makeReq())
    const { reader } = await startStreamAndFlush(res.body!)
    const registeredEvents = mockRedisInstance.on.mock.calls.map(c => c[0])
    expect(registeredEvents).toContain('message')
    await reader.cancel()
  })

  it('registers error handler on sub', async () => {
    const res = await GET(makeReq())
    const { reader } = await startStreamAndFlush(res.body!)
    const registeredEvents = mockRedisInstance.on.mock.calls.map(c => c[0])
    expect(registeredEvents).toContain('error')
    await reader.cancel()
  })

  it('message handler emits tasks:updated event with parsed officer_slug and timestamp', async () => {
    const res = await GET(makeReq())
    const decoder = new TextDecoder()
    const { reader } = await startStreamAndFlush(res.body!)

    // Simulate a Redis message
    const msgHandler = mockRedisInstance.on.mock.calls.find(c => c[0] === 'message')?.[1]
    expect(msgHandler).toBeDefined()

    const payload = JSON.stringify({ officer_slug: 'cos', timestamp: '2024-01-01T00:00:00.000Z' })
    msgHandler!('cabinet:tasks:updated', payload)

    const { value } = await reader.read()
    await reader.cancel()

    const frameText = decoder.decode(value)
    const parsed = parseFrame(frameText)
    expect(parsed.event).toBe('tasks:updated')
    const data = parsed.data as Record<string, unknown>
    expect(data.officer_slug).toBe('cos')
    expect(typeof data.timestamp).toBe('string')
  })

  it('message handler emits tasks:updated with just timestamp when payload is not a string', async () => {
    const res = await GET(makeReq())
    const decoder = new TextDecoder()
    const { reader } = await startStreamAndFlush(res.body!)

    const msgHandler = mockRedisInstance.on.mock.calls.find(c => c[0] === 'message')?.[1]
    // Pass a non-string message
    msgHandler!('cabinet:tasks:updated', 42)

    const { value } = await reader.read()
    await reader.cancel()

    const frameText = decoder.decode(value)
    const parsed = parseFrame(frameText)
    expect(parsed.event).toBe('tasks:updated')
    const data = parsed.data as Record<string, unknown>
    expect(data.officer_slug).toBeUndefined()
    expect(typeof data.timestamp).toBe('string')
  })

  it('message handler emits tasks:updated with just timestamp when JSON.parse throws', async () => {
    const res = await GET(makeReq())
    const decoder = new TextDecoder()
    const { reader } = await startStreamAndFlush(res.body!)

    const msgHandler = mockRedisInstance.on.mock.calls.find(c => c[0] === 'message')?.[1]
    // Pass invalid JSON string
    msgHandler!('cabinet:tasks:updated', '{not-valid-json}')

    const { value } = await reader.read()
    await reader.cancel()

    const frameText = decoder.decode(value)
    const parsed = parseFrame(frameText)
    expect(parsed.event).toBe('tasks:updated')
    const data = parsed.data as Record<string, unknown>
    expect(typeof data.timestamp).toBe('string')
  })

  it('subscribe reject triggers cleanup (unsubscribe called)', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    // Make subscribe reject
    mockRedisInstance.subscribe.mockRejectedValueOnce(new Error('subscribe failed'))
    const res = await GET(makeReq())
    const { reader } = await startStreamAndFlush(res.body!)
    // Allow the rejected promise to settle
    await flushMicrotasks(5)
    expect(mockRedisInstance.unsubscribe).toHaveBeenCalled()
    await reader.cancel()
    warnSpy.mockRestore()
  })

  it('error event triggers cleanup (unsubscribe called)', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const res = await GET(makeReq())
    const { reader } = await startStreamAndFlush(res.body!)

    // Trigger error handler
    const errorHandler = mockRedisInstance.on.mock.calls.find(c => c[0] === 'error')?.[1]
    expect(errorHandler).toBeDefined()
    errorHandler!(new Error('Redis connection dropped'))

    // Allow cleanup to settle
    await flushMicrotasks(3)
    expect(mockRedisInstance.unsubscribe).toHaveBeenCalled()

    await reader.cancel()
    warnSpy.mockRestore()
  })
})

// ---------------------------------------------------------------------------
// Polling fallback
// ---------------------------------------------------------------------------

describe('GET tasks/stream — polling fallback', () => {
  it('does NOT call ioredis when REDIS_URL is unset', async () => {
    delete process.env.REDIS_URL
    const res = await GET(makeReq())
    const { reader } = await startStreamAndFlush(res.body!)
    expect(mockIoredisDefault).not.toHaveBeenCalled()
    await reader.cancel()
  })

  it('does NOT subscribe when REDIS_URL is unset', async () => {
    delete process.env.REDIS_URL
    const res = await GET(makeReq())
    const { reader } = await startStreamAndFlush(res.body!)
    expect(mockRedisInstance.subscribe).not.toHaveBeenCalled()
    await reader.cancel()
  })

  it('does NOT subscribe when ioredis import throws', async () => {
    function ThrowingMock(this: unknown): never { throw new Error('module not found') }
    mockIoredisDefault.mockImplementationOnce(ThrowingMock)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const res = await GET(makeReq())
    const { reader } = await startStreamAndFlush(res.body!)
    expect(mockRedisInstance.subscribe).not.toHaveBeenCalled()
    await reader.cancel()
    warnSpy.mockRestore()
  })
})

// ---------------------------------------------------------------------------
// AbortSignal cleanup
// ---------------------------------------------------------------------------

describe('GET tasks/stream — AbortSignal cleanup', () => {
  it('calls unsubscribe on client disconnect (abort signal)', async () => {
    const { req, controller } = makeAbortableReq()
    const res = await GET(req)
    const { reader } = await startStreamAndFlush(res.body!)

    // Abort the request (simulates client disconnect)
    controller.abort()

    // Allow abort handler to settle
    await flushMicrotasks(3)
    expect(mockRedisInstance.unsubscribe).toHaveBeenCalled()

    await reader.cancel()
  })
})

// ---------------------------------------------------------------------------
// Keep-alive setup
// ---------------------------------------------------------------------------

describe('GET tasks/stream — keep-alive', () => {
  it('stream start does not immediately emit a keep-alive ping (only connected event initially)', async () => {
    const res = await GET(makeReq())
    const frames = await readFrames(res.body!, 1)
    // The first frame should be the connected event, not a raw SSE comment
    const first = frames[0]
    expect(first).toContain('event: connected')
    expect(first).not.toBe(':\n\n')
  })
})
