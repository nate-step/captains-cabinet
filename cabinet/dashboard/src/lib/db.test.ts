// db.ts — lazy pg-pool singleton harness.
// Testing strategy: vi.mock('pg') replaces the real Pool class with a fake
// that records constructor opts + query() calls. Each test resets the
// globalThis.__pgPool cache + NEON_CONNECTION_STRING so state from one
// test doesn't bleed into the next.
//
// Invariants pinned:
//  - Pool is NOT created at module import (lazy — required for Next.js
//    build-time page-data collection where NEON_CONNECTION_STRING is unset)
//  - getDbPool()/query() throw when NEON_CONNECTION_STRING is missing
//  - Second call returns the same Pool (globalThis cache)
//  - Pool is created with max:5, ssl rejectUnauthorized:false, 5s connect
//    timeout — values that the production footprint relies on
//  - query<T>() returns result.rows, not the full result object

import { describe, it, expect, beforeEach, vi } from 'vitest'

// Track fake Pool instances across tests so we can assert creation + caching
interface FakePool {
  __opts: Record<string, unknown>
  query: ReturnType<typeof vi.fn>
}
const poolCtorCalls: Record<string, unknown>[] = []

vi.mock('pg', () => {
  class Pool {
    __opts: Record<string, unknown>
    query: ReturnType<typeof vi.fn>
    constructor(opts: Record<string, unknown>) {
      this.__opts = opts
      this.query = vi.fn(async (_text: string, _values?: unknown[]) => ({
        rows: [{ id: 1, name: 'fake' }],
        rowCount: 1,
      }))
      poolCtorCalls.push(opts)
    }
  }
  return { Pool }
})

type DbMod = typeof import('./db')
let mod: DbMod

async function loadFresh(): Promise<DbMod> {
  // Reset module cache to re-run top-level code (not strictly needed here
  // since db.ts has no top-level side effects — but keeps tests hermetic).
  vi.resetModules()
  return import('./db')
}

beforeEach(async () => {
  // Clear the module-level singleton + tracked ctor calls
  delete (globalThis as { __pgPool?: unknown }).__pgPool
  poolCtorCalls.length = 0
  delete process.env.NEON_CONNECTION_STRING
  // NODE_ENV is typed readonly in Next.js 15+ — cast to reset between tests
  delete (process.env as Record<string, string | undefined>).NODE_ENV
  mod = await loadFresh()
})

describe('db — lazy pool creation', () => {
  it('does not create a Pool at module import (build-safe)', () => {
    // After import, no Pool was constructed yet
    expect(poolCtorCalls).toHaveLength(0)
    expect((globalThis as { __pgPool?: unknown }).__pgPool).toBeUndefined()
  })

  it('getDbPool throws when NEON_CONNECTION_STRING is unset', () => {
    expect(() => mod.getDbPool()).toThrow('NEON_CONNECTION_STRING env var is not set')
  })

  it('query throws when NEON_CONNECTION_STRING is unset', async () => {
    await expect(mod.query('SELECT 1')).rejects.toThrow(
      'NEON_CONNECTION_STRING env var is not set'
    )
  })

  it('getDbPool creates Pool on first call with env set', () => {
    process.env.NEON_CONNECTION_STRING = 'postgres://test@host/db'
    const pool = mod.getDbPool() as unknown as FakePool
    expect(poolCtorCalls).toHaveLength(1)
    expect(pool.__opts).toHaveProperty('connectionString', 'postgres://test@host/db')
  })

  it('Pool created with expected configuration values', () => {
    process.env.NEON_CONNECTION_STRING = 'postgres://test@host/db'
    mod.getDbPool()
    const opts = poolCtorCalls[0]
    expect(opts.max).toBe(5)
    expect(opts.idleTimeoutMillis).toBe(30_000)
    expect(opts.connectionTimeoutMillis).toBe(5_000)
    expect(opts.ssl).toEqual({ rejectUnauthorized: false })
  })
})

describe('db — singleton caching', () => {
  it('second getDbPool() returns the same instance (only 1 ctor call)', () => {
    process.env.NEON_CONNECTION_STRING = 'postgres://test@host/db'
    const a = mod.getDbPool()
    const b = mod.getDbPool()
    expect(a).toBe(b)
    expect(poolCtorCalls).toHaveLength(1)
  })

  it('caches on globalThis.__pgPool (cross-HMR stability)', () => {
    process.env.NEON_CONNECTION_STRING = 'postgres://test@host/db'
    mod.getDbPool()
    expect((globalThis as { __pgPool?: unknown }).__pgPool).toBeDefined()
  })

  it('query() reuses the cached pool (no second ctor call)', async () => {
    process.env.NEON_CONNECTION_STRING = 'postgres://test@host/db'
    mod.getDbPool()
    await mod.query('SELECT 1')
    expect(poolCtorCalls).toHaveLength(1)
  })

  it('development mode uses globalThis cache too (??= idempotent)', () => {
    ;(process.env as Record<string, string | undefined>).NODE_ENV = 'development'
    process.env.NEON_CONNECTION_STRING = 'postgres://dev@host/db'
    mod.getDbPool()
    mod.getDbPool()
    expect(poolCtorCalls).toHaveLength(1)
  })
})

describe('db — query() delegation', () => {
  it('passes text + values to pool.query', async () => {
    process.env.NEON_CONNECTION_STRING = 'postgres://test@host/db'
    const pool = mod.getDbPool() as unknown as FakePool
    await mod.query('SELECT * FROM users WHERE id = $1', [42])
    expect(pool.query).toHaveBeenCalledWith('SELECT * FROM users WHERE id = $1', [42])
  })

  it('returns result.rows (not the full QueryResult)', async () => {
    process.env.NEON_CONNECTION_STRING = 'postgres://test@host/db'
    const rows = await mod.query<{ id: number; name: string }>('SELECT 1')
    expect(rows).toEqual([{ id: 1, name: 'fake' }])
    // Caller should NOT see rowCount, command, fields etc.
    expect(rows).not.toHaveProperty('rowCount')
  })

  it('forwards undefined values when 2nd arg omitted', async () => {
    process.env.NEON_CONNECTION_STRING = 'postgres://test@host/db'
    const pool = mod.getDbPool() as unknown as FakePool
    await mod.query('SELECT NOW()')
    expect(pool.query).toHaveBeenCalledWith('SELECT NOW()', undefined)
  })

  it('throws when env is set but then cleared between query calls (cached pool survives)', async () => {
    process.env.NEON_CONNECTION_STRING = 'postgres://test@host/db'
    await mod.query('SELECT 1')
    // Clearing env after pool cached doesn't invalidate cache
    delete process.env.NEON_CONNECTION_STRING
    await expect(mod.query('SELECT 2')).resolves.toEqual([{ id: 1, name: 'fake' }])
    expect(poolCtorCalls).toHaveLength(1)
  })
})

describe('db — NODE_ENV=development branch', () => {
  it('dev mode: globalThis ??= creates pool on first call', () => {
    ;(process.env as Record<string, string | undefined>).NODE_ENV = 'development'
    process.env.NEON_CONNECTION_STRING = 'postgres://dev@host/db'
    expect((globalThis as { __pgPool?: unknown }).__pgPool).toBeUndefined()
    mod.getDbPool()
    expect((globalThis as { __pgPool?: unknown }).__pgPool).toBeDefined()
  })

  it('dev mode: pre-populated globalThis.__pgPool is reused (HMR scenario)', () => {
    ;(process.env as Record<string, string | undefined>).NODE_ENV = 'development'
    process.env.NEON_CONNECTION_STRING = 'postgres://dev@host/db'
    // Simulate HMR reload where globalThis.__pgPool is already set
    const precached = { __opts: { fake: 'precache' }, query: vi.fn() }
    ;(globalThis as { __pgPool?: unknown }).__pgPool = precached
    const pool = mod.getDbPool() as unknown as typeof precached
    expect(pool).toBe(precached)
    expect(poolCtorCalls).toHaveLength(0)  // No new pool created
  })
})
