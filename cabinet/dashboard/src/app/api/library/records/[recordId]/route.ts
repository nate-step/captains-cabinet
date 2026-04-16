import { NextRequest, NextResponse } from 'next/server'
import { getRecord, updateRecord, deleteRecord } from '@/lib/library'

export const dynamic = 'force-dynamic'

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ recordId: string }> }
) {
  try {
    const { recordId } = await params
    const record = await getRecord(recordId)
    if (!record) {
      return NextResponse.json({ error: 'Record not found' }, { status: 404 })
    }
    return NextResponse.json({ record })
  } catch (err) {
    console.error('[library] GET /api/library/records/[recordId]', err)
    return NextResponse.json({ error: 'Failed to get record' }, { status: 500 })
  }
}

export async function PATCH(
  req: NextRequest,
  { params }: { params: Promise<{ recordId: string }> }
) {
  try {
    const { recordId } = await params
    const body = (await req.json()) as {
      title: string
      content_markdown: string
      schema_data?: Record<string, unknown>
      labels?: string[]
    }

    if (!body.title?.trim()) {
      return NextResponse.json({ error: 'title is required' }, { status: 400 })
    }

    const record = await updateRecord(recordId, {
      title: body.title.trim(),
      content_markdown: body.content_markdown ?? '',
      schema_data: body.schema_data,
      labels: body.labels,
    })
    return NextResponse.json({ record })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Unknown error'
    console.error('[library] PATCH /api/library/records/[recordId]', err)
    if (message.includes('not found')) {
      return NextResponse.json({ error: message }, { status: 404 })
    }
    return NextResponse.json({ error: 'Failed to update record' }, { status: 500 })
  }
}

export async function DELETE(
  _req: NextRequest,
  { params }: { params: Promise<{ recordId: string }> }
) {
  try {
    const { recordId } = await params
    const deleted = await deleteRecord(recordId)
    if (!deleted) {
      return NextResponse.json({ error: 'Record not found or already deleted' }, { status: 404 })
    }
    return NextResponse.json({ ok: true })
  } catch (err) {
    console.error('[library] DELETE /api/library/records/[recordId]', err)
    return NextResponse.json({ error: 'Failed to delete record' }, { status: 500 })
  }
}
