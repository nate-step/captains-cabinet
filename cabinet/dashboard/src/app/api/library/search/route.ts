import { NextRequest, NextResponse } from 'next/server'
import { searchRecords } from '@/lib/library'

export const dynamic = 'force-dynamic'

export async function POST(req: NextRequest) {
  try {
    const body = (await req.json()) as {
      query: string
      space_id?: string
      labels?: string[]
      limit?: number
    }

    if (!body.query?.trim()) {
      return NextResponse.json({ error: 'query is required' }, { status: 400 })
    }

    const results = await searchRecords({
      query: body.query.trim(),
      space_id: body.space_id,
      labels: body.labels,
      limit: body.limit ?? 10,
    })

    return NextResponse.json({ results })
  } catch (err) {
    console.error('[library] POST /api/library/search', err)
    return NextResponse.json({ error: 'Search failed' }, { status: 500 })
  }
}
