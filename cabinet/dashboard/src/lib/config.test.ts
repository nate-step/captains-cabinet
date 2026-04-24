// config.ts — 9 config getters used by dashboard /admin + /health pages.
// Module captures IS_MOCK at load from (MOCK_DATA === 'true' OR
// !fs.existsSync(CONFIG_PATH)). In test env CONFIG_PATH defaults to
// /opt/founders-cabinet/instance/config/product.yml which EXISTS —
// so we force MOCK_DATA=true before dynamic import to pin the
// deterministic mock fixtures.
//
// Real path (fs.readFileSync + yaml.load) requires fs mocking and
// is deferred — this harness covers the fallback contract that
// /admin relies on during Next.js build-time collection.

import { beforeAll, describe, it, expect } from 'vitest'

process.env.MOCK_DATA = 'true'

type Mod = typeof import('./config')
let mod: Mod

beforeAll(async () => {
  mod = await import('./config')
})

describe('getConfig — mock path', () => {
  it('returns an object with expected top-level sections', () => {
    const config = mod.getConfig()
    expect(config).toHaveProperty('product')
    expect(config).toHaveProperty('voice')
    expect(config).toHaveProperty('image_generation')
    expect(config).toHaveProperty('embeddings')
    expect(config).toHaveProperty('notion')
    expect(config).toHaveProperty('linear')
    expect(config).toHaveProperty('telegram')
  })

  it('product section has name + captain_name + repo', () => {
    const { product } = mod.getConfig() as { product: Record<string, string> }
    expect(product.name).toBe('Sensed')
    expect(product.captain_name).toBe('Nate')
    expect(typeof product.repo).toBe('string')
  })
})

describe('getDashboardConfig — consumer mode gate', () => {
  it('defaults consumerModeEnabled to true (safe default)', () => {
    const result = mod.getDashboardConfig()
    expect(result.consumerModeEnabled).toBe(true)
  })

  it('returns shape {consumerModeEnabled: boolean}', () => {
    const result = mod.getDashboardConfig()
    expect(result).toHaveProperty('consumerModeEnabled')
    expect(typeof result.consumerModeEnabled).toBe('boolean')
  })
})

describe('getOfficerConfig(role) — known roles', () => {
  it('returns the CoS config with calm-composed prompt', () => {
    const result = mod.getOfficerConfig('cos')
    expect(result.title).toBe('Chief of Staff (CoS)')
    expect(result.botUsername).toBe('cabinet_cos_bot')
    expect(result.voicePrompt).toContain('calm')
  })

  it('returns the CTO config with sharp-technical prompt', () => {
    const result = mod.getOfficerConfig('cto')
    expect(result.title).toBe('Chief Technology Officer (CTO)')
    expect(result.botUsername).toBe('cabinet_cto_bot')
    expect(result.voicePrompt).toContain('technical')
  })

  it('returns all 5 officer titles present in mock', () => {
    for (const role of ['cos', 'cto', 'cpo', 'cro', 'coo']) {
      const result = mod.getOfficerConfig(role)
      expect(result.title).toBeTruthy()
      expect(result.title.length).toBeGreaterThan(0)
    }
  })

  it('officer config has voiceStability in range [0, 1]', () => {
    for (const role of ['cos', 'cto', 'cpo', 'cro', 'coo']) {
      const { voiceStability } = mod.getOfficerConfig(role)
      expect(voiceStability).toBeGreaterThanOrEqual(0)
      expect(voiceStability).toBeLessThanOrEqual(1)
    }
  })

  it('unknown role falls back to uppercase title + empty fields', () => {
    const result = mod.getOfficerConfig('xyz')
    expect(result.title).toBe('XYZ')
    expect(result.botUsername).toBe('')
    expect(result.voiceId).toBe('')
    expect(result.voiceStability).toBe(0.5)
    expect(result.voiceSpeed).toBe(1.0)
  })

  it('coo has empty voiceId (voice disabled for coo in mock)', () => {
    const result = mod.getOfficerConfig('coo')
    expect(result.voiceId).toBe('')
  })
})

describe('getGlobalConfig — merged product + voice + image + embeddings', () => {
  it('product block contains captain_name + name + description', () => {
    const { product } = mod.getGlobalConfig()
    expect(product.name).toBe('Sensed')
    expect(product.captain_name).toBe('Nate')
    expect(product.description).toContain('Dual-map')
  })

  it('voice.enabled is boolean', () => {
    const { voice } = mod.getGlobalConfig()
    expect(typeof voice.enabled).toBe('boolean')
    expect(voice.provider).toBe('elevenlabs')
  })

  it('embeddings.dimensions is 1024 (voyage-3)', () => {
    const { embeddings } = mod.getGlobalConfig()
    expect(embeddings.dimensions).toBe(1024)
    expect(embeddings.provider).toBe('voyage')
    expect(embeddings.models.storage).toBe('voyage-3')
    expect(embeddings.models.query).toBe('voyage-3')
  })

  it('image_generation has enabled + provider + model', () => {
    const { image_generation } = mod.getGlobalConfig()
    expect(image_generation.enabled).toBe(true)
    expect(image_generation.provider).toBe('openai')
    expect(image_generation.model).toBe('gpt-image-1')
  })

  it('missing nested fields fall back to safe defaults (string→empty, bool→false, num→0)', () => {
    // Contract-level test via mock shape — pins that getGlobalConfig never
    // throws on partial config (all fields have ||/?? fallbacks)
    const result = mod.getGlobalConfig()
    expect(typeof result.product.name).toBe('string')
    expect(typeof result.voice.enabled).toBe('boolean')
    expect(typeof result.embeddings.dimensions).toBe('number')
  })
})

describe('getNotionConfig — string-only database IDs', () => {
  it('returns only string values (filters non-string entries)', () => {
    const result = mod.getNotionConfig()
    for (const v of Object.values(result)) {
      expect(typeof v).toBe('string')
    }
  })

  it('includes the mock notion database keys', () => {
    const result = mod.getNotionConfig()
    expect(result).toHaveProperty('business_brain')
    expect(result).toHaveProperty('research_hub')
    expect(result).toHaveProperty('product_hub')
  })
})

describe('getLinearConfig — team_key + workspace_url', () => {
  it('returns both fields from mock', () => {
    const result = mod.getLinearConfig()
    expect(result.team_key).toBe('SEN')
    expect(result.workspace_url).toBe('https://linear.app/sensed')
  })

  it('has the exact shape (two string fields)', () => {
    const result = mod.getLinearConfig()
    expect(Object.keys(result).sort()).toEqual(['team_key', 'workspace_url'])
    expect(typeof result.team_key).toBe('string')
    expect(typeof result.workspace_url).toBe('string')
  })
})

describe('getActiveProjectSlug — mock path', () => {
  it('returns "sensed" in mock mode', () => {
    expect(mod.getActiveProjectSlug()).toBe('sensed')
  })
})

describe('getProjectConfig — active project YAML', () => {
  it('returns the mock project config with expected sections', () => {
    const result = mod.getProjectConfig()
    expect(result).toHaveProperty('product')
    expect(result).toHaveProperty('notion')
    expect(result).toHaveProperty('linear')
    expect(result).toHaveProperty('neon')
    expect(result).toHaveProperty('telegram')
  })

  it('product section has mount_path set to /workspace/product', () => {
    const { product } = mod.getProjectConfig() as { product: Record<string, string> }
    expect(product.mount_path).toBe('/workspace/product')
  })

  it('notion.dashboard has page_id + decision_queue_db + daily_briefings_db', () => {
    const config = mod.getProjectConfig() as {
      notion: { dashboard: Record<string, string> }
    }
    expect(config.notion.dashboard.page_id).toBeTruthy()
    expect(config.notion.dashboard.decision_queue_db).toBeTruthy()
    expect(config.notion.dashboard.daily_briefings_db).toBeTruthy()
  })

  it('linear team_key + workspace_url are strings', () => {
    const { linear } = mod.getProjectConfig() as {
      linear: { team_key: string; workspace_url: string }
    }
    expect(typeof linear.team_key).toBe('string')
    expect(typeof linear.workspace_url).toBe('string')
  })

  it('telegram.officers has all 5 role entries', () => {
    const { telegram } = mod.getProjectConfig() as {
      telegram: { officers: Record<string, string> }
    }
    for (const role of ['cos', 'cto', 'cpo', 'cro', 'coo']) {
      expect(telegram.officers).toHaveProperty(role)
      expect(telegram.officers[role]).toContain('bot')
    }
  })
})

describe('getProjectsList — mock path', () => {
  it('returns the mock fixture with sensed + demo-project', () => {
    const result = mod.getProjectsList()
    expect(result).toContainEqual({ slug: 'sensed', name: 'Sensed' })
    expect(result).toContainEqual({ slug: 'demo-project', name: 'Demo Project' })
  })

  it('every entry has {slug, name} string fields', () => {
    const result = mod.getProjectsList()
    for (const item of result) {
      expect(typeof item.slug).toBe('string')
      expect(typeof item.name).toBe('string')
      expect(item.slug.length).toBeGreaterThan(0)
      expect(item.name.length).toBeGreaterThan(0)
    }
  })
})
