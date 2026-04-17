/**
 * Spec 034 — GET /api/cabinets/[id] (detail)
 */

import { NextRequest, NextResponse } from 'next/server'
import { requireProvisioningAccess } from '@/lib/provisioning/guard'
import { query } from '@/lib/db'

export const dynamic = 'force-dynamic'

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const guard = await requireProvisioningAccess()
  if (guard.response) return guard.response

  const { id } = await params

  try {
    const rows = await query<{
      cabinet_id: string
      captain_id: string
      name: string
      preset: string
      capacity: string
      state: string
      state_entered_at: string
      officer_slots: unknown
      retry_count: number
      created_at: string
    }>(
      `SELECT cabinet_id, captain_id, name, preset, capacity, state,
              state_entered_at, officer_slots, retry_count, created_at
       FROM cabinets
       WHERE cabinet_id = $1`,
      [id]
    )

    if (rows.length === 0) {
      return NextResponse.json({ ok: false, message: 'Cabinet not found' }, { status: 404 })
    }

    return NextResponse.json({ ok: true, cabinet: rows[0] })
  } catch (err) {
    console.error(`[api/cabinets/${id}] GET error`, err)
    return NextResponse.json({ ok: false, message: 'Failed to fetch cabinet' }, { status: 500 })
  }
}
