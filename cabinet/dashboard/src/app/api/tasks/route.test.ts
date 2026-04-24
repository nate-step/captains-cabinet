// GET + POST /api/tasks — all-boards list + task creation route harness.
//
// Mocks @/lib/tasks (preserving real WipCapExceededError class via
// vi.importActual so `err instanceof WipCapExceededError` survives the mock),
// @/lib/linear-tasks, and node:fs/promises for the resolveActiveContext
// fallback.
//
// Coverage:
//   GET
//     - query ?context= bypasses env + file fallback
//     - CABINET_CONTEXT env wins over file fallback (no query)
//     - active-project.txt fallback when no query + no env
//     - empty active-project.txt → 500 (error path)
//     - response shape {boards, captain, context_slug}
//     - Promise.all parallelism (both fetches triggered)
//     - 500 when getAllOfficerBoards throws
//     - 500 when getLinearFounderActions throws
//   POST
//     - 400 missing/empty officer_slug
//     - 400 missing/empty title
//     - 400 missing / invalid action
//     - 201 startTask for action=start
//     - 201 queueTask for action=queue
//     - options pass-through: linked_url/linked_kind/linked_id/context_slug
//     - WipCapExceededError thrown → 409 {error, current_wip_count, cap, titles}
//     - PG errcode 23514 coerced via coerceWipCapError → 409 w/ real slug (not '?')
//     - app-level WipCapExceededError: coerce NOT called (instanceof short-circuit)
//     - context_slug required / not found → 400
//     - context_slug invalid → 503 (should not happen — CLI validates)
//     - generic error → 500 with error message
//     - body-parse throw → 500

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import type { NextRequest } from 'next/server'

const {
  mockGetAllOfficerBoards,
  mockStartTask,
  mockQueueTask,
  mockCoerce,
  mockGetLinearFounderActions,
  mockReadFile,
} = vi.hoisted(() => ({
  mockGetAllOfficerBoards: vi.fn(),
  mockStartTask: vi.fn(),
  mockQueueTask: vi.fn(),
  mockCoerce: vi.fn(),
  mockGetLinearFounderActions: vi.fn(),
  mockReadFile: vi.fn(),
}))

// Keep the real WipCapExceededError class so handler's `instanceof` works.
vi.mock('@/lib/tasks', async () => {
  const actual = await vi.importActual<typeof import('@/lib/tasks')>('@/lib/tasks')
  return {
    ...actual,
    getAllOfficerBoards: mockGetAllOfficerBoards,
    startTask: mockStartTask,
    queueTask: mockQueueTask,
    coerceWipCapError: mockCoerce,
  }
})

vi.mock('@/lib/linear-tasks', () => ({
  getLinearFounderActions: mockGetLinearFounderActions,
}))

vi.mock('node:fs/promises', () => ({
  readFile: mockReadFile,
}))

// Import real class AFTER mocks so tests can `throw new WipCapExceededError(...)`.
import { WipCapExceededError } from '@/lib/tasks'
import { GET, POST } from './route'

function makeGetReq(url: string): NextRequest {
  return { url } as unknown as NextRequest
}

function makePostReq(body: unknown): NextRequest {
  return {
    json: async () => body,
  } as unknown as NextRequest
}

beforeEach(() => {
  mockGetAllOfficerBoards.mockReset()
  mockStartTask.mockReset()
  mockQueueTask.mockReset()
  mockCoerce.mockReset()
  mockGetLinearFounderActions.mockReset()
  mockReadFile.mockReset()
  delete process.env.CABINET_CONTEXT
  delete process.env.CABINET_ROOT
})

afterEach(() => {
  delete process.env.CABINET_CONTEXT
  delete process.env.CABINET_ROOT
})

describe('GET /api/tasks — context resolution', () => {
  it('uses ?context= query param when provided (no env, no file read)', async () => {
    mockGetAllOfficerBoards.mockResolvedValueOnce([])
    mockGetLinearFounderActions.mockResolvedValueOnce({ items: [] })
    const res = await GET(makeGetReq('http://localhost/api/tasks?context=from-query'))
    expect(res.status).toBe(200)
    expect(mockReadFile).not.toHaveBeenCalled()
    expect(mockGetAllOfficerBoards).toHaveBeenCalledWith('from-query')
    const body = await res.json()
    expect(body.context_slug).toBe('from-query')
  })

  it('trims query param whitespace', async () => {
    mockGetAllOfficerBoards.mockResolvedValueOnce([])
    mockGetLinearFounderActions.mockResolvedValueOnce({ items: [] })
    await GET(makeGetReq('http://localhost/api/tasks?context=%20%20spaced%20%20'))
    expect(mockGetAllOfficerBoards).toHaveBeenCalledWith('spaced')
  })

  it('falls back to CABINET_CONTEXT env when query empty', async () => {
    process.env.CABINET_CONTEXT = 'from-env'
    mockGetAllOfficerBoards.mockResolvedValueOnce([])
    mockGetLinearFounderActions.mockResolvedValueOnce({ items: [] })
    await GET(makeGetReq('http://localhost/api/tasks'))
    expect(mockReadFile).not.toHaveBeenCalled()
    expect(mockGetAllOfficerBoards).toHaveBeenCalledWith('from-env')
  })

  it('empty ?context= string falls through to env/file (trim drops it)', async () => {
    process.env.CABINET_CONTEXT = 'fallback'
    mockGetAllOfficerBoards.mockResolvedValueOnce([])
    mockGetLinearFounderActions.mockResolvedValueOnce({ items: [] })
    await GET(makeGetReq('http://localhost/api/tasks?context='))
    expect(mockGetAllOfficerBoards).toHaveBeenCalledWith('fallback')
  })

  it('falls back to active-project.txt when no query + no env', async () => {
    mockReadFile.mockResolvedValueOnce('from-file\n')
    mockGetAllOfficerBoards.mockResolvedValueOnce([])
    mockGetLinearFounderActions.mockResolvedValueOnce({ items: [] })
    await GET(makeGetReq('http://localhost/api/tasks'))
    expect(mockReadFile).toHaveBeenCalledTimes(1)
    expect(mockGetAllOfficerBoards).toHaveBeenCalledWith('from-file')
  })

  it('CABINET_ROOT env overrides default path for active-project.txt', async () => {
    process.env.CABINET_ROOT = '/custom/root'
    mockReadFile.mockResolvedValueOnce('slug')
    mockGetAllOfficerBoards.mockResolvedValueOnce([])
    mockGetLinearFounderActions.mockResolvedValueOnce({ items: [] })
    await GET(makeGetReq('http://localhost/api/tasks'))
    const pathArg = mockReadFile.mock.calls[0][0] as string
    expect(pathArg).toContain('/custom/root')
    expect(pathArg).toContain('instance/config/active-project.txt')
  })

  it('default /opt/founders-cabinet path when CABINET_ROOT unset', async () => {
    mockReadFile.mockResolvedValueOnce('slug')
    mockGetAllOfficerBoards.mockResolvedValueOnce([])
    mockGetLinearFounderActions.mockResolvedValueOnce({ items: [] })
    await GET(makeGetReq('http://localhost/api/tasks'))
    const pathArg = mockReadFile.mock.calls[0][0] as string
    expect(pathArg).toContain('/opt/founders-cabinet')
  })

  it('500 when active-project.txt is empty string', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockReadFile.mockResolvedValueOnce('   ')
    const res = await GET(makeGetReq('http://localhost/api/tasks'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to fetch tasks')
    spy.mockRestore()
  })
})

describe('GET /api/tasks — response shape', () => {
  it('returns {boards, captain, context_slug}', async () => {
    mockGetAllOfficerBoards.mockResolvedValueOnce([
      { slug: 'cto', tasks: [{ id: 1, title: 'x' }] },
    ])
    mockGetLinearFounderActions.mockResolvedValueOnce({
      items: [{ id: 'ABC-1', title: 'captain task' }],
    })
    const res = await GET(makeGetReq('http://localhost/api/tasks?context=test'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toHaveProperty('boards')
    expect(body).toHaveProperty('captain')
    expect(body).toHaveProperty('context_slug', 'test')
    expect(body.boards).toHaveLength(1)
    expect(body.captain.items).toHaveLength(1)
  })

  it('invokes both fetches (not sequential) for parallelism', async () => {
    let boardsResolved = false
    let linearResolved = false
    mockGetAllOfficerBoards.mockImplementationOnce(async () => {
      boardsResolved = true
      return []
    })
    mockGetLinearFounderActions.mockImplementationOnce(async () => {
      linearResolved = true
      return { items: [] }
    })
    await GET(makeGetReq('http://localhost/api/tasks?context=t'))
    expect(boardsResolved).toBe(true)
    expect(linearResolved).toBe(true)
  })
})

describe('GET /api/tasks — error paths (500)', () => {
  it('500 when getAllOfficerBoards rejects', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockGetAllOfficerBoards.mockRejectedValueOnce(new Error('pg down'))
    mockGetLinearFounderActions.mockResolvedValueOnce({ items: [] })
    const res = await GET(makeGetReq('http://localhost/api/tasks?context=t'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to fetch tasks')
    spy.mockRestore()
  })

  it('500 when getLinearFounderActions rejects', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockGetAllOfficerBoards.mockResolvedValueOnce([])
    mockGetLinearFounderActions.mockRejectedValueOnce(new Error('linear 429'))
    const res = await GET(makeGetReq('http://localhost/api/tasks?context=t'))
    expect(res.status).toBe(500)
    spy.mockRestore()
  })

  it('500 does not leak internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockGetAllOfficerBoards.mockRejectedValueOnce(new Error('secret: tok=xoxp-hidden'))
    mockGetLinearFounderActions.mockResolvedValueOnce({ items: [] })
    const res = await GET(makeGetReq('http://localhost/api/tasks?context=t'))
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('xoxp-hidden')
    expect(body.error).toBe('Failed to fetch tasks')
    spy.mockRestore()
  })
})

describe('POST /api/tasks — body validation (400)', () => {
  it('400 when officer_slug missing', async () => {
    const res = await POST(makePostReq({ title: 't', action: 'start' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toBe('officer_slug is required')
  })

  it('400 when officer_slug is empty string', async () => {
    const res = await POST(makePostReq({ officer_slug: '', title: 't', action: 'start' }))
    expect(res.status).toBe(400)
  })

  it('400 when officer_slug is whitespace only', async () => {
    const res = await POST(
      makePostReq({ officer_slug: '   ', title: 't', action: 'start' })
    )
    expect(res.status).toBe(400)
    expect(mockStartTask).not.toHaveBeenCalled()
  })

  it('400 when title missing', async () => {
    const res = await POST(makePostReq({ officer_slug: 'cto', action: 'start' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toBe('title is required')
  })

  it('400 when title is whitespace only', async () => {
    const res = await POST(
      makePostReq({ officer_slug: 'cto', title: '   ', action: 'start' })
    )
    expect(res.status).toBe(400)
  })

  it('400 when action missing', async () => {
    const res = await POST(makePostReq({ officer_slug: 'cto', title: 't' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toContain('action must be')
  })

  it('400 when action is neither "start" nor "queue"', async () => {
    const res = await POST(
      makePostReq({ officer_slug: 'cto', title: 't', action: 'bogus' })
    )
    expect(res.status).toBe(400)
    expect(mockStartTask).not.toHaveBeenCalled()
    expect(mockQueueTask).not.toHaveBeenCalled()
  })
})

describe('POST /api/tasks — dispatch (201)', () => {
  it('action=start calls startTask and returns 201 with task', async () => {
    mockStartTask.mockResolvedValueOnce({ id: 42, title: 't', status: 'wip' })
    const res = await POST(
      makePostReq({ officer_slug: 'cto', title: 't', action: 'start' })
    )
    expect(res.status).toBe(201)
    const body = await res.json()
    expect(body.task).toEqual({ id: 42, title: 't', status: 'wip' })
    expect(mockStartTask).toHaveBeenCalledTimes(1)
    expect(mockQueueTask).not.toHaveBeenCalled()
  })

  it('action=queue calls queueTask and returns 201 with task', async () => {
    mockQueueTask.mockResolvedValueOnce({ id: 43, title: 'q', status: 'queued' })
    const res = await POST(
      makePostReq({ officer_slug: 'cto', title: 'q', action: 'queue' })
    )
    expect(res.status).toBe(201)
    expect(mockQueueTask).toHaveBeenCalledTimes(1)
    expect(mockStartTask).not.toHaveBeenCalled()
  })

  it('passes officer_slug + title positional args', async () => {
    mockStartTask.mockResolvedValueOnce({ id: 1 })
    await POST(
      makePostReq({ officer_slug: 'cpo', title: 'work', action: 'start' })
    )
    expect(mockStartTask).toHaveBeenCalledWith('cpo', 'work', expect.any(Object))
  })

  it('passes opts object with linked_* and context_slug fields', async () => {
    mockStartTask.mockResolvedValueOnce({ id: 1 })
    await POST(
      makePostReq({
        officer_slug: 'cto',
        title: 't',
        action: 'start',
        linked_url: 'https://linear.app/ABC-1',
        linked_kind: 'linear',
        linked_id: 'ABC-1',
        context_slug: 'proj-a',
      })
    )
    expect(mockStartTask).toHaveBeenCalledWith('cto', 't', {
      linkedUrl: 'https://linear.app/ABC-1',
      linkedKind: 'linear',
      linkedId: 'ABC-1',
      contextSlug: 'proj-a',
    })
  })

  it('opts object populated with undefined when fields omitted', async () => {
    mockStartTask.mockResolvedValueOnce({ id: 1 })
    await POST(
      makePostReq({ officer_slug: 'cto', title: 't', action: 'start' })
    )
    expect(mockStartTask).toHaveBeenCalledWith('cto', 't', {
      linkedUrl: undefined,
      linkedKind: undefined,
      linkedId: undefined,
      contextSlug: undefined,
    })
  })
})

describe('POST /api/tasks — WIP cap (409, Spec 038 v1.2)', () => {
  it('app-level WipCapExceededError → 409 with real titles/cap/current', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockStartTask.mockRejectedValueOnce(
      new WipCapExceededError('cto', ['a', 'b', 'c'], 3)
    )
    const res = await POST(
      makePostReq({ officer_slug: 'cto', title: 'd', action: 'start' })
    )
    expect(res.status).toBe(409)
    const body = await res.json()
    expect(body).toEqual({
      error: 'wip-cap-exceeded',
      current_wip_count: 3,
      cap: 3,
      titles: ['a', 'b', 'c'],
    })
    spy.mockRestore()
  })

  it('app-level WipCapExceededError short-circuits coerce (instanceof check)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockStartTask.mockRejectedValueOnce(new WipCapExceededError('cto', ['x']))
    await POST(makePostReq({ officer_slug: 'cto', title: 't', action: 'start' }))
    expect(mockCoerce).not.toHaveBeenCalled()
    spy.mockRestore()
  })

  it('PG errcode 23514 coerced → 409 (hoisted officerSlug, not "?")', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const pgErr = Object.assign(new Error('WIP limit (3) exceeded'), { code: '23514' })
    mockStartTask.mockRejectedValueOnce(pgErr)
    mockCoerce.mockReturnValueOnce(new WipCapExceededError('cpo', [], 3))
    const res = await POST(
      makePostReq({ officer_slug: 'cpo', title: 't', action: 'start' })
    )
    expect(res.status).toBe(409)
    expect(mockCoerce).toHaveBeenCalledWith(pgErr, 'cpo')
    spy.mockRestore()
  })

  it('23514 but coerce returns null → falls through to 500', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const pgErr = Object.assign(new Error('some other 23514'), { code: '23514' })
    mockStartTask.mockRejectedValueOnce(pgErr)
    mockCoerce.mockReturnValueOnce(null)
    const res = await POST(
      makePostReq({ officer_slug: 'cto', title: 't', action: 'start' })
    )
    expect(res.status).toBe(500)
    spy.mockRestore()
  })

  it('coerce receives the actual officer_slug after title validation', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    // officer_slug captured BEFORE title validation so it's available in catch
    mockStartTask.mockRejectedValueOnce(Object.assign(new Error('e'), { code: '99999' }))
    mockCoerce.mockReturnValueOnce(null)
    await POST(
      makePostReq({ officer_slug: 'specific-officer', title: 't', action: 'start' })
    )
    expect(mockCoerce).toHaveBeenCalledWith(expect.anything(), 'specific-officer')
    spy.mockRestore()
  })
})

describe('POST /api/tasks — context_slug errors (400 / 503)', () => {
  it('context_slug is required → 400 (Spec 038 §4.8 caller misuse)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockStartTask.mockRejectedValueOnce(new Error('context_slug is required (AC #21)'))
    mockCoerce.mockReturnValueOnce(null)
    const res = await POST(
      makePostReq({ officer_slug: 'cto', title: 't', action: 'start' })
    )
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toContain('context_slug is required')
    spy.mockRestore()
  })

  it('context_slug not found → 400', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockStartTask.mockRejectedValueOnce(new Error("context_slug 'foo' not found in contexts/"))
    mockCoerce.mockReturnValueOnce(null)
    const res = await POST(
      makePostReq({ officer_slug: 'cto', title: 't', action: 'start' })
    )
    expect(res.status).toBe(400)
    spy.mockRestore()
  })

  it('context_slug invalid (regex) → 503 (shouldn\'t happen — CLI validates first)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockStartTask.mockRejectedValueOnce(new Error("context_slug '../evil' is invalid"))
    mockCoerce.mockReturnValueOnce(null)
    const res = await POST(
      makePostReq({ officer_slug: 'cto', title: 't', action: 'start' })
    )
    expect(res.status).toBe(503)
    spy.mockRestore()
  })
})

describe('POST /api/tasks — exception paths (500)', () => {
  it('generic error → 500 with message', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockStartTask.mockRejectedValueOnce(new Error('pg connection refused'))
    mockCoerce.mockReturnValueOnce(null)
    const res = await POST(
      makePostReq({ officer_slug: 'cto', title: 't', action: 'start' })
    )
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('pg connection refused')
    spy.mockRestore()
  })

  it('non-Error throw → 500 with "Unknown error"', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockStartTask.mockRejectedValueOnce('string thrown')
    mockCoerce.mockReturnValueOnce(null)
    const res = await POST(
      makePostReq({ officer_slug: 'cto', title: 't', action: 'start' })
    )
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Unknown error')
    spy.mockRestore()
  })

  it('body-parse throw (malformed JSON) → 500', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const badReq = {
      json: async () => {
        throw new SyntaxError('Unexpected token < in JSON')
      },
    } as unknown as NextRequest
    const res = await POST(badReq)
    expect(res.status).toBe(500)
    spy.mockRestore()
  })
})
