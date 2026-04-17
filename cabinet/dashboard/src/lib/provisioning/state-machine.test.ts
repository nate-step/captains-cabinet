/**
 * Spec 034 — State machine unit tests
 *
 * Reference tests for canTransition(), isTimedOut(), and boot-sweep logic.
 *
 * NOTE: Vitest wiring is not yet configured for this codebase. These tests
 * are authored in vitest syntax and will run once vitest is added to the
 * dashboard package.json (FW follow-up tracked separately). Tests document
 * expected behavior and serve as a regression suite.
 *
 * To run once vitest is wired:
 *   cd cabinet/dashboard && npx vitest src/lib/provisioning/state-machine.test.ts
 */

// vitest is not yet installed in this package — these tests are authoritative
// reference specs. Add "vitest" to devDependencies to run them.
// The globals below resolve at runtime when vitest is present.
/* global describe, it, expect */
declare function describe(name: string, fn: () => void): void
declare function it(name: string, fn: () => void): void
declare const expect: (val: unknown) => {
  toBe: (expected: unknown) => void
  toBeUndefined: () => void
  toBeDefined: () => void
  toContain: (expected: unknown) => void
  toHaveLength: (n: number) => void
  not: { toContain: (expected: unknown) => void; toBeNull: () => void }
  toBeNull: () => void
  toBeGreaterThan: (n: number) => void
}
import {
  canTransition,
  isTimedOut,
  STATE_MACHINE,
  STUCK_STATES,
  ARCHIVE_BLOCKED_STATES,
  type CabinetState,
} from './state-machine'

// ----------------------------------------------------------------
// canTransition: valid transitions
// ----------------------------------------------------------------

describe('canTransition — valid paths', () => {
  const validPairs: [CabinetState, CabinetState][] = [
    ['creating', 'adopting-bots'],
    ['creating', 'failed'],
    ['adopting-bots', 'provisioning'],
    ['adopting-bots', 'failed'],
    ['provisioning', 'starting'],
    ['provisioning', 'failed'],
    ['starting', 'active'],
    ['starting', 'failed'],
    ['active', 'suspended'],
    ['active', 'archiving'],
    ['suspended', 'starting'],
    ['suspended', 'archiving'],
    ['failed', 'provisioning'],
    ['failed', 'archiving'],
    ['archiving', 'archived'],
    ['archiving', 'failed'],
  ]

  for (const [from, to] of validPairs) {
    it(`allows ${from} → ${to}`, () => {
      const result = canTransition(from, to)
      expect(result.ok).toBe(true)
      expect(result.reason).toBeUndefined()
    })
  }
})

// ----------------------------------------------------------------
// canTransition: invalid transitions
// ----------------------------------------------------------------

describe('canTransition — invalid paths', () => {
  const invalidPairs: [CabinetState, CabinetState][] = [
    ['creating', 'active'],
    ['creating', 'suspended'],
    ['creating', 'archived'],
    ['adopting-bots', 'active'],
    ['adopting-bots', 'archiving'],
    ['provisioning', 'active'],
    ['provisioning', 'archiving'],
    ['starting', 'suspended'],
    ['starting', 'provisioning'],
    ['active', 'creating'],
    ['active', 'failed'],
    ['active', 'provisioning'],
    ['suspended', 'active'],
    ['suspended', 'failed'],
    ['failed', 'active'],
    ['failed', 'suspended'],
    ['archiving', 'active'],
    ['archiving', 'creating'],
    ['archived', 'active'], // terminal
    ['archived', 'creating'], // terminal
    ['archived', 'archived'], // terminal
  ]

  for (const [from, to] of invalidPairs) {
    it(`rejects ${from} → ${to}`, () => {
      const result = canTransition(from, to)
      expect(result.ok).toBe(false)
      expect(result.reason).toBeDefined()
    })
  }

  it('rejects transition from archived (terminal state)', () => {
    const result = canTransition('archived', 'active')
    expect(result.ok).toBe(false)
    expect(result.reason).toContain('terminal')
  })

  it('rejects unknown source state', () => {
    const result = canTransition('unknown' as CabinetState, 'active')
    expect(result.ok).toBe(false)
    expect(result.reason).toContain('Unknown source state')
  })

  it('rejects unknown target state', () => {
    const result = canTransition('active', 'unknown' as CabinetState)
    expect(result.ok).toBe(false)
    expect(result.reason).toContain('Unknown target state')
  })
})

// ----------------------------------------------------------------
// isTimedOut: timeout checks
// ----------------------------------------------------------------

describe('isTimedOut — timeout behavior', () => {
  it('creating times out after 60s', () => {
    const pastDate = new Date(Date.now() - 65_000) // 65s ago
    expect(isTimedOut('creating', pastDate)).toBe(true)
  })

  it('creating does not time out before 60s', () => {
    const recentDate = new Date(Date.now() - 30_000) // 30s ago
    expect(isTimedOut('creating', recentDate)).toBe(false)
  })

  it('adopting-bots times out after 15min', () => {
    const pastDate = new Date(Date.now() - 16 * 60_000)
    expect(isTimedOut('adopting-bots', pastDate)).toBe(true)
  })

  it('adopting-bots does not time out before 15min', () => {
    const recentDate = new Date(Date.now() - 5 * 60_000)
    expect(isTimedOut('adopting-bots', recentDate)).toBe(false)
  })

  it('provisioning times out after 10min', () => {
    const pastDate = new Date(Date.now() - 11 * 60_000)
    expect(isTimedOut('provisioning', pastDate)).toBe(true)
  })

  it('starting times out after 5min', () => {
    const pastDate = new Date(Date.now() - 6 * 60_000)
    expect(isTimedOut('starting', pastDate)).toBe(true)
  })

  it('archiving times out after 10min', () => {
    const pastDate = new Date(Date.now() - 11 * 60_000)
    expect(isTimedOut('archiving', pastDate)).toBe(true)
  })

  it('active never times out (stable)', () => {
    const veryOldDate = new Date(0)
    expect(isTimedOut('active', veryOldDate)).toBe(false)
  })

  it('suspended never times out (stable)', () => {
    const veryOldDate = new Date(0)
    expect(isTimedOut('suspended', veryOldDate)).toBe(false)
  })

  it('failed never times out (stable)', () => {
    const veryOldDate = new Date(0)
    expect(isTimedOut('failed', veryOldDate)).toBe(false)
  })

  it('archived never times out (terminal)', () => {
    const veryOldDate = new Date(0)
    expect(isTimedOut('archived', veryOldDate)).toBe(false)
  })
})

// ----------------------------------------------------------------
// STATE_MACHINE invariants
// ----------------------------------------------------------------

describe('STATE_MACHINE — invariants', () => {
  const allStates = Object.keys(STATE_MACHINE) as CabinetState[]

  it('every state has a definition', () => {
    expect(allStates.length).toBe(9)
  })

  it('all allowed_next targets are valid states', () => {
    for (const state of allStates) {
      const def = STATE_MACHINE[state]
      for (const next of def.allowed_next) {
        expect(allStates).toContain(next)
      }
    }
  })

  it('terminal states have no allowed_next', () => {
    for (const state of allStates) {
      const def = STATE_MACHINE[state]
      if (def.terminal) {
        expect(def.allowed_next).toHaveLength(0)
      }
    }
  })

  it('stable states have no timeout', () => {
    for (const state of allStates) {
      const def = STATE_MACHINE[state]
      if (def.stable) {
        expect(def.timeout_ms).toBeNull()
        expect(def.on_timeout).toBeNull()
      }
    }
  })

  it('non-stable non-terminal states have a timeout', () => {
    for (const state of allStates) {
      const def = STATE_MACHINE[state]
      if (!def.stable && !def.terminal) {
        expect(def.timeout_ms).not.toBeNull()
        expect(def.on_timeout).not.toBeNull()
      }
    }
  })
})

// ----------------------------------------------------------------
// STUCK_STATES — boot-sweep candidates
// ----------------------------------------------------------------

describe('STUCK_STATES', () => {
  it('includes all in-flight states', () => {
    expect(STUCK_STATES).toContain('creating')
    expect(STUCK_STATES).toContain('provisioning')
    expect(STUCK_STATES).toContain('starting')
    expect(STUCK_STATES).toContain('archiving')
  })

  it('does not include stable states', () => {
    expect(STUCK_STATES).not.toContain('active')
    expect(STUCK_STATES).not.toContain('suspended')
    expect(STUCK_STATES).not.toContain('failed')
  })

  it('does not include terminal states', () => {
    expect(STUCK_STATES).not.toContain('archived')
  })

  it('all stuck states can transition to failed', () => {
    for (const state of STUCK_STATES) {
      const result = canTransition(state as CabinetState, 'failed')
      expect(result.ok).toBe(true)
    }
  })
})

// ----------------------------------------------------------------
// ARCHIVE_BLOCKED_STATES
// ----------------------------------------------------------------

describe('ARCHIVE_BLOCKED_STATES', () => {
  it('blocks archive in all in-flight states', () => {
    expect(ARCHIVE_BLOCKED_STATES).toContain('creating')
    expect(ARCHIVE_BLOCKED_STATES).toContain('adopting-bots')
    expect(ARCHIVE_BLOCKED_STATES).toContain('provisioning')
    expect(ARCHIVE_BLOCKED_STATES).toContain('starting')
    expect(ARCHIVE_BLOCKED_STATES).toContain('archiving')
    expect(ARCHIVE_BLOCKED_STATES).toContain('archived')
  })

  it('allows archive from active, suspended, failed', () => {
    const archivableStates: CabinetState[] = ['active', 'suspended', 'failed']
    for (const state of archivableStates) {
      expect(ARCHIVE_BLOCKED_STATES).not.toContain(state)
      const result = canTransition(state, 'archiving')
      expect(result.ok).toBe(true)
    }
  })
})

// ----------------------------------------------------------------
// Boot-sweep logic (unit-level — no DB)
// ----------------------------------------------------------------

describe('Boot-sweep timeout logic', () => {
  it('correctly identifies which states need sweeping', () => {
    const now = Date.now()

    // Cabinets stuck beyond their timeout — should be swept
    for (const state of STUCK_STATES) {
      const def = STATE_MACHINE[state as CabinetState]
      const stuckAt = new Date(now - (def.timeout_ms! + 1000))
      expect(isTimedOut(state as CabinetState, stuckAt)).toBe(true)
    }
  })

  it('does not flag recently-entered in-flight states', () => {
    const now = Date.now()

    for (const state of STUCK_STATES) {
      const def = STATE_MACHINE[state as CabinetState]
      const recentAt = new Date(now - (def.timeout_ms! - 5000))
      expect(isTimedOut(state as CabinetState, recentAt)).toBe(false)
    }
  })
})
