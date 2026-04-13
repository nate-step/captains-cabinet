const IS_MOCK = !process.env.REDIS_URL || process.env.MOCK_DATA === 'true'

// Generate date strings for last N days
function daysAgo(n: number): string {
  const d = new Date()
  d.setDate(d.getDate() - n)
  return d.toISOString().split('T')[0]
}

// Mock data for local development
const today = new Date().toISOString().split('T')[0]
const officers = ['cos', 'cto', 'cpo', 'cro', 'coo']
const dailyCosts = [4250, 3800, 5100, 4700, 3200, 4900, 4450, 3600, 5200, 4100, 3900, 4600, 5000, 3700, 4300, 4800, 3500, 5300, 4000, 3100, 4400, 4950, 3850, 5050, 4150, 3650, 4550, 4750, 3350, 5150]
const officerWeights: Record<string, number> = { cos: 0.30, cto: 0.25, cpo: 0.20, cro: 0.15, coo: 0.10 }

const mockStore: Record<string, string> = {
  'cabinet:heartbeat:cos': new Date().toISOString(),
  'cabinet:heartbeat:cto': new Date(Date.now() - 120000).toISOString(),
  'cabinet:heartbeat:cpo': new Date(Date.now() - 300000).toISOString(),
  'cabinet:heartbeat:cro': new Date(Date.now() - 60000).toISOString(),
  'cabinet:heartbeat:coo': new Date(Date.now() - 900000).toISOString(),
  'cabinet:officer:expected:cos': 'active',
  'cabinet:officer:expected:cto': 'active',
  'cabinet:officer:expected:cpo': 'active',
  'cabinet:officer:expected:cro': 'active',
  'cabinet:officer:expected:coo': 'active',
  'cabinet:killswitch': '',
  // Health mock data — last-toolcall and daily tool call counts
  'cabinet:last-toolcall:cos': new Date(Date.now() - 45000).toISOString(),
  'cabinet:last-toolcall:cto': new Date(Date.now() - 180000).toISOString(),
  'cabinet:last-toolcall:cpo': new Date(Date.now() - 420000).toISOString(),
  'cabinet:last-toolcall:cro': new Date(Date.now() - 90000).toISOString(),
  'cabinet:last-toolcall:coo': new Date(Date.now() - 960000).toISOString(),
  'cabinet:toolcalls:cos': '312',
  'cabinet:toolcalls:cto': '487',
  'cabinet:toolcalls:cpo': '156',
  'cabinet:toolcalls:cro': '203',
  'cabinet:toolcalls:coo': '89',
  // Schedule last-run mock data
  'cabinet:schedule:last-run:cos:reflection': new Date(Date.now() - 3 * 3600000).toISOString(),
  'cabinet:schedule:last-run:cos:briefing': new Date(Date.now() - 7 * 3600000).toISOString(),
  'cabinet:schedule:last-run:cro:research-sweep': new Date(Date.now() - 2 * 3600000).toISOString(),
  'cabinet:schedule:last-run:cpo:backlog-refinement': new Date(Date.now() - 10 * 3600000).toISOString(),
  'cabinet:schedule:last-run:cos:retro': new Date(Date.now() - 20 * 3600000).toISOString(),
}

// Populate 30 days of daily cost + per-officer cost data
for (let i = 0; i < 30; i++) {
  const dateStr = daysAgo(i)
  const totalCents = dailyCosts[i]
  mockStore[`cabinet:cost:daily:${dateStr}`] = String(totalCents)
  for (const role of officers) {
    const weight = officerWeights[role]
    // Add some randomness per officer
    const jitter = 0.8 + Math.random() * 0.4
    const officerCost = Math.round(totalCents * weight * jitter)
    mockStore[`cabinet:cost:officer:${role}:${dateStr}`] = String(officerCost)
  }
}

// Mock hash store for HGETALL support
const mockHashStore: Record<string, Record<string, string>> = {}

// Populate mock token cost data (new system)
for (let i = 0; i < 7; i++) {
  const dateStr = daysAgo(i)
  const hash: Record<string, string> = {}
  for (const role of officers) {
    const weight = officerWeights[role]
    const base = 500000 + Math.round(Math.random() * 200000) // ~500K-700K output tokens
    hash[`${role}_input`] = String(Math.round(base * 0.01))
    hash[`${role}_output`] = String(Math.round(base * weight))
    hash[`${role}_cache_write`] = String(Math.round(base * weight * 2.5))
    hash[`${role}_cache_read`] = String(Math.round(base * weight * 50))
    // Opus cost in microdollars: in*15 + out*75 + cw*3.75 + cr*0.30
    const inp = Math.round(base * 0.01)
    const out = Math.round(base * weight)
    const cw = Math.round(base * weight * 2.5)
    const cr = Math.round(base * weight * 50)
    hash[`${role}_cost_micro`] = String(inp * 15 + out * 75 + Math.round(cw * 3.75) + Math.round(cr * 0.3))
  }
  mockHashStore[`cabinet:cost:tokens:daily:${dateStr}`] = hash
}

// Mock context window data per officer (for health page)
const mockContextPcts: Record<string, number> = { cos: 38.2, cto: 67.5, cpo: 22.1, cro: 45.8, coo: 81.4 }
for (const role of officers) {
  const pct = mockContextPcts[role]
  mockHashStore[`cabinet:cost:tokens:${role}`] = {
    last_context_pct: String(pct),
    last_context_tokens: String(Math.round((pct / 100) * 1000000)),
    last_updated: new Date(Date.now() - Math.round(Math.random() * 300000)).toISOString(),
  }
}

const mockRedis = {
  get: async (key: string) => mockStore[key] || null,
  set: async (key: string, value: string) => { mockStore[key] = value; return 'OK' },
  del: async (key: string) => { delete mockStore[key]; return 1 },
  keys: async (pattern: string) => {
    const prefix = pattern.replace('*', '')
    return [
      ...Object.keys(mockStore).filter(k => k.startsWith(prefix)),
      ...Object.keys(mockHashStore).filter(k => k.startsWith(prefix)),
    ]
  },
  hgetall: async (key: string) => mockHashStore[key] || null,
}

let redis: typeof mockRedis

if (IS_MOCK) {
  console.log('[dashboard] Using mock Redis (set REDIS_URL to connect to real Redis)')
  redis = mockRedis
} else {
  const Redis = require('ioredis')
  const realRedis = new Redis(process.env.REDIS_URL)
  redis = realRedis as typeof mockRedis
}

export default redis

export interface DailyCostEntry {
  date: string
  total: number
  officers: Record<string, number>
}

export async function getCostHistory(days: number): Promise<DailyCostEntry[]> {
  // Discover officers dynamically from Redis expected keys (not hardcoded)
  const officerKeys = await redis.keys('cabinet:officer:expected:*')
  const officers = officerKeys.map(k => k.replace('cabinet:officer:expected:', ''))
  // Fallback if no expected keys found
  if (officers.length === 0) officers.push('cos', 'cto', 'cpo', 'cro', 'coo')

  const entries: DailyCostEntry[] = []

  for (let i = 0; i < days; i++) {
    const d = new Date()
    d.setDate(d.getDate() - i)
    const dateStr = d.toISOString().split('T')[0]

    const totalStr = await redis.get(`cabinet:cost:daily:${dateStr}`)
    const total = totalStr ? parseInt(totalStr, 10) : 0

    const officerCosts: Record<string, number> = {}
    for (const role of officers) {
      const costStr = await redis.get(`cabinet:cost:officer:${role}:${dateStr}`)
      officerCosts[role] = costStr ? parseInt(costStr, 10) : 0
    }

    entries.push({ date: dateStr, total, officers: officerCosts })
  }

  return entries
}

export interface TokenCostEntry {
  date: string
  officers: Record<string, {
    input: number
    output: number
    cacheWrite: number
    cacheRead: number
    costMicro: number
  }>
  totalCostMicro: number
}

export async function getTokenCostHistory(days: number): Promise<TokenCostEntry[]> {
  const officerKeys = await redis.keys('cabinet:officer:expected:*')
  const officers = officerKeys
    .map(k => k.replace('cabinet:officer:expected:', ''))
    .filter(k => !k.includes(':'))
  if (officers.length === 0) officers.push('cos', 'cto', 'cpo', 'cro', 'coo')

  const entries: TokenCostEntry[] = []

  for (let i = 0; i < days; i++) {
    const d = new Date()
    d.setDate(d.getDate() - i)
    const dateStr = d.toISOString().split('T')[0]

    const hash = await redis.hgetall(`cabinet:cost:tokens:daily:${dateStr}`)
    const officerData: TokenCostEntry['officers'] = {}
    let totalCostMicro = 0

    for (const role of officers) {
      if (!hash || Object.keys(hash).length === 0) continue
      const input = parseInt(hash[`${role}_input`] || '0', 10)
      const output = parseInt(hash[`${role}_output`] || '0', 10)
      const cacheWrite = parseInt(hash[`${role}_cache_write`] || '0', 10)
      const cacheRead = parseInt(hash[`${role}_cache_read`] || '0', 10)
      const costMicro = parseInt(hash[`${role}_cost_micro`] || '0', 10)
      officerData[role] = { input, output, cacheWrite, cacheRead, costMicro }
      totalCostMicro += costMicro
    }

    entries.push({ date: dateStr, officers: officerData, totalCostMicro })
  }

  return entries
}

export async function getScheduleLastRuns(): Promise<Record<string, string>> {
  const keys = await redis.keys('cabinet:schedule:last-run:*')
  const result: Record<string, string> = {}
  for (const key of keys) {
    const val = await redis.get(key)
    if (val) {
      const shortKey = key.replace('cabinet:schedule:last-run:', '')
      result[shortKey] = val
    }
  }
  return result
}
