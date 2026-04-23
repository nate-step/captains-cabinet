/**
 * PATCH /api/library/records/:recordId/status
 *
 * Spec 037 A5: Status state-machine transitions.
 * Body: { status: RecordStatus, superseded_by_record_id?: string }
 * Returns 409 with allowed_transitions on invalid transitions.
 */

import { NextRequest, NextResponse } from 'next/server'
import { updateRecordStatus } from '@/lib/library'
import type { RecordStatus } from '@/lib/library'

export const dynamic = 'force-dynamic'

const VALID_STATUSES: RecordStatus[] = [
  'draft', 'in_review', 'approved', 'implemented', 'superseded',
]

export async function PATCH(
  req: NextRequest,
  { params }: { params: Promise<{ recordId: string }> }
) {
  // AC #24 (v3.2): quarantine guard — block status mutations during live migration.
  // Must be checked before auth + DB reads to prevent authz oscillation during
  // partial backfill where some rows may not yet have a valid status.
  if (process.env.LIBRARY_MIGRATION_IN_PROGRESS === '1') {
    return NextResponse.json(
      { error: 'migration_in_progress', retry_after_seconds: 300 },
      { status: 503 }
    )
  }

  try {
    const { recordId } = await params
    const body = (await req.json()) as {
      status?: string
      superseded_by_record_id?: string
    }

    if (!body.status || !VALID_STATUSES.includes(body.status as RecordStatus)) {
      return NextResponse.json(
        { error: `status must be one of: ${VALID_STATUSES.join(', ')}` },
        { status: 400 }
      )
    }

    const result = await updateRecordStatus(
      recordId,
      body.status as RecordStatus,
      body.superseded_by_record_id
    )

    if (!result.ok) {
      const isInvalidTransition = result.current_status !== undefined
      if (isInvalidTransition) {
        // AC #16: pin exact 409 shape with from/to fields
        return NextResponse.json(
          {
            error: 'invalid_transition',
            from: result.current_status,
            to: body.status,
            allowed_transitions: result.allowed_transitions,
          },
          { status: 409 }
        )
      }
      return NextResponse.json({ error: result.error }, { status: 404 })
    }

    return NextResponse.json({ ok: true })
  } catch (err) {
    console.error('[library] PATCH /api/library/records/[recordId]/status', err)
    return NextResponse.json({ error: 'Status update failed' }, { status: 500 })
  }
}
