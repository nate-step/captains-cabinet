const IS_MOCK = !process.env.REDIS_URL || process.env.MOCK_DATA === 'true'

// Mock data for local development
const today = new Date().toISOString().split('T')[0]
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
  [`cabinet:cost:daily:${today}`]: '4250',
  'cabinet:killswitch': '',
}

const mockRedis = {
  get: async (key: string) => mockStore[key] || null,
  set: async (key: string, value: string) => { mockStore[key] = value; return 'OK' },
  del: async (key: string) => { delete mockStore[key]; return 1 },
  keys: async (pattern: string) => {
    const prefix = pattern.replace('*', '')
    return Object.keys(mockStore).filter(k => k.startsWith(prefix))
  },
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
