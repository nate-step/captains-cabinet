// redis.ts — mockRedis backend + cost/token/schedule readers.
// Module captures IS_MOCK at load time from REDIS_URL+MOCK_DATA. With
// REDIS_URL unset (default in vitest env), IS_MOCK=true routes through
// the mockStore + mockHashStore, so we test the mock path end-to-end.
//
// mockHashStore is populated via Math.random at module load (30 days
// of cost data) — we assert structural invariants (length, shape,
// arithmetic), not exact cost values. For direct mockRedis tests we
// set/get/del deterministic keys inside the mock store.

import { beforeAll, describe, it, expect } from 'vitest'

// Ensure mock path is active before dynamic import (module reads env at load)
delete process.env.REDIS_URL
delete process.env.MOCK_DATA

type RedisShape = {
  get: (key: string) => Promise<string | null>
  set: (key: string, value: string) => Promise<string>
  del: (key: string) => Promise<number>
  keys: (pattern: string) => Promise<string[]>
  hgetall: (key: string) => Promise<Record<string, string> | null>
}

type Mod = typeof import('./redis')

let mod: Mod
let redis: RedisShape

beforeAll(async () => {
  mod = await import('./redis')
  redis = mod.default as unknown as RedisShape
})

describe('mockRedis — primitive ops', () => {
  it('set then get returns the stored value', async () => {
    await redis.set('test:set-get', 'hello')
    expect(await redis.get('test:set-get')).toBe('hello')
  })

  it('set overwrites an existing value', async () => {
    await redis.set('test:overwrite', 'a')
    await redis.set('test:overwrite', 'b')
    expect(await redis.get('test:overwrite')).toBe('b')
  })

  it('get returns null for unknown key', async () => {
    expect(await redis.get('test:nonexistent-key-xyz')).toBeNull()
  })

  it('del removes the key', async () => {
    await redis.set('test:to-delete', 'v')
    await redis.del('test:to-delete')
    expect(await redis.get('test:to-delete')).toBeNull()
  })

  it('del on missing key does not throw', async () => {
    await expect(redis.del('test:never-existed')).resolves.toBeDefined()
  })

  it('set returns OK', async () => {
    expect(await redis.set('test:retval', 'v')).toBe('OK')
  })

  it('del returns a number', async () => {
    expect(typeof (await redis.del('test:retval'))).toBe('number')
  })
})

describe('mockRedis — keys pattern matching', () => {
  it('keys returns entries matching prefix*', async () => {
    await redis.set('test:keys:a', '1')
    await redis.set('test:keys:b', '2')
    const result = await redis.keys('test:keys:*')
    expect(result).toContain('test:keys:a')
    expect(result).toContain('test:keys:b')
  })

  it('keys spans BOTH string store AND hash store', async () => {
    // seed data populated mockHashStore with cabinet:cost:tokens:daily:<date>
    // cabinet:heartbeat:* lives in mockStore
    // keys for cabinet:* returns entries from both
    const result = await redis.keys('cabinet:*')
    const hasFromStringStore = result.some((k) => k.startsWith('cabinet:heartbeat:'))
    const hasFromHashStore = result.some((k) => k.startsWith('cabinet:cost:tokens:daily:'))
    expect(hasFromStringStore).toBe(true)
    expect(hasFromHashStore).toBe(true)
  })

  it('keys with no matches returns empty array', async () => {
    const result = await redis.keys('nope-no-such-prefix:*')
    expect(result).toEqual([])
  })

  it('keys strips the asterisk to derive prefix', async () => {
    // pattern 'cabinet:heartbeat:*' → prefix 'cabinet:heartbeat:' — only
    // the first asterisk is replaced. Pins that behavior.
    const result = await redis.keys('cabinet:heartbeat:*')
    expect(result.length).toBeGreaterThan(0)
    for (const k of result) {
      expect(k.startsWith('cabinet:heartbeat:')).toBe(true)
    }
  })
})

describe('mockRedis — hgetall', () => {
  it('returns seeded hash for cabinet:cost:tokens:daily:<today>', async () => {
    const today = new Date().toISOString().split('T')[0]
    const hash = await redis.hgetall(`cabinet:cost:tokens:daily:${today}`)
    expect(hash).not.toBeNull()
    // Mock seeds all 5 officers × 5 metrics = 25 keys
    expect(Object.keys(hash!).length).toBe(25)
    expect(hash!).toHaveProperty('cos_input')
    expect(hash!).toHaveProperty('cto_cost_micro')
  })

  it('hash values are strings (HSET serialization convention)', async () => {
    const today = new Date().toISOString().split('T')[0]
    const hash = await redis.hgetall(`cabinet:cost:tokens:daily:${today}`)
    for (const v of Object.values(hash!)) {
      expect(typeof v).toBe('string')
    }
  })

  it('returns null for unknown hash key', async () => {
    expect(await redis.hgetall('cabinet:never-set-hash')).toBeNull()
  })

  it('returns seeded context pct hash for cabinet:cost:tokens:<role>', async () => {
    const hash = await redis.hgetall('cabinet:cost:tokens:cto')
    expect(hash).not.toBeNull()
    expect(hash!).toHaveProperty('last_context_pct')
    expect(hash!).toHaveProperty('last_context_tokens')
    expect(hash!).toHaveProperty('last_updated')
  })
})

describe('getCostHistory(days)', () => {
  it('returns an array of length === days', async () => {
    const result = await mod.getCostHistory(7)
    expect(result).toHaveLength(7)
  })

  it('days=0 returns empty array', async () => {
    const result = await mod.getCostHistory(0)
    expect(result).toEqual([])
  })

  it('each entry has {date, total, officers}', async () => {
    const result = await mod.getCostHistory(3)
    for (const entry of result) {
      expect(entry).toHaveProperty('date')
      expect(entry).toHaveProperty('total')
      expect(entry).toHaveProperty('officers')
      expect(typeof entry.date).toBe('string')
      expect(typeof entry.total).toBe('number')
      expect(typeof entry.officers).toBe('object')
    }
  })

  it('date[0] is today (descending date order)', async () => {
    const today = new Date().toISOString().split('T')[0]
    const result = await mod.getCostHistory(1)
    expect(result[0].date).toBe(today)
  })

  it('total equals sum of officer costs for each entry', async () => {
    const result = await mod.getCostHistory(5)
    for (const entry of result) {
      const sum = Object.values(entry.officers).reduce((a, b) => a + b, 0)
      expect(entry.total).toBe(sum)
    }
  })

  it('officers keys include the 5 default officer roles', async () => {
    const result = await mod.getCostHistory(1)
    const roles = Object.keys(result[0].officers)
    for (const expected of ['cos', 'cto', 'cpo', 'cro', 'coo']) {
      expect(roles).toContain(expected)
    }
  })

  it('entries past the 30-day mock backfill have zero totals', async () => {
    const result = await mod.getCostHistory(60)
    // last entries (index ≥ 30) date further back than seeded data,
    // so hash is null → all officer costs = 0
    const oldest = result[59]
    expect(oldest.total).toBe(0)
    for (const v of Object.values(oldest.officers)) expect(v).toBe(0)
  })

  // FW-072 / S3 (Pool Phase 1A): pool-mode field shape (per-project
  // `<officer>_<project>_cost_micro`) is summed alongside legacy
  // `<officer>_cost_micro` per officer. The mockHashStore seed is
  // module-private so direct pool-shape seeding isn't exposed in tests
  // — live validation under pool ships separately as a hook integration
  // test. Sum logic is exercised at line 139-159 of redis.ts:
  //   - matches `${role}_cost_micro` (legacy)
  //   - OR `${role}_*_cost_micro` (pool)
  // and never double-counts (each write event hits exactly one shape).
})

describe('getTokenCostHistory(days)', () => {
  it('returns an array of length === days', async () => {
    const result = await mod.getTokenCostHistory(4)
    expect(result).toHaveLength(4)
  })

  it('each entry has {date, officers, totalCostMicro}', async () => {
    const result = await mod.getTokenCostHistory(2)
    for (const entry of result) {
      expect(entry).toHaveProperty('date')
      expect(entry).toHaveProperty('officers')
      expect(entry).toHaveProperty('totalCostMicro')
    }
  })

  it('each officer entry has {input, output, cacheWrite, cacheRead, costMicro}', async () => {
    const result = await mod.getTokenCostHistory(1)
    const officers = result[0].officers
    expect(Object.keys(officers).length).toBeGreaterThan(0)
    for (const role of Object.keys(officers)) {
      expect(officers[role]).toHaveProperty('input')
      expect(officers[role]).toHaveProperty('output')
      expect(officers[role]).toHaveProperty('cacheWrite')
      expect(officers[role]).toHaveProperty('cacheRead')
      expect(officers[role]).toHaveProperty('costMicro')
    }
  })

  it('totalCostMicro equals sum of all officers costMicro', async () => {
    const result = await mod.getTokenCostHistory(3)
    for (const entry of result) {
      const sum = Object.values(entry.officers).reduce((a, o) => a + o.costMicro, 0)
      expect(entry.totalCostMicro).toBe(sum)
    }
  })

  it('missing hash (beyond 30-day backfill) gives empty officers object', async () => {
    // Index 30+ is past the mock backfill, so hash is null → no officer keys added
    const result = await mod.getTokenCostHistory(60)
    const beyondBackfill = result[59]
    expect(Object.keys(beyondBackfill.officers)).toHaveLength(0)
    expect(beyondBackfill.totalCostMicro).toBe(0)
  })

  it('date[0] is today', async () => {
    const today = new Date().toISOString().split('T')[0]
    const result = await mod.getTokenCostHistory(1)
    expect(result[0].date).toBe(today)
  })
})

describe('getScheduleLastRuns', () => {
  it('returns an object with seeded schedule keys, prefix stripped', async () => {
    const result = await mod.getScheduleLastRuns()
    // Mock seeds these 5 schedule keys
    expect(result).toHaveProperty('cos:reflection')
    expect(result).toHaveProperty('cos:briefing')
    expect(result).toHaveProperty('cro:research-sweep')
    expect(result).toHaveProperty('cpo:backlog-refinement')
    expect(result).toHaveProperty('cos:retro')
  })

  it('values are ISO timestamps (strings)', async () => {
    const result = await mod.getScheduleLastRuns()
    for (const v of Object.values(result)) {
      expect(typeof v).toBe('string')
      // ISO format YYYY-MM-DDTHH:MM:SS.sssZ
      expect(v).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    }
  })

  it('excludes null/empty values from the result map', async () => {
    // Verify the seeded entries all roundtrip — and that nothing else leaked
    // through as empty. If a set('') returned an empty string, the `if (val)`
    // gate would have filtered it; this pins that gate.
    await redis.set('cabinet:schedule:last-run:test:empty', '')
    const result = await mod.getScheduleLastRuns()
    expect(result).not.toHaveProperty('test:empty')
    // Cleanup
    await redis.del('cabinet:schedule:last-run:test:empty')
  })

  it('new keys set via redis.set show up in subsequent calls', async () => {
    await redis.set('cabinet:schedule:last-run:test:new-entry', '2026-04-24T09:00:00Z')
    const result = await mod.getScheduleLastRuns()
    expect(result['test:new-entry']).toBe('2026-04-24T09:00:00Z')
    await redis.del('cabinet:schedule:last-run:test:new-entry')
  })
})
