import { NextRequest, NextResponse } from 'next/server'
import { getRecordHistory } from '@/lib/library'

export const dynamic = 'force-dynamic'

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ recordId: string }> }
) {
  try {
    const { recordId } = await params
    const history = await getRecordHistory(recordId)
    return NextResponse.json({ history })
  } catch (err) {
    console.error('[library] GET /api/library/records/[recordId]/history', err)
    return NextResponse.json({ error: 'Failed to get history' }, { status: 500 })
  }
}
