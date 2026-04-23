import { NextRequest, NextResponse } from 'next/server'
import { getRecord } from '@/lib/library'

export const dynamic = 'force-dynamic'

/**
 * GET /api/library/records/:id/preview
 *
 * Returns a lightweight record preview for the Q2 wikilink hovercard.
 * Shape: { id, title, status, preview } — capped at 200 chars of plain text.
 * Strips markdown syntax before truncating so the card shows readable prose.
 */
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

    // Strip common markdown syntax for a readable plain-text preview
    const plain = record.content_markdown
      .replace(/^#{1,6}\s+/gm, '')       // headings
      .replace(/\*\*(.+?)\*\*/g, '$1')   // bold
      .replace(/\*(.+?)\*/g, '$1')       // italic
      .replace(/`{1,3}[^`]*`{1,3}/g, '') // inline code + fenced blocks
      .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1') // markdown links
      .replace(/\[\[([^\]]+)\]\]/g, '$1')       // wikilinks
      .replace(/^\s*[-*>]\s+/gm, '')            // list markers / blockquotes
      .replace(/\n{2,}/g, ' ')                  // collapse blank lines
      .replace(/\s+/g, ' ')
      .trim()

    const preview = plain.length > 200 ? plain.slice(0, 200) + '…' : plain

    return NextResponse.json({
      id: record.id,
      title: record.title,
      status: record.status,
      preview,
    })
  } catch (err) {
    console.error('[library] GET /api/library/records/[recordId]/preview', err)
    return NextResponse.json({ error: 'Failed to load preview' }, { status: 500 })
  }
}
