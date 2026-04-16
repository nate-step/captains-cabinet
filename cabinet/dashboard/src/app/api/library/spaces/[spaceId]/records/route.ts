import { NextRequest, NextResponse } from 'next/server'
import { listRecords, createRecord } from '@/lib/library'

export const dynamic = 'force-dynamic'

export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ spaceId: string }> }
) {
  try {
    const { spaceId } = await params
    const { searchParams } = req.nextUrl
    const labelsParam = searchParams.get('labels')
    const labels = labelsParam
      ? labelsParam
          .split(',')
          .map((l) => l.trim())
          .filter(Boolean)
      : undefined
    const limit = Number(searchParams.get('limit') ?? '50')
    const offset = Number(searchParams.get('offset') ?? '0')

    const records = await listRecords(spaceId, { labels, limit, offset })
    return NextResponse.json({ records })
  } catch (err) {
    console.error('[library] GET /api/library/spaces/[spaceId]/records', err)
    return NextResponse.json({ error: 'Failed to list records' }, { status: 500 })
  }
}

export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ spaceId: string }> }
) {
  try {
    const { spaceId } = await params
    const body = (await req.json()) as {
      title: string
      content_markdown?: string
      schema_data?: Record<string, unknown>
      labels?: string[]
      created_by_officer?: string
    }

    if (!body.title?.trim()) {
      return NextResponse.json({ error: 'title is required' }, { status: 400 })
    }

    const record = await createRecord({
      space_id: spaceId,
      title: body.title.trim(),
      content_markdown: body.content_markdown,
      schema_data: body.schema_data,
      labels: body.labels,
      created_by_officer: body.created_by_officer,
    })
    return NextResponse.json({ record }, { status: 201 })
  } catch (err) {
    console.error('[library] POST /api/library/spaces/[spaceId]/records', err)
    return NextResponse.json({ error: 'Failed to create record' }, { status: 500 })
  }
}
