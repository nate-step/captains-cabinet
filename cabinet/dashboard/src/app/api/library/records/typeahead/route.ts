/**
 * GET /api/library/records/typeahead?q=<prefix>&spaceId=<optional>&limit=<optional>
 *
 * Spec 037 A1: Wikilink editor typeahead autocomplete.
 * Title-prefix match only (ILIKE '<prefix>%') — fast, deterministic.
 * Current space first, then cross-space. Returns max 10 results by default.
 */

import { NextRequest, NextResponse } from 'next/server'
import { typeaheadRecords } from '@/lib/wikilinks'

export const dynamic = 'force-dynamic'

export async function GET(req: NextRequest) {
  try {
    const { searchParams } = new URL(req.url)
    const q = searchParams.get('q') ?? ''
    const spaceId = searchParams.get('spaceId') ?? undefined
    const limit = Math.min(parseInt(searchParams.get('limit') ?? '10', 10), 20)

    if (!q.trim()) {
      return NextResponse.json({ results: [] })
    }

    const results = await typeaheadRecords(q.trim(), { spaceId, limit })
    return NextResponse.json({ results })
  } catch (err) {
    console.error('[library] GET /api/library/records/typeahead', err)
    return NextResponse.json({ error: 'Typeahead failed' }, { status: 500 })
  }
}
