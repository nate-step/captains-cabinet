/**
 * Spec 034 PR 5 — Shared CabinetRow type
 *
 * Previously duplicated across cabinet-list.tsx (client) and worker.ts (server).
 * Single canonical definition here — both sides import from this module.
 */

export interface OfficerSlot {
  role: string
  bot_token?: string | null
  adopted_at?: string | null
  adopted?: boolean
}

export interface CabinetRow {
  cabinet_id: string
  name: string
  preset: string
  capacity: string
  state: string
  state_entered_at: string
  officer_slots: OfficerSlot[] | unknown
  retry_count: number
  created_at: string
}
