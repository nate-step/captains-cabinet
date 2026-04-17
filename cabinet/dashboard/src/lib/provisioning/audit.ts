/**
 * Spec 034 — Provisioning audit trail
 *
 * Writes rows to cabinet_provisioning_events. Every state transition,
 * bot adoption, and error goes through here. Payload is scrubbed of
 * secrets before insert.
 */

import { query } from '@/lib/db'
import type { CabinetState } from './state-machine'

export type EntryPoint = 'dashboard' | 'telegram' | 'worker' | 'system'

export type EventType =
  | 'state_transition'
  | 'adopt_bot'
  | 'orphan_bot'
  | 'error'
  | 'cancel'
  | 'boot_sweep'
  | 'lock_acquired'
  | 'lock_released'

export interface AuditEventInput {
  cabinet_id: string
  actor: string
  entry_point: EntryPoint
  event_type: EventType
  state_before?: CabinetState | null
  state_after?: CabinetState | null
  payload?: Record<string, unknown>
  error?: string | null
}

/**
 * Token / secret regex — redacts any value whose key matches.
 * Matches: token, secret, key, password (case-insensitive).
 */
const SECRET_KEY_RE = /token|secret|key|password/i

/**
 * Walk a plain-object payload and redact any field whose key looks like a secret.
 */
function redactPayload(payload: Record<string, unknown>): Record<string, unknown> {
  const result: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(payload)) {
    if (SECRET_KEY_RE.test(k)) {
      result[k] = '[REDACTED]'
    } else if (v !== null && typeof v === 'object' && !Array.isArray(v)) {
      result[k] = redactPayload(v as Record<string, unknown>)
    } else {
      result[k] = v
    }
  }
  return result
}

/**
 * Write a single audit event row. Never throws — audit failures are logged
 * but must not crash the provisioning flow itself.
 */
export async function writeAuditEvent(event: AuditEventInput): Promise<void> {
  try {
    const safePayload = event.payload ? redactPayload(event.payload) : {}
    await query(
      `INSERT INTO cabinet_provisioning_events
         (cabinet_id, actor, entry_point, event_type,
          state_before, state_after, payload, error)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)`,
      [
        event.cabinet_id,
        event.actor,
        event.entry_point,
        event.event_type,
        event.state_before ?? null,
        event.state_after ?? null,
        JSON.stringify(safePayload),
        event.error ?? null,
      ]
    )
  } catch (err) {
    // Audit failures must not halt the provisioning flow
    console.error('[provisioning/audit] writeAuditEvent failed', err)
  }
}

/**
 * Convenience: write a state_transition event.
 */
export async function writeTransitionEvent(opts: {
  cabinet_id: string
  actor: string
  entry_point: EntryPoint
  from: CabinetState
  to: CabinetState
  payload?: Record<string, unknown>
}): Promise<void> {
  await writeAuditEvent({
    cabinet_id: opts.cabinet_id,
    actor: opts.actor,
    entry_point: opts.entry_point,
    event_type: 'state_transition',
    state_before: opts.from,
    state_after: opts.to,
    payload: opts.payload,
  })
}

/**
 * Retrieve audit events for a Cabinet since a given event_id (SSE Last-Event-ID
 * replay). Returns events in ascending timestamp order.
 */
export interface AuditEvent extends Record<string, unknown> {
  event_id: number
  cabinet_id: string
  timestamp: string
  actor: string
  entry_point: string
  event_type: string
  state_before: string | null
  state_after: string | null
  payload: Record<string, unknown>
  error: string | null
}

export async function getAuditEvents(
  cabinetId: string,
  sinceEventId?: number
): Promise<AuditEvent[]> {
  if (sinceEventId != null) {
    return query<AuditEvent>(
      `SELECT event_id, cabinet_id, timestamp, actor, entry_point,
              event_type, state_before, state_after, payload, error
       FROM cabinet_provisioning_events
       WHERE cabinet_id = $1 AND event_id > $2
       ORDER BY timestamp ASC`,
      [cabinetId, sinceEventId]
    )
  }
  return query<AuditEvent>(
    `SELECT event_id, cabinet_id, timestamp, actor, entry_point,
            event_type, state_before, state_after, payload, error
     FROM cabinet_provisioning_events
     WHERE cabinet_id = $1
     ORDER BY timestamp ASC`,
    [cabinetId]
  )
}
