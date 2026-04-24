// GET/PATCH/DELETE /api/tasks/:id — route handler harness.
//
// Covers all 3 methods of the per-task endpoint (Spec 038 Phase A v1.2).
// The interesting path is PATCH's 038.5 wip-cap coercion: errors raised by
// the DB trigger (errcode 23514) are translated into the same 409 body as
// the app-level pre-check, using the officer_slug hoisted out of the try
// scope so the 409 body reports the real caller (not '?').
//
// Pattern inherited from status/route.test.ts (first route harness): vi.hoisted
// for the shared mock-fn pair, vi.mock('@/lib/tasks') stubs the DB boundary,
// minimal NextRequest + params-Promise. WipCapExceededError is imported as a
// REAL class (not mocked) so `err instanceof WipCapExceededError` in the
// handler works — coerceWipCapError is the mock'd factory we control.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { NextRequest } from 'next/server'

// Real class needed for instanceof check in the handler's catch.
// Cast loosely — we're injecting our own instances.
const realTasksMod = await import('@/lib/tasks')
const WipCapExceededError = realTasksMod.WipCapExceededError

const {
  mockGetTask,
  mockDoneTask,
  mockSetBlocked,
  mockCancelTask,
  mockUpdateTask,
  mockCoerce,
} = vi.hoisted(() => ({
  mockGetTask: vi.fn(),
  mockDoneTask: vi.fn(),
  mockSetBlocked: vi.fn(),
  mockCancelTask: vi.fn(),
  mockUpdateTask: vi.fn(),
  mockCoerce: vi.fn(),
}))

vi.mock('@/lib/tasks', async () => {
  // Keep the real WipCapExceededError class (handler uses instanceof).
  const actual = await vi.importActual<typeof import('@/lib/tasks')>('@/lib/tasks')
  return {
    ...actual,
    getTask: mockGetTask,
    doneTask: mockDoneTask,
    setBlocked: mockSetBlocked,
    cancelTask: mockCancelTask,
    updateTask: mockUpdateTask,
    coerceWipCapError: mockCoerce,
  }
})

import { GET, PATCH, DELETE } from './route'

function makeReq(body: unknown): NextRequest {
  return { json: async () => body } as unknown as NextRequest
}

function makeBadJsonReq(): NextRequest {
  return {
    json: async () => {
      throw new SyntaxError('bad json')
    },
  } as unknown as NextRequest
}

function makeParams(id: string) {
  return { params: Promise.resolve({ id }) }
}

beforeEach(() => {
  mockGetTask.mockReset()
  mockDoneTask.mockReset()
  mockSetBlocked.mockReset()
  mockCancelTask.mockReset()
  mockUpdateTask.mockReset()
  mockCoerce.mockReset()
  mockCoerce.mockReturnValue(null) // default: no coercion
})

const fakeTask = { id: 42, title: 'x', status: 'open' }

describe('GET /api/tasks/:id', () => {
  it('400 when id is not a number', async () => {
    const res = await GET(makeReq({}), makeParams('not-a-number'))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toBe('Invalid task id')
  })

  it('404 when getTask returns null', async () => {
    mockGetTask.mockResolvedValueOnce(null)
    const res = await GET(makeReq({}), makeParams('99'))
    expect(res.status).toBe(404)
    const body = await res.json()
    expect(body.error).toBe('Task not found')
  })

  it('200 with task when getTask returns a row', async () => {
    mockGetTask.mockResolvedValueOnce(fakeTask)
    const res = await GET(makeReq({}), makeParams('42'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ task: fakeTask })
  })

  it('500 when getTask throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockGetTask.mockRejectedValueOnce(new Error('pg down'))
    const res = await GET(makeReq({}), makeParams('42'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to fetch task')
    spy.mockRestore()
  })

  it('parseInt happily takes numeric id regardless of leading zeros', async () => {
    mockGetTask.mockResolvedValueOnce(fakeTask)
    await GET(makeReq({}), makeParams('0042'))
    expect(mockGetTask).toHaveBeenCalledWith(42)
  })
})

describe('PATCH /api/tasks/:id — validation (400)', () => {
  it('400 invalid task id', async () => {
    const res = await PATCH(makeReq({ action: 'done' }), makeParams('abc'))
    expect(res.status).toBe(400)
    expect((await res.json()).error).toBe('Invalid task id')
  })

  it('400 when action is missing', async () => {
    const res = await PATCH(makeReq({ officer_slug: 'cto' }), makeParams('42'))
    expect(res.status).toBe(400)
    expect((await res.json()).error).toBe('action is required')
  })

  it('400 when officer_slug is missing for done', async () => {
    const res = await PATCH(makeReq({ action: 'done' }), makeParams('42'))
    expect(res.status).toBe(400)
    expect((await res.json()).error).toContain('officer_slug required')
  })

  it('400 when officer_slug is missing for block', async () => {
    const res = await PATCH(makeReq({ action: 'block' }), makeParams('42'))
    expect(res.status).toBe(400)
  })

  it('400 when officer_slug is whitespace-only for cancel', async () => {
    const res = await PATCH(
      makeReq({ action: 'cancel', officer_slug: '   ' }),
      makeParams('42')
    )
    expect(res.status).toBe(400)
    expect((await res.json()).error).toContain('officer_slug required')
  })

  it('400 when block action has no blocked_reason', async () => {
    const res = await PATCH(
      makeReq({ action: 'block', officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(res.status).toBe(400)
    expect((await res.json()).error).toBe('blocked_reason is required')
  })

  it('400 when block has whitespace-only blocked_reason', async () => {
    const res = await PATCH(
      makeReq({ action: 'block', officer_slug: 'cto', blocked_reason: '  ' }),
      makeParams('42')
    )
    expect(res.status).toBe(400)
  })

  it('400 when update has no fields to update', async () => {
    const res = await PATCH(makeReq({ action: 'update' }), makeParams('42'))
    expect(res.status).toBe(400)
    expect((await res.json()).error).toBe('No fields to update')
  })

  it('400 on unknown action', async () => {
    const res = await PATCH(
      makeReq({ action: 'bogus', officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(res.status).toBe(400)
    expect((await res.json()).error).toContain('done')
    expect((await res.json().catch(() => null)) ?? {}).toBeDefined()
  })
})

describe('PATCH /api/tasks/:id — action dispatch', () => {
  it('done → calls doneTask(taskId, officer_slug) and returns task', async () => {
    mockDoneTask.mockResolvedValueOnce(fakeTask)
    const res = await PATCH(
      makeReq({ action: 'done', officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ task: fakeTask })
    expect(mockDoneTask).toHaveBeenCalledWith(42, 'cto')
  })

  it('block → setBlocked(taskId, slug, true, reason)', async () => {
    mockSetBlocked.mockResolvedValueOnce(fakeTask)
    await PATCH(
      makeReq({ action: 'block', officer_slug: 'cto', blocked_reason: 'waiting on X' }),
      makeParams('42')
    )
    expect(mockSetBlocked).toHaveBeenCalledWith(42, 'cto', true, 'waiting on X')
  })

  it('unblock → setBlocked(taskId, slug, false)', async () => {
    mockSetBlocked.mockResolvedValueOnce(fakeTask)
    await PATCH(
      makeReq({ action: 'unblock', officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(mockSetBlocked).toHaveBeenCalledWith(42, 'cto', false)
  })

  it('cancel → cancelTask(taskId, slug)', async () => {
    mockCancelTask.mockResolvedValueOnce(fakeTask)
    await PATCH(
      makeReq({ action: 'cancel', officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(mockCancelTask).toHaveBeenCalledWith(42, 'cto')
  })

  it('update (title only) → updateTask with just title field', async () => {
    mockUpdateTask.mockResolvedValueOnce(fakeTask)
    await PATCH(
      makeReq({ action: 'update', title: 'new' }),
      makeParams('42')
    )
    expect(mockUpdateTask).toHaveBeenCalledWith(42, { title: 'new' })
  })

  it('update does NOT require officer_slug (whitelisted-field edit)', async () => {
    mockUpdateTask.mockResolvedValueOnce(fakeTask)
    const res = await PATCH(
      makeReq({ action: 'update', description: 'd' }),
      makeParams('42')
    )
    expect(res.status).toBe(200)
  })

  it('update sends multiple fields through', async () => {
    mockUpdateTask.mockResolvedValueOnce(fakeTask)
    await PATCH(
      makeReq({
        action: 'update',
        title: 't',
        description: 'd',
        linked_url: 'u',
        linked_kind: 'k',
        linked_id: 'i',
      }),
      makeParams('42')
    )
    expect(mockUpdateTask).toHaveBeenCalledWith(42, {
      title: 't',
      description: 'd',
      linked_url: 'u',
      linked_kind: 'k',
      linked_id: 'i',
    })
  })

  it('update skips undefined fields entirely (vs empty string)', async () => {
    mockUpdateTask.mockResolvedValueOnce(fakeTask)
    // Empty string is NOT undefined — should pass through
    await PATCH(
      makeReq({ action: 'update', title: '', description: undefined }),
      makeParams('42')
    )
    expect(mockUpdateTask).toHaveBeenCalledWith(42, { title: '' })
  })
})

describe('PATCH /api/tasks/:id — wip-cap coercion (038.5)', () => {
  it('WipCapExceededError instance → 409 with wip-cap-exceeded body', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const wipErr = new WipCapExceededError('cto', ['Task A', 'Task B'])
    mockDoneTask.mockRejectedValueOnce(wipErr)
    const res = await PATCH(
      makeReq({ action: 'done', officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(res.status).toBe(409)
    const body = await res.json()
    expect(body).toEqual({
      error: 'wip-cap-exceeded',
      current_wip_count: 2,
      cap: 3,
      titles: ['Task A', 'Task B'],
    })
    // Instance branch should NOT call coerceWipCapError (short-circuits).
    expect(mockCoerce).not.toHaveBeenCalled()
    spy.mockRestore()
  })

  it('errcode 23514 coerced via coerceWipCapError → 409 using hoisted officerSlug', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const pgErr = { code: '23514', message: 'WIP limit (3) exceeded' }
    mockDoneTask.mockRejectedValueOnce(pgErr)
    // Coerce uses the officer_slug hoisted out of the try scope
    mockCoerce.mockReturnValueOnce(new WipCapExceededError('cpo', [], 3))
    const res = await PATCH(
      makeReq({ action: 'done', officer_slug: 'cpo' }),
      makeParams('42')
    )
    expect(res.status).toBe(409)
    expect(mockCoerce).toHaveBeenCalledWith(pgErr, 'cpo')
    spy.mockRestore()
  })

  it('coerce with titles → titles echoed in 409 body', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockDoneTask.mockRejectedValueOnce(new Error('23514ish'))
    mockCoerce.mockReturnValueOnce(
      new WipCapExceededError('cto', ['Write spec', 'Fix bug', 'Ship docs'])
    )
    const res = await PATCH(
      makeReq({ action: 'done', officer_slug: 'cto' }),
      makeParams('42')
    )
    const body = await res.json()
    expect(body.titles).toEqual(['Write spec', 'Fix bug', 'Ship docs'])
    expect(body.current_wip_count).toBe(3)
    spy.mockRestore()
  })
})

describe('PATCH /api/tasks/:id — error mapping', () => {
  it('error with "not found" in message → 404', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockDoneTask.mockRejectedValueOnce(new Error('Task 42 not found'))
    const res = await PATCH(
      makeReq({ action: 'done', officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(res.status).toBe(404)
    expect((await res.json()).error).toBe('Task 42 not found')
    spy.mockRestore()
  })

  it('generic error → 500 with error message', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockDoneTask.mockRejectedValueOnce(new Error('database connection refused'))
    const res = await PATCH(
      makeReq({ action: 'done', officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(res.status).toBe(500)
    expect((await res.json()).error).toBe('database connection refused')
    spy.mockRestore()
  })

  it('non-Error thrown value → 500 with "Unknown error"', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockDoneTask.mockRejectedValueOnce('string thrown')
    const res = await PATCH(
      makeReq({ action: 'done', officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(res.status).toBe(500)
    expect((await res.json()).error).toBe('Unknown error')
    spy.mockRestore()
  })

  it('req.json() throws → 500 (json parse fails before action dispatch)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const res = await PATCH(makeBadJsonReq(), makeParams('42'))
    expect(res.status).toBe(500)
    spy.mockRestore()
  })
})

describe('DELETE /api/tasks/:id', () => {
  it('400 when id is not a number', async () => {
    const res = await DELETE(makeReq({ officer_slug: 'cto' }), makeParams('xyz'))
    expect(res.status).toBe(400)
    expect((await res.json()).error).toBe('Invalid task id')
  })

  it('400 when officer_slug is missing', async () => {
    const res = await DELETE(makeReq({}), makeParams('42'))
    expect(res.status).toBe(400)
    expect((await res.json()).error).toBe('officer_slug required')
  })

  it('body parse error swallowed → body treated as empty object → 400 on missing officer_slug', async () => {
    // Handler does `.catch(() => ({}))` on req.json for DELETE specifically
    const res = await DELETE(makeBadJsonReq(), makeParams('42'))
    expect(res.status).toBe(400)
    expect((await res.json()).error).toBe('officer_slug required')
  })

  it('200 with task on success', async () => {
    mockCancelTask.mockResolvedValueOnce(fakeTask)
    const res = await DELETE(
      makeReq({ officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(res.status).toBe(200)
    expect(await res.json()).toEqual({ task: fakeTask })
    expect(mockCancelTask).toHaveBeenCalledWith(42, 'cto')
  })

  it('"not found" error → 404', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockCancelTask.mockRejectedValueOnce(new Error('Task 42 not found'))
    const res = await DELETE(
      makeReq({ officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(res.status).toBe(404)
    spy.mockRestore()
  })

  it('coerceWipCapError returns error → 409 with wip-cap-exceeded body', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockCancelTask.mockRejectedValueOnce({ code: '23514' })
    mockCoerce.mockReturnValueOnce(new WipCapExceededError('cto', [], 3))
    const res = await DELETE(
      makeReq({ officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(res.status).toBe(409)
    expect((await res.json()).error).toBe('wip-cap-exceeded')
    // DELETE handler passes '?' to coerce (cancel can't trip WIP — but kept
    // for future edge like cancel→requeue)
    expect(mockCoerce).toHaveBeenCalledWith({ code: '23514' }, '?')
    spy.mockRestore()
  })

  it('generic error → 500', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockCancelTask.mockRejectedValueOnce(new Error('oops'))
    const res = await DELETE(
      makeReq({ officer_slug: 'cto' }),
      makeParams('42')
    )
    expect(res.status).toBe(500)
    expect((await res.json()).error).toBe('oops')
    spy.mockRestore()
  })
})
