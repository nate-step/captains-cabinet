// GET + POST /api/library/spaces — spaces list + create handler.
//
// Two verbs, each with their own response paths:
//   GET
//     - 200 with {spaces} on success
//     - 500 on throw
//   POST
//     - 400 when name missing/empty/whitespace
//     - 201 with {space} on success
//     - name trimmed before createSpace call
//     - description/schema_json/starter_template/owner pass-through
//     - 500 on throw
//
// Pattern: simple lib-mock (vi.hoisted + vi.mock('@/lib/library')).

import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { NextRequest } from 'next/server'

const { mockListSpaces, mockCreateSpace } = vi.hoisted(() => ({
  mockListSpaces: vi.fn(),
  mockCreateSpace: vi.fn(),
}))

vi.mock('@/lib/library', () => ({
  listSpaces: mockListSpaces,
  createSpace: mockCreateSpace,
}))

import { GET, POST } from './route'

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

beforeEach(() => {
  mockListSpaces.mockReset()
  mockCreateSpace.mockReset()
})

describe('GET /api/library/spaces — success (200)', () => {
  it('200 with {spaces} array on success', async () => {
    const spaces = [
      { id: 'sp1', name: 'Engineering', slug: 'engineering' },
      { id: 'sp2', name: 'Research', slug: 'research' },
    ]
    mockListSpaces.mockResolvedValueOnce(spaces)
    const res = await GET()
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ spaces })
  })

  it('200 with empty {spaces: []} when no spaces exist', async () => {
    mockListSpaces.mockResolvedValueOnce([])
    const res = await GET()
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ spaces: [] })
  })

  it('calls listSpaces with no arguments', async () => {
    mockListSpaces.mockResolvedValueOnce([])
    await GET()
    expect(mockListSpaces).toHaveBeenCalledWith()
  })
})

describe('GET /api/library/spaces — error path (500)', () => {
  it('500 when listSpaces throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockListSpaces.mockRejectedValueOnce(new Error('pg down'))
    const res = await GET()
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to list spaces')
    spy.mockRestore()
  })

  it('500 never leaks internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockListSpaces.mockRejectedValueOnce(new Error('secret: conn=pg://u:pw@host'))
    const res = await GET()
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('pw@host')
    spy.mockRestore()
  })
})

describe('POST /api/library/spaces — body validation (400)', () => {
  it('400 when name is missing', async () => {
    const res = await POST(makeReq({ description: 'a space' }))
    expect(res.status).toBe(400)
    const body = await res.json()
    expect(body.error).toBe('name is required')
  })

  it('400 when name is empty string', async () => {
    const res = await POST(makeReq({ name: '' }))
    expect(res.status).toBe(400)
    expect(mockCreateSpace).not.toHaveBeenCalled()
  })

  it('400 when name is whitespace only', async () => {
    const res = await POST(makeReq({ name: '   ' }))
    expect(res.status).toBe(400)
    expect(mockCreateSpace).not.toHaveBeenCalled()
  })

  it('400 when body is empty object', async () => {
    const res = await POST(makeReq({}))
    expect(res.status).toBe(400)
  })
})

describe('POST /api/library/spaces — pass-through', () => {
  it('name trimmed before createSpace call', async () => {
    mockCreateSpace.mockResolvedValueOnce({ id: 'sp1', name: 'Engineering' })
    await POST(makeReq({ name: '  Engineering  ' }))
    expect(mockCreateSpace).toHaveBeenCalledWith(
      expect.objectContaining({ name: 'Engineering' })
    )
  })

  it('passes description through', async () => {
    mockCreateSpace.mockResolvedValueOnce({ id: 'sp1' })
    await POST(makeReq({ name: 'Eng', description: 'Tech specs and ADRs' }))
    expect(mockCreateSpace).toHaveBeenCalledWith(
      expect.objectContaining({ description: 'Tech specs and ADRs' })
    )
  })

  it('passes schema_json through', async () => {
    const schema = { type: 'object', properties: { priority: { type: 'number' } } }
    mockCreateSpace.mockResolvedValueOnce({ id: 'sp1' })
    await POST(makeReq({ name: 'Eng', schema_json: schema }))
    expect(mockCreateSpace).toHaveBeenCalledWith(
      expect.objectContaining({ schema_json: schema })
    )
  })

  it('passes starter_template through', async () => {
    mockCreateSpace.mockResolvedValueOnce({ id: 'sp1' })
    await POST(makeReq({ name: 'Eng', starter_template: '# Title\n\n...' }))
    expect(mockCreateSpace).toHaveBeenCalledWith(
      expect.objectContaining({ starter_template: '# Title\n\n...' })
    )
  })

  it('passes owner through', async () => {
    mockCreateSpace.mockResolvedValueOnce({ id: 'sp1' })
    await POST(makeReq({ name: 'Eng', owner: 'cto' }))
    expect(mockCreateSpace).toHaveBeenCalledWith(
      expect.objectContaining({ owner: 'cto' })
    )
  })

  it('optional fields undefined when absent', async () => {
    mockCreateSpace.mockResolvedValueOnce({ id: 'sp1' })
    await POST(makeReq({ name: 'Eng' }))
    expect(mockCreateSpace).toHaveBeenCalledWith({
      name: 'Eng',
      description: undefined,
      schema_json: undefined,
      starter_template: undefined,
      owner: undefined,
    })
  })
})

describe('POST /api/library/spaces — success (201)', () => {
  it('201 with {space} on success', async () => {
    const space = { id: 'sp1', name: 'Engineering', slug: 'engineering' }
    mockCreateSpace.mockResolvedValueOnce(space)
    const res = await POST(makeReq({ name: 'Engineering' }))
    expect(res.status).toBe(201)
    const body = await res.json()
    expect(body).toEqual({ space })
  })
})

describe('POST /api/library/spaces — error paths (500)', () => {
  it('500 when createSpace throws', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockCreateSpace.mockRejectedValueOnce(new Error('unique constraint violation'))
    const res = await POST(makeReq({ name: 'Eng' }))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to create space')
    spy.mockRestore()
  })

  it('500 when req.json() throws (malformed body)', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const res = await POST(makeBadJsonReq())
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('Failed to create space')
    spy.mockRestore()
  })

  it('500 never leaks internal error detail', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    mockCreateSpace.mockRejectedValueOnce(new Error('secret: token=x-api-key-123'))
    const res = await POST(makeReq({ name: 'Eng' }))
    const body = await res.json()
    expect(JSON.stringify(body)).not.toContain('x-api-key-123')
    spy.mockRestore()
  })
})
