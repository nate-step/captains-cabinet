import { NextRequest, NextResponse } from 'next/server'
import { getBacklinks } from '@/lib/wikilinks'

export const dynamic = 'force-dynamic'

// Spec 045 Phase 1 — GET /api/library/records/[recordId]/backlinks
// Returns the records that link IN to the target record via [[wikilink]] syntax.
// Underlying query lives in lib/wikilinks.ts and is shared with the (future)
// library_get_backlinks MCP tool.
export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ recordId: string }> }
) {
  try {
    const { recordId } = await params
    if (!/^\d+$/.test(recordId)) {
      return NextResponse.json({ error: 'invalid recordId' }, { status: 400 })
    }
    const backlinks = await getBacklinks(recordId)
    return NextResponse.json({ backlinks })
  } catch (err) {
    console.error('[library] GET /api/library/records/[recordId]/backlinks', err)
    return NextResponse.json({ error: 'failed to load backlinks' }, { status: 500 })
  }
}
