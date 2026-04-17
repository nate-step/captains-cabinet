/**
 * Spec 034 — Provisioning state machine
 *
 * Source of truth for valid state transitions and per-state timeouts.
 * Both the API routes and the worker consult this module before making
 * any transition. Nothing transitions a Cabinet row without calling
 * canTransition() first.
 */

export type CabinetState =
  | 'creating'
  | 'adopting-bots'
  | 'provisioning'
  | 'starting'
  | 'active'
  | 'suspended'
  | 'failed'
  | 'archiving'
  | 'archived'

export interface StateDefinition {
  /** States that are valid targets from this state */
  allowed_next: CabinetState[]
  /** How long the state is allowed to sit before on_timeout fires. null = stable (no timeout). */
  timeout_ms: number | null
  /** State to transition to when timeout fires. null = stable states. */
  on_timeout: CabinetState | null
  /** Whether this is a terminal state (no further transitions possible) */
  terminal: boolean
  /** Whether this is a stable state (timeout = null; persists indefinitely) */
  stable: boolean
}

/**
 * State machine table — matches spec v2 §State Machine exactly.
 *
 * | State          | Timeout (default)     | On timeout    | Allowed transitions                                 |
 * |----------------|-----------------------|---------------|-----------------------------------------------------|
 * | creating       | 60s                   | → failed      | → adopting-bots | failed | cancelled(→failed here)   |
 * | adopting-bots  | 15min idle            | → cancelled   | → provisioning | failed | cancelled               |
 * | provisioning   | 10min no event        | → failed      | → starting | failed                              |
 * | starting       | 5min no heartbeat     | → failed      | → active | failed                              |
 * | active         | N/A (stable)          | —             | → suspended | archiving                        |
 * | suspended      | N/A (stable)          | —             | → starting (resume) | archiving            |
 * | failed         | N/A (stable)          | —             | → provisioning (retry, max 3) | archiving       |
 * | archiving      | 10min                 | → failed      | → archived                                          |
 * | archived       | N/A (terminal)        | —             | —                                                   |
 */
export const STATE_MACHINE: Record<CabinetState, StateDefinition> = {
  creating: {
    allowed_next: ['adopting-bots', 'failed'],
    timeout_ms: 60_000, // 60s
    on_timeout: 'failed',
    terminal: false,
    stable: false,
  },
  'adopting-bots': {
    // 'cancelled' in spec maps to 'failed' — no separate cancelled state defined
    allowed_next: ['provisioning', 'failed'],
    timeout_ms: 15 * 60_000, // 15min idle
    on_timeout: 'failed',
    terminal: false,
    stable: false,
  },
  provisioning: {
    allowed_next: ['starting', 'failed'],
    timeout_ms: 10 * 60_000, // 10min no event
    on_timeout: 'failed',
    terminal: false,
    stable: false,
  },
  starting: {
    allowed_next: ['active', 'failed'],
    timeout_ms: 5 * 60_000, // 5min no heartbeat
    on_timeout: 'failed',
    terminal: false,
    stable: false,
  },
  active: {
    allowed_next: ['suspended', 'archiving'],
    timeout_ms: null,
    on_timeout: null,
    terminal: false,
    stable: true,
  },
  suspended: {
    allowed_next: ['starting', 'archiving'],
    timeout_ms: null,
    on_timeout: null,
    terminal: false,
    stable: true,
  },
  failed: {
    allowed_next: ['provisioning', 'archiving'],
    timeout_ms: null,
    on_timeout: null,
    terminal: false,
    stable: true,
  },
  archiving: {
    allowed_next: ['archived', 'failed'],
    timeout_ms: 10 * 60_000, // 10min
    on_timeout: 'failed',
    terminal: false,
    stable: false,
  },
  archived: {
    allowed_next: [],
    timeout_ms: null,
    on_timeout: null,
    terminal: true,
    stable: true,
  },
}

export interface TransitionResult {
  ok: boolean
  reason?: string
}

/**
 * Check whether a state transition is valid according to the machine.
 * Returns { ok: true } or { ok: false, reason: "..." }.
 */
export function canTransition(from: CabinetState, to: CabinetState): TransitionResult {
  const def = STATE_MACHINE[from]
  if (!def) {
    return { ok: false, reason: `Unknown source state: ${from}` }
  }
  if (def.terminal) {
    return { ok: false, reason: `State '${from}' is terminal — no transitions allowed` }
  }
  if (!STATE_MACHINE[to]) {
    return { ok: false, reason: `Unknown target state: ${to}` }
  }
  if (!def.allowed_next.includes(to)) {
    return {
      ok: false,
      reason: `Transition '${from}' → '${to}' is not allowed. Valid targets: [${def.allowed_next.join(', ')}]`,
    }
  }
  return { ok: true }
}

/**
 * States where the archive endpoint MUST return 409.
 * Archive is only valid from active | suspended | failed.
 */
export const ARCHIVE_BLOCKED_STATES: CabinetState[] = [
  'creating',
  'adopting-bots',
  'provisioning',
  'starting',
  'archiving',
  'archived',
]

/**
 * States where a Cabinet is considered "in-flight" for the boot-time sweep.
 */
export const STUCK_STATES: CabinetState[] = ['creating', 'provisioning', 'starting', 'archiving']

/**
 * Compute whether a Cabinet in the given state has exceeded its timeout.
 * Returns true if the state has a defined timeout AND the state was entered
 * more than timeout_ms ago.
 */
export function isTimedOut(state: CabinetState, stateEnteredAt: Date): boolean {
  const def = STATE_MACHINE[state]
  if (!def || def.timeout_ms === null) return false
  const elapsed = Date.now() - stateEnteredAt.getTime()
  return elapsed > def.timeout_ms
}
