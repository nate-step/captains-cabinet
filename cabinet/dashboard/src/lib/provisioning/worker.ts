/**
 * Spec 034 — Provisioning worker (in-memory)
 *
 * Accepts a provisioning job from the API route and runs it asynchronously
 * using Promise.resolve().then(...). The route does NOT await the worker —
 * it returns 202 immediately.
 *
 * Worker responsibilities:
 *  1. Create cabinet row in `creating` state
 *  2. Transition to `adopting-bots` once worker startup steps complete
 *  3. Every transition goes through canTransition() guard + writeAuditEvent()
 *
 * Boot-time sweep:
 *  On server start, SELECT FROM cabinets WHERE state IN stuck states AND
 *  state_entered_at < (now - timeout) → mark `failed`.
 *
 * PR 1 scope: actual provisioning steps (split-cabinet.sh, Docker Compose,
 * peers.yml) are stubbed with TODO comments. Full wiring is PR 3/4/5.
 */

import { query, getDbPool } from '@/lib/db'
import { canTransition, STUCK_STATES, STATE_MACHINE, type CabinetState } from './state-machine'
import { writeAuditEvent, writeTransitionEvent } from './audit'
import crypto from 'crypto'

export interface ProvisioningJobInput {
  cabinet_id: string
  captain_id: string
  name: string
  preset: string
  capacity: string
  actor: string
}

// ----------------------------------------------------------------
// Cabinet DB types
// ----------------------------------------------------------------

interface OfficerSlot {
  role: string
  bot_token: string | null
  adopted_at: string | null
}

export interface CabinetRow {
  cabinet_id: string
  captain_id: string
  name: string
  preset: string
  capacity: string
  state: CabinetState
  state_entered_at: string
  officer_slots: OfficerSlot[]
  retry_count: number
  created_at: string
}

// ----------------------------------------------------------------
// State transition helper — updates DB + writes audit event
// ----------------------------------------------------------------

async function transitionState(opts: {
  cabinet_id: string
  from: CabinetState
  to: CabinetState
  actor: string
  payload?: Record<string, unknown>
  error?: string
}): Promise<void> {
  const check = canTransition(opts.from, opts.to)
  if (!check.ok) {
    console.error(`[worker] Invalid transition ${opts.from} → ${opts.to}: ${check.reason}`)
    throw new Error(check.reason)
  }

  await query(
    `UPDATE cabinets
     SET state = $1, state_entered_at = now()
     WHERE cabinet_id = $2 AND state = $3`,
    [opts.to, opts.cabinet_id, opts.from]
  )

  await writeTransitionEvent({
    cabinet_id: opts.cabinet_id,
    actor: opts.actor,
    entry_point: 'worker',
    from: opts.from,
    to: opts.to,
    payload: opts.payload,
  })

  if (opts.error) {
    await writeAuditEvent({
      cabinet_id: opts.cabinet_id,
      actor: opts.actor,
      entry_point: 'worker',
      event_type: 'error',
      state_before: opts.from,
      state_after: opts.to,
      error: opts.error,
    })
  }
}

// ----------------------------------------------------------------
// Boot-time sweep — marks stuck Cabinets as failed
// ----------------------------------------------------------------

let bootSweepRan = false

/**
 * Run once at server startup. Finds Cabinets stuck in in-flight states
 * beyond their defined timeout and marks them failed.
 * Idempotent — safe to call on every boot.
 */
export async function runBootSweep(): Promise<void> {
  if (bootSweepRan) return
  bootSweepRan = true

  try {
    // Build a CASE expression for per-state timeout thresholds
    const cases = STUCK_STATES.map((s) => {
      const def = STATE_MACHINE[s]
      const ms = def.timeout_ms ?? 600_000 // fallback 10min
      const seconds = Math.floor(ms / 1000)
      return `WHEN state = '${s}' THEN now() - interval '${seconds} seconds'`
    }).join('\n       ')

    const stuckCabinets = await query<{ cabinet_id: string; state: string }>(
      `SELECT cabinet_id, state FROM cabinets
       WHERE state = ANY($1)
         AND state_entered_at < CASE
           ${cases}
           ELSE now()
         END`,
      [STUCK_STATES]
    )

    for (const { cabinet_id, state } of stuckCabinets) {
      console.warn(`[worker/boot-sweep] Cabinet ${cabinet_id} stuck in '${state}' → failing`)
      try {
        await transitionState({
          cabinet_id,
          from: state as CabinetState,
          to: 'failed',
          actor: 'system',
          payload: { reason: 'boot-sweep timeout recovery' },
        })
      } catch (err) {
        // If the row was already moved by a concurrent sweep, swallow
        console.warn(`[worker/boot-sweep] Skipping ${cabinet_id}: ${err}`)
      }
    }
  } catch (err) {
    console.error('[worker/boot-sweep] Sweep failed:', err)
  }
}

// ----------------------------------------------------------------
// Main provisioning job runner
// ----------------------------------------------------------------

/**
 * Start a provisioning job. Returns immediately (fire-and-forget).
 * The caller should NOT await this function.
 */
export function startProvisioningJob(input: ProvisioningJobInput): void {
  // Dispatch asynchronously without blocking the route response
  Promise.resolve()
    .then(() => runProvisioningJob(input))
    .catch((err) => {
      console.error(`[worker] Unhandled provisioning error for ${input.cabinet_id}:`, err)
    })
}

async function runProvisioningJob(input: ProvisioningJobInput): Promise<void> {
  const { cabinet_id, captain_id: _captain_id, name: _name, preset, capacity, actor } = input

  try {
    // Cabinet row was already inserted by the API route in 'creating' state.
    // Worker picks up from there and transitions to adopting-bots.

    // Step 1: Worker startup — validate preset, generate peer secret
    // TODO (PR 3): Run actual preset validation (directory + agents + capabilities)
    // TODO (PR 5): Generate CABINET_PEER_SECRET_<id> + write to .env files + peers.yml

    // Generate peer secret (stored for later wiring — not written to disk in PR 1)
    const _peerSecret = crypto.randomBytes(32).toString('hex')
    // TODO (PR 5): Write _peerSecret to cabinet .env + peers.yml shared_secret_ref

    // Transition to adopting-bots (worker startup complete)
    await transitionState({
      cabinet_id,
      from: 'creating',
      to: 'adopting-bots',
      actor,
      payload: { preset, capacity },
    })

    // From this point the API waits for bot adoptions via POST /adopt-bot.
    // The transition to `provisioning` is triggered by the adopt-bot endpoint
    // once all officer slots are filled.

    // TODO (PR 3): Derive expected officer roles from preset and populate
    //   officer_slots with {role, bot_token: null, adopted_at: null}
    //   so the adopt-bot endpoint knows which slots to fill.

    console.info(`[worker] Cabinet ${cabinet_id} → adopting-bots. Waiting for bot adoptions.`)
  } catch (err) {
    console.error(`[worker] Provisioning job failed for ${cabinet_id}:`, err)

    // Best-effort: mark failed in DB
    try {
      const rows = await query<{ state: string }>(
        'SELECT state FROM cabinets WHERE cabinet_id = $1',
        [cabinet_id]
      )
      if (rows.length > 0) {
        const currentState = rows[0].state as CabinetState
        const check = canTransition(currentState, 'failed')
        if (check.ok) {
          await transitionState({
            cabinet_id,
            from: currentState,
            to: 'failed',
            actor: 'worker',
            error: String(err),
          })
        }
      }
    } catch (markErr) {
      console.error(`[worker] Could not mark ${cabinet_id} as failed:`, markErr)
    }
  }
}

// ----------------------------------------------------------------
// Provisioning continuation — called when all bots are adopted
// ----------------------------------------------------------------

/**
 * Called by the adopt-bot endpoint when all officer slots are filled.
 * Transitions adopting-bots → provisioning → starting.
 */
export function startProvisioningRun(cabinet_id: string, actor: string): void {
  Promise.resolve()
    .then(() => runProvisioningSteps(cabinet_id, actor))
    .catch((err) => {
      console.error(`[worker] runProvisioningSteps failed for ${cabinet_id}:`, err)
    })
}

async function runProvisioningSteps(cabinet_id: string, actor: string): Promise<void> {
  const pool = getDbPool()
  const client = await pool.connect()
  try {
    await client.query('BEGIN')

    const result = await client.query<{ state: string; retry_count: number }>(
      'SELECT state, retry_count FROM cabinets WHERE cabinet_id = $1 FOR UPDATE',
      [cabinet_id]
    )
    if (result.rows.length === 0) {
      throw new Error(`Cabinet ${cabinet_id} not found`)
    }

    const { state, retry_count } = result.rows[0]

    // Enforce retry circuit breaker: max 3 retries
    if (state === 'failed' && retry_count >= 3) {
      await client.query('ROLLBACK')
      console.warn(`[worker] Cabinet ${cabinet_id} has exhausted retries (${retry_count}) — archive required`)
      return
    }

    await client.query('COMMIT')
  } catch (err) {
    await client.query('ROLLBACK')
    throw err
  } finally {
    client.release()
  }

  try {
    // Transition to provisioning
    await transitionState({
      cabinet_id,
      from: 'adopting-bots',
      to: 'provisioning',
      actor,
      payload: { step: 'starting-provisioning' },
    })

    // TODO (PR 3): Run split-cabinet.sh --target-cabinet cabinet_id --capacity capacity --apply
    //   Write migration journal to cabinet/state/migrations/{job_id}.json
    //   Idempotency guard via migrations_applied table

    // TODO (PR 4): docker compose up for new Cabinet's officer containers

    // TODO (PR 5): Write peers.yml entries (phase 1: consented_by_captain: false)
    //              Flip to consented_by_captain: true once both sides verified (phase 2)

    // Transition to starting
    await transitionState({
      cabinet_id,
      from: 'provisioning',
      to: 'starting',
      actor,
      payload: { step: 'waiting-for-heartbeat' },
    })

    // TODO (PR 4): Wait for first-boot heartbeat from the new Cabinet's CoS officer.
    //   On heartbeat confirmation → transitionState starting → active

    console.info(`[worker] Cabinet ${cabinet_id} → starting. Waiting for first heartbeat.`)
  } catch (err) {
    console.error(`[worker] Provisioning steps failed for ${cabinet_id}:`, err)

    try {
      const rows = await query<{ state: string; retry_count: number }>(
        'SELECT state, retry_count FROM cabinets WHERE cabinet_id = $1',
        [cabinet_id]
      )
      if (rows.length > 0) {
        const currentState = rows[0].state as CabinetState
        const check = canTransition(currentState, 'failed')
        if (check.ok) {
          await transitionState({
            cabinet_id,
            from: currentState,
            to: 'failed',
            actor: 'worker',
            error: String(err),
          })
          // Increment retry counter
          await query(
            'UPDATE cabinets SET retry_count = retry_count + 1 WHERE cabinet_id = $1',
            [cabinet_id]
          )
        }
      }
    } catch (markErr) {
      console.error(`[worker] Could not mark ${cabinet_id} as failed:`, markErr)
    }
  }
}
