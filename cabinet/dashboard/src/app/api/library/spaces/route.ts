import { NextRequest, NextResponse } from 'next/server'
import { listSpaces, createSpace } from '@/lib/library'

export const dynamic = 'force-dynamic'

export async function GET() {
  try {
    const spaces = await listSpaces()
    return NextResponse.json({ spaces })
  } catch (err) {
    console.error('[library] GET /api/library/spaces', err)
    return NextResponse.json({ error: 'Failed to list spaces' }, { status: 500 })
  }
}

export async function POST(req: NextRequest) {
  try {
    const body = (await req.json()) as {
      name: string
      description?: string
      schema_json?: Record<string, unknown>
      starter_template?: string
      owner?: string
    }

    if (!body.name?.trim()) {
      return NextResponse.json({ error: 'name is required' }, { status: 400 })
    }

    const space = await createSpace({
      name: body.name.trim(),
      description: body.description,
      schema_json: body.schema_json,
      starter_template: body.starter_template,
      owner: body.owner,
    })
    return NextResponse.json({ space }, { status: 201 })
  } catch (err) {
    console.error('[library] POST /api/library/spaces', err)
    return NextResponse.json({ error: 'Failed to create space' }, { status: 500 })
  }
}
