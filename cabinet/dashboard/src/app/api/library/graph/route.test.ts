// GET /api/library/graph — library graph data handler (Spec 045 Phase 2).
//
// Response paths:
//   - 200 with {nodes, edges} on success (default + filter cases)
//   - 500 on throw
//
// Quirks:
//   - space_ids: comma-separated, ignored values that aren't pure digits
//   - limit: clamped to [1, 5000]; default undefined (lib applies its own default)

import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { NextRequest } from 'next/server'

const { mockGetGraphData } = vi.hoisted(() => ({
  mockGetGraphData: vi.fn(),
}))

vi.mock('@/lib/library', () => ({
  getGraphData: mockGetGraphData,
}))

import { GET } from './route'

function makeReq(url: string): NextRequest {
  return { url } as unknown as NextRequest
}

beforeEach(() => {
  mockGetGraphData.mockReset()
})

describe('GET /api/library/graph — happy path', () => {
  it('200 with empty result when corpus is empty', async () => {
    mockGetGraphData.mockResolvedValueOnce({ nodes: [], edges: [], total_record_count: 0 })
    const res = await GET(makeReq('http://test/api/library/graph'))
    expect(res.status).toBe(200)
    const body = await res.json()
    expect(body).toEqual({ nodes: [], edges: [], total_record_count: 0 })
  })

  it('200 with nodes + edges + total_record_count', async () => {
    const data = {
      nodes: [
        { id: '1', title: 'A', space_id: '10', degree: 2 },
        { id: '2', title: 'B', space_id: '10', degree: 1 },
      ],
      edges: [{ source: '1', target: '2' }],
      total_record_count: 2,
    }
    mockGetGraphData.mockResolvedValueOnce(data)
    const res = await GET(makeReq('http://test/api/library/graph'))
    const body = await res.json()
    expect(body).toEqual(data)
  })

  it('200 with truncated corpus — total > rendered', async () => {
    const data = {
      nodes: [{ id: '1', title: 'A', space_id: '10', degree: 5 }],
      edges: [],
      total_record_count: 597,
    }
    mockGetGraphData.mockResolvedValueOnce(data)
    const res = await GET(makeReq('http://test/api/library/graph?limit=1'))
    const body = await res.json()
    expect(body.total_record_count).toBe(597)
    expect(body.nodes).toHaveLength(1)
  })

  it('passes spaceIds + limit through to lib', async () => {
    mockGetGraphData.mockResolvedValueOnce({ nodes: [], edges: [], total_record_count: 0 })
    await GET(makeReq('http://test/api/library/graph?space_ids=10,11&limit=200'))
    expect(mockGetGraphData).toHaveBeenCalledWith({
      spaceIds: ['10', '11'],
      limitNodes: 200,
    })
  })

  it('strips non-numeric space_ids', async () => {
    mockGetGraphData.mockResolvedValueOnce({ nodes: [], edges: [], total_record_count: 0 })
    await GET(makeReq('http://test/api/library/graph?space_ids=10,abc,12'))
    expect(mockGetGraphData).toHaveBeenCalledWith({
      spaceIds: ['10', '12'],
      limitNodes: undefined,
    })
  })

  it('clamps limit to <=5000', async () => {
    mockGetGraphData.mockResolvedValueOnce({ nodes: [], edges: [], total_record_count: 0 })
    await GET(makeReq('http://test/api/library/graph?limit=99999'))
    expect(mockGetGraphData).toHaveBeenCalledWith({
      spaceIds: undefined,
      limitNodes: 5000,
    })
  })

  it('clamps limit to >=1', async () => {
    mockGetGraphData.mockResolvedValueOnce({ nodes: [], edges: [], total_record_count: 0 })
    await GET(makeReq('http://test/api/library/graph?limit=0'))
    expect(mockGetGraphData).toHaveBeenCalledWith({
      spaceIds: undefined,
      limitNodes: 1,
    })
  })

  it('ignores non-numeric limit', async () => {
    mockGetGraphData.mockResolvedValueOnce({ nodes: [], edges: [], total_record_count: 0 })
    await GET(makeReq('http://test/api/library/graph?limit=abc'))
    expect(mockGetGraphData).toHaveBeenCalledWith({
      spaceIds: undefined,
      limitNodes: undefined,
    })
  })
})

describe('GET /api/library/graph — error path', () => {
  it('500 when lib throws', async () => {
    mockGetGraphData.mockRejectedValueOnce(new Error('db down'))
    const res = await GET(makeReq('http://test/api/library/graph'))
    expect(res.status).toBe(500)
    const body = await res.json()
    expect(body.error).toBe('failed to load graph data')
  })
})
