// POST|GET /api/telegram/provisioning-webhook — Spec 034 PR 4 harness
//
// Scope: GET health-check, POST feature-flag guard, JSON parse failures,
//   non-message update silently ACK'd, Captain-auth guard (configured vs. not,
//   wrong vs. right chatId), rawText extraction (text/caption/both/empty),
//   token-redaction in console.log, handleMessage dispatch, sendReplies
//   (first with replyTo, additional chained), sendTelegramMessage internals
//   (missing token, fetch !ok, fetch throws, text > 4096 truncation),
//   loadState post-dispatch → polling loop fire-and-forget, handleMessage throws,
//   always-200 invariant.
//
// Mock strategy: vi.hoisted for guard/flow modules and global.fetch.
//   featureFlagCheck is a plain function — mocked via @/lib/provisioning/guard.
//   handleMessage / startPollingLoop / loadState from @/lib/provisioning/flow.
//   global.fetch replaced per-test.

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import type { NextRequest } from 'next/server'

// ---------------------------------------------------------------------------
// Hoisted mocks
// ---------------------------------------------------------------------------

const {
  mockFeatureFlagCheck,
  mockHandleMessage,
  mockStartPollingLoop,
  mockLoadState,
} = vi.hoisted(() => ({
  mockFeatureFlagCheck: vi.fn(),
  mockHandleMessage: vi.fn(),
  mockStartPollingLoop: vi.fn(),
  mockLoadState: vi.fn(),
}))

vi.mock('@/lib/provisioning/guard', () => ({
  featureFlagCheck: mockFeatureFlagCheck,
}))

vi.mock('@/lib/provisioning/flow', () => ({
  handleMessage: mockHandleMessage,
  startPollingLoop: mockStartPollingLoop,
  loadState: mockLoadState,
}))

import { GET, POST } from './route'

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const fetchMock = vi.fn()
global.fetch = fetchMock as unknown as typeof fetch

const CAPTAIN_CHAT_ID = '123456789'
const CAPTAIN_CHAT_ID_NUM = 123456789

function setEnv(overrides: Record<string, string | undefined>) {
  for (const [k, v] of Object.entries(overrides)) {
    if (v === undefined) {
      delete process.env[k]
    } else {
      process.env[k] = v
    }
  }
}

function makeUpdate(overrides: {
  chatId?: number
  messageId?: number
  text?: string
  caption?: string
  forwardFrom?: object
  noMessage?: boolean
  callbackQuery?: boolean
}): object {
  if (overrides.noMessage) {
    return { update_id: 1 }
  }
  if (overrides.callbackQuery) {
    return { update_id: 1, callback_query: { id: 'cq1', data: 'test' } }
  }
  const msg: Record<string, unknown> = {
    message_id: overrides.messageId ?? 42,
    chat: { id: overrides.chatId ?? CAPTAIN_CHAT_ID_NUM, type: 'private' },
    from: { id: overrides.chatId ?? CAPTAIN_CHAT_ID_NUM, first_name: 'Nate' },
    date: 1700000000,
  }
  if (overrides.text !== undefined) msg.text = overrides.text
  if (overrides.caption !== undefined) msg.caption = overrides.caption
  if (overrides.forwardFrom !== undefined) msg.forward_from = overrides.forwardFrom
  return { update_id: 1, message: msg }
}

function makeReq(body: unknown, throwOnJson = false): NextRequest {
  return {
    json: throwOnJson
      ? async () => { throw new SyntaxError('Bad JSON') }
      : async () => body,
  } as unknown as NextRequest
}

// ---------------------------------------------------------------------------
// Default setup
// ---------------------------------------------------------------------------

beforeEach(() => {
  mockFeatureFlagCheck.mockReset()
  mockHandleMessage.mockReset()
  mockStartPollingLoop.mockReset()
  mockLoadState.mockReset()
  fetchMock.mockReset()

  // Feature flag enabled by default
  mockFeatureFlagCheck.mockReturnValue(null)
  // handleMessage returns empty replies by default
  mockHandleMessage.mockResolvedValue([])
  // loadState returns null by default (no polling loop)
  mockLoadState.mockResolvedValue(null)
  // startPollingLoop resolves immediately
  mockStartPollingLoop.mockResolvedValue(undefined)
  // fetch succeeds by default
  fetchMock.mockResolvedValue({ ok: true, text: async () => 'ok' })

  setEnv({
    CAPTAIN_TELEGRAM_CHAT_ID: CAPTAIN_CHAT_ID,
    MANAGER_BOT_TOKEN: 'bot_token_abc',
  })
})

afterEach(() => {
  vi.restoreAllMocks()
})

// ---------------------------------------------------------------------------
// GET — health check
// ---------------------------------------------------------------------------

describe('GET provisioning-webhook', () => {
  it('returns 200 with endpoint metadata', async () => {
    const res = await GET()
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body.ok).toBe(true)
    expect(body.endpoint).toBe('provisioning-webhook')
    expect(typeof body.note).toBe('string')
  })
})

// ---------------------------------------------------------------------------
// POST — feature flag
// ---------------------------------------------------------------------------

describe('POST provisioning-webhook — feature flag', () => {
  it('returns flagResponse (503) when feature flag disabled', async () => {
    const { NextResponse } = await import('next/server')
    const flagResp = NextResponse.json({ ok: false, disabled: true }, { status: 503 })
    mockFeatureFlagCheck.mockReturnValueOnce(flagResp)
    const res = await POST(makeReq({ update_id: 1 }))
    expect(res.status).toBe(503)
    expect(mockHandleMessage).not.toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// POST — JSON parsing
// ---------------------------------------------------------------------------

describe('POST provisioning-webhook — JSON parsing', () => {
  it('returns 200 {ok:true} on invalid JSON (silent drop, no sendMessage)', async () => {
    const res = await POST(makeReq(null, true))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ ok: true })
    expect(fetchMock).not.toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// POST — non-message update
// ---------------------------------------------------------------------------

describe('POST provisioning-webhook — non-message updates', () => {
  it('returns 200 ACK on update without message field', async () => {
    const res = await POST(makeReq(makeUpdate({ noMessage: true })))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ ok: true })
    expect(mockHandleMessage).not.toHaveBeenCalled()
  })

  it('returns 200 ACK on callback_query update (no message key)', async () => {
    const res = await POST(makeReq(makeUpdate({ callbackQuery: true })))
    expect(res.status).toBe(200)
    expect(mockHandleMessage).not.toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// POST — Captain auth guard
// ---------------------------------------------------------------------------

describe('POST provisioning-webhook — Captain auth guard', () => {
  it('returns 200 + no sendMessage when CAPTAIN_TELEGRAM_CHAT_ID not set', async () => {
    setEnv({ CAPTAIN_TELEGRAM_CHAT_ID: undefined })
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const res = await POST(makeReq(makeUpdate({ text: 'hello' })))
    expect(res.status).toBe(200)
    expect(fetchMock).not.toHaveBeenCalled()
    expect(mockHandleMessage).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('console.warn emitted when CAPTAIN_TELEGRAM_CHAT_ID not set', async () => {
    setEnv({ CAPTAIN_TELEGRAM_CHAT_ID: undefined })
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    await POST(makeReq(makeUpdate({ text: 'hello' })))
    expect(warnSpy).toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('returns 200 + console.warn + no sendMessage for wrong chatId', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const res = await POST(makeReq(makeUpdate({ chatId: 999999999, text: 'hello' })))
    expect(res.status).toBe(200)
    expect(fetchMock).not.toHaveBeenCalled()
    expect(mockHandleMessage).not.toHaveBeenCalled()
    expect(warnSpy).toHaveBeenCalled()
    warnSpy.mockRestore()
  })

  it('proceeds past auth for correct chatId', async () => {
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'hello' })))
    expect(mockHandleMessage).toHaveBeenCalled()
  })
})

// ---------------------------------------------------------------------------
// POST — rawText extraction
// ---------------------------------------------------------------------------

describe('POST provisioning-webhook — rawText extraction', () => {
  it('returns 200, no dispatch when message has no text and no caption', async () => {
    const res = await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM })))
    expect(res.status).toBe(200)
    expect(mockHandleMessage).not.toHaveBeenCalled()
  })

  it('returns 200, no dispatch when text is whitespace-only', async () => {
    const res = await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: '   ' })))
    expect(res.status).toBe(200)
    expect(mockHandleMessage).not.toHaveBeenCalled()
  })

  it('uses text field as rawText', async () => {
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'provision me' })))
    expect(mockHandleMessage).toHaveBeenCalledWith(
      String(CAPTAIN_CHAT_ID_NUM),
      'provision me'
    )
  })

  it('uses caption as rawText when text is absent', async () => {
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, caption: 'forwarded caption' })))
    expect(mockHandleMessage).toHaveBeenCalledWith(
      String(CAPTAIN_CHAT_ID_NUM),
      'forwarded caption'
    )
  })

  it('text takes precedence over caption when both present', async () => {
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'real text', caption: 'caption text' })))
    expect(mockHandleMessage).toHaveBeenCalledWith(
      String(CAPTAIN_CHAT_ID_NUM),
      'real text'
    )
  })
})

// ---------------------------------------------------------------------------
// POST — token redaction in console.log
// ---------------------------------------------------------------------------

describe('POST provisioning-webhook — token redaction', () => {
  it('logs [TOKEN_REDACTED] for token-shaped substring in message text', async () => {
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {})
    const tokenLike = '12345678:ABCDEFGHIJabcdefghij_-1234567890123'
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: tokenLike })))
    const logCalls = logSpy.mock.calls.map(c => c.join(' '))
    expect(logCalls.some(msg => msg.includes('[TOKEN_REDACTED]'))).toBe(true)
    expect(logCalls.some(msg => msg.includes('ABCDEFGHIJabcdefghij'))).toBe(false)
    logSpy.mockRestore()
  })

  it('token redaction: exactly 8 digits + colon + 35-char secret matches', async () => {
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {})
    // Minimum bound: 8 digits + 35-char secret
    const edgeToken = '12345678:' + 'A'.repeat(35)
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: edgeToken })))
    const logCalls = logSpy.mock.calls.map(c => c.join(' '))
    expect(logCalls.some(msg => msg.includes('[TOKEN_REDACTED]'))).toBe(true)
    logSpy.mockRestore()
  })

  it('does NOT redact plain text without token-shaped substring', async () => {
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {})
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'just normal text' })))
    const logCalls = logSpy.mock.calls.map(c => c.join(' '))
    expect(logCalls.some(msg => msg.includes('[TOKEN_REDACTED]'))).toBe(false)
    logSpy.mockRestore()
  })
})

// ---------------------------------------------------------------------------
// POST — handleMessage dispatch and replies
// ---------------------------------------------------------------------------

describe('POST provisioning-webhook — handleMessage dispatch', () => {
  it('calls handleMessage with String(chatId) and rawText', async () => {
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'hello bot', messageId: 77 })))
    expect(mockHandleMessage).toHaveBeenCalledWith(String(CAPTAIN_CHAT_ID_NUM), 'hello bot')
  })

  it('calls fetch with correct Telegram sendMessage URL for first reply', async () => {
    mockHandleMessage.mockResolvedValueOnce([{ text: 'Reply from bot' }])
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'go', messageId: 42 })))
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0]
    expect(url).toContain('sendMessage')
    expect(url).toContain('bot_token_abc')
    const parsedBody = JSON.parse(init.body as string)
    expect(parsedBody.chat_id).toBe(CAPTAIN_CHAT_ID_NUM)
    expect(parsedBody.text).toBe('Reply from bot')
    expect(parsedBody.reply_to_message_id).toBe(42)
  })

  it('first reply threads with replyToMessageId; subsequent replies have no reply_to', async () => {
    mockHandleMessage.mockResolvedValueOnce([
      { text: 'First reply' },
      { text: 'Second reply' },
    ])
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'go', messageId: 55 })))
    expect(fetchMock).toHaveBeenCalledTimes(2)
    const firstBody = JSON.parse(fetchMock.mock.calls[0][1].body)
    const secondBody = JSON.parse(fetchMock.mock.calls[1][1].body)
    expect(firstBody.reply_to_message_id).toBe(55)
    expect(secondBody.reply_to_message_id).toBeUndefined()
  })

  it('sends additional chained messages on a reply', async () => {
    mockHandleMessage.mockResolvedValueOnce([
      {
        text: 'Main reply',
        additional: [{ text: 'Chained 1' }, { text: 'Chained 2' }],
      },
    ])
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'multi', messageId: 10 })))
    // First reply + 2 additional = 3 fetch calls
    expect(fetchMock).toHaveBeenCalledTimes(3)
  })

  it('no fetch call when replies array is empty', async () => {
    mockHandleMessage.mockResolvedValueOnce([])
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'hi' })))
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('sends generic error reply when handleMessage throws', async () => {
    mockHandleMessage.mockRejectedValueOnce(new Error('state machine exploded'))
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const res = await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'crash' })))
    expect(res.status).toBe(200)
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const body = JSON.parse(fetchMock.mock.calls[0][1].body)
    expect(body.text).toMatch(/wrong|cancel/i)
    errorSpy.mockRestore()
  })

  it('still returns 200 when handleMessage throws', async () => {
    mockHandleMessage.mockRejectedValueOnce(new Error('boom'))
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const res = await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'crash' })))
    expect(res.status).toBe(200)
    errorSpy.mockRestore()
  })
})

// ---------------------------------------------------------------------------
// POST — sendTelegramMessage internals
// ---------------------------------------------------------------------------

describe('POST provisioning-webhook — sendTelegramMessage internals', () => {
  it('logs error and skips fetch when MANAGER_BOT_TOKEN not set', async () => {
    setEnv({ MANAGER_BOT_TOKEN: undefined })
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockHandleMessage.mockResolvedValueOnce([{ text: 'some reply' }])
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'hi' })))
    expect(fetchMock).not.toHaveBeenCalled()
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })

  it('logs error when fetch response is not ok', async () => {
    fetchMock.mockResolvedValueOnce({ ok: false, text: async () => 'Bad Request' })
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockHandleMessage.mockResolvedValueOnce([{ text: 'reply' }])
    const res = await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'hi' })))
    expect(res.status).toBe(200)
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })

  it('logs error when fetch throws', async () => {
    fetchMock.mockRejectedValueOnce(new Error('ECONNREFUSED'))
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockHandleMessage.mockResolvedValueOnce([{ text: 'reply' }])
    const res = await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'hi' })))
    expect(res.status).toBe(200)
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })

  it('truncates text longer than 4096 chars to 4093 + ellipsis', async () => {
    const longText = 'x'.repeat(5000)
    mockHandleMessage.mockResolvedValueOnce([{ text: longText }])
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'trigger' })))
    const sentBody = JSON.parse(fetchMock.mock.calls[0][1].body)
    expect(sentBody.text.length).toBe(4094) // 4093 + 1 for '…' (1 char)
    expect(sentBody.text.endsWith('…')).toBe(true)
  })

  it('does NOT truncate text of exactly 4096 chars', async () => {
    const exactText = 'y'.repeat(4096)
    mockHandleMessage.mockResolvedValueOnce([{ text: exactText }])
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'trigger' })))
    const sentBody = JSON.parse(fetchMock.mock.calls[0][1].body)
    expect(sentBody.text.length).toBe(4096)
    expect(sentBody.text.endsWith('…')).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// POST — polling loop fire-and-forget
// ---------------------------------------------------------------------------

describe('POST provisioning-webhook — polling loop', () => {
  it('does not call startPollingLoop when loadState returns null', async () => {
    mockHandleMessage.mockResolvedValueOnce([])
    mockLoadState.mockResolvedValueOnce(null)
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'hi' })))
    expect(mockStartPollingLoop).not.toHaveBeenCalled()
  })

  it('does not call startPollingLoop when step != polling_status', async () => {
    mockHandleMessage.mockResolvedValueOnce([])
    mockLoadState.mockResolvedValueOnce({ step: 'adopting_bot', cabinetId: 'cab_abc' })
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'hi' })))
    expect(mockStartPollingLoop).not.toHaveBeenCalled()
  })

  it('does not call startPollingLoop when step=polling_status but cabinetId is null', async () => {
    mockHandleMessage.mockResolvedValueOnce([])
    mockLoadState.mockResolvedValueOnce({ step: 'polling_status', cabinetId: null })
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'hi' })))
    expect(mockStartPollingLoop).not.toHaveBeenCalled()
  })

  it('calls startPollingLoop with chatId/state/callback when step=polling_status + cabinetId set', async () => {
    const state = { step: 'polling_status', cabinetId: 'cab_xyz' }
    mockHandleMessage.mockResolvedValueOnce([])
    mockLoadState.mockResolvedValueOnce(state)
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'all bots adopted' })))
    expect(mockStartPollingLoop).toHaveBeenCalledWith(
      String(CAPTAIN_CHAT_ID_NUM),
      state,
      expect.any(Function)
    )
  })

  it('still returns 200 when startPollingLoop rejects (fire-and-forget catch)', async () => {
    const state = { step: 'polling_status', cabinetId: 'cab_xyz' }
    mockHandleMessage.mockResolvedValueOnce([])
    mockLoadState.mockResolvedValueOnce(state)
    mockStartPollingLoop.mockRejectedValueOnce(new Error('polling exploded'))
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const res = await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'go' })))
    expect(res.status).toBe(200)
    errorSpy.mockRestore()
  })

  it('polling callback calls sendTelegramMessage (fetch) with message text', async () => {
    const state = { step: 'polling_status', cabinetId: 'cab_xyz' }
    mockHandleMessage.mockResolvedValueOnce([])
    mockLoadState.mockResolvedValueOnce(state)
    await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'go' })))
    // Retrieve the callback passed to startPollingLoop and call it
    const callback = mockStartPollingLoop.mock.calls[0][2] as (msg: { text: string }) => Promise<void>
    await callback({ text: 'Cabinet is live!' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const sentBody = JSON.parse(fetchMock.mock.calls[0][1].body)
    expect(sentBody.text).toBe('Cabinet is live!')
    expect(sentBody.chat_id).toBe(CAPTAIN_CHAT_ID_NUM)
  })
})

// ---------------------------------------------------------------------------
// POST — always-200 invariant
// ---------------------------------------------------------------------------

describe('POST provisioning-webhook — always-200', () => {
  it('returns 200 even on complete internal failure cascade', async () => {
    mockHandleMessage.mockRejectedValueOnce(new Error('catastrophic'))
    fetchMock.mockRejectedValueOnce(new Error('network down'))
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const res = await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'go' })))
    expect(res.status).toBe(200)
    errorSpy.mockRestore()
  })

  it('response body always contains {ok: true}', async () => {
    const res = await POST(makeReq(makeUpdate({ chatId: CAPTAIN_CHAT_ID_NUM, text: 'hi' })))
    const body = await res.json()
    expect(body.ok).toBe(true)
  })
})
