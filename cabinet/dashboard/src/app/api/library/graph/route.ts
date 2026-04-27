import { NextRequest, NextResponse } from 'next/server'
import { getGraphData } from '@/lib/library'

export const dynamic = 'force-dynamic'

// Spec 045 Phase 2 — GET /api/library/graph
// Returns {nodes, edges} for the force-directed graph view at /library/graph.
// Query params:
//   ?space_ids=1,2,3   filter to one or more Spaces (omit for cross-Space)
//   ?limit=500         cap node count (default 500, top-N by degree)
export async function GET(req: NextRequest) {
  try {
    const url = new URL(req.url)
    const spaceIdsParam = url.searchParams.get('space_ids')
    const limitParam = url.searchParams.get('limit')

    const spaceIds = spaceIdsParam
      ? spaceIdsParam
          .split(',')
          .map((s) => s.trim())
          .filter((s) => /^\d+$/.test(s))
      : undefined

    const limit = limitParam && /^\d+$/.test(limitParam) ? parseInt(limitParam, 10) : undefined
    const clampedLimit = limit !== undefined ? Math.min(Math.max(limit, 1), 5000) : undefined

    const data = await getGraphData({ spaceIds, limitNodes: clampedLimit })
    return NextResponse.json(data)
  } catch (err) {
    console.error('[library] GET /api/library/graph', err)
    return NextResponse.json({ error: 'failed to load graph data' }, { status: 500 })
  }
}
