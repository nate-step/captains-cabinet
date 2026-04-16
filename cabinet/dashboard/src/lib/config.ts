import fs from 'fs'
import yaml from 'js-yaml'

const CONFIG_PATH = process.env.CONFIG_PATH || '/opt/founders-cabinet/instance/config/product.yml'
const PROJECTS_DIR = process.env.PROJECTS_DIR || '/opt/founders-cabinet/instance/config/projects'
const ACTIVE_PROJECT_FILE = process.env.ACTIVE_PROJECT_FILE || '/opt/founders-cabinet/instance/config/active-project.txt'
const AGENTS_DIR = process.env.AGENTS_DIR || '/opt/founders-cabinet/.claude/agents'
const LOOP_PROMPTS_DIR = process.env.LOOP_PROMPTS_DIR || '/opt/founders-cabinet/cabinet/loop-prompts'
const IS_MOCK = process.env.MOCK_DATA === 'true' || !fs.existsSync(CONFIG_PATH)

const mockConfig: Record<string, unknown> = {
  product: {
    name: 'Sensed',
    description: 'Dual-map product for meaningful and anomalous human experiences',
    captain_name: 'Nate',
    repo: 'https://github.com/nateref/sensed',
    repo_branch: 'main',
  },
  voice: {
    enabled: true,
    naturalize: true,
    mode: 'group',
    provider: 'elevenlabs',
    model: 'eleven_turbo_v2_5',
    voices: {
      cos: 'pFZP5JQG7iQjIQuC4Bku',
      cto: 'TX3LPaxmHKxFdv7VOQHJ',
      cpo: 'EXAVITQu4vr4xnSDxMaL',
      cro: 'onwK4e9ZLuTAKqWW03F9',
    },
    naturalize_prompts: {
      cos: 'Speak as a calm, composed chief of staff. Brief and decisive.',
      cto: 'Speak as a sharp, technical CTO. Concise and precise.',
      cpo: 'Speak as a thoughtful product leader. User-focused and strategic.',
      cro: 'Speak as a curious, analytical researcher. Data-driven and thorough.',
    },
    stability: { cos: 0.5, cto: 0.45, cpo: 0.5, cro: 0.55 },
    speeds: { cos: 1.0, cto: 1.05, cpo: 1.0, cro: 0.95 },
    models: { cos: 'eleven_turbo_v2_5', cto: 'eleven_turbo_v2_5', cpo: 'eleven_turbo_v2_5', cro: 'eleven_turbo_v2_5' },
  },
  image_generation: {
    enabled: true,
    provider: 'openai',
    model: 'gpt-image-1',
  },
  embeddings: {
    provider: 'voyage',
    models: { storage: 'voyage-3', query: 'voyage-3' },
    dimensions: 1024,
  },
  notion: {
    business_brain: '1a2b3c4d5e6f7890abcdef1234567890',
    research_hub: '2b3c4d5e6f7890abcdef12345678901a',
    product_hub: '3c4d5e6f7890abcdef12345678901a2b',
    engineering_hub: '4d5e6f7890abcdef12345678901a2b3c',
    cabinet_ops: '5e6f7890abcdef12345678901a2b3c4d',
    captains_dashboard: '6f7890abcdef12345678901a2b3c4d5e',
  },
  linear: {
    team_key: 'SEN',
    workspace_url: 'https://linear.app/sensed',
  },
  telegram: {
    officers: {
      cos: 'cabinet_cos_bot',
      cto: 'cabinet_cto_bot',
      cpo: 'cabinet_cpo_bot',
      cro: 'cabinet_cro_bot',
    },
  },
}

export function getConfig(): Record<string, unknown> {
  if (IS_MOCK) {
    return mockConfig
  }
  try {
    const content = fs.readFileSync(CONFIG_PATH, 'utf8')
    return yaml.load(content) as Record<string, unknown>
  } catch {
    return mockConfig
  }
}

export interface OfficerConfig {
  title: string
  botUsername: string
  voiceId: string
  voicePrompt: string
  voiceModel: string
  voiceStability: number
  voiceSpeed: number
  loopPrompt: string
  roleDefinition: string
}

const mockOfficerConfigs: Record<string, OfficerConfig> = {
  cos: {
    title: 'Chief of Staff (CoS)',
    botUsername: 'cabinet_cos_bot',
    voiceId: 'pFZP5JQG7iQjIQuC4Bku',
    voicePrompt: 'Speak as a calm, composed chief of staff. Brief and decisive.',
    voiceModel: 'eleven_turbo_v2_5',
    voiceStability: 0.5,
    voiceSpeed: 1.0,
    loopPrompt: 'Check triggers, process scheduled work, review pending Captain decisions.',
    roleDefinition: '# Chief of Staff (CoS)\n\nYou are the Chief of Staff...',
  },
  cto: {
    title: 'Chief Technology Officer (CTO)',
    botUsername: 'cabinet_cto_bot',
    voiceId: 'TX3LPaxmHKxFdv7VOQHJ',
    voicePrompt: 'Speak as a sharp, technical CTO. Concise and precise.',
    voiceModel: 'eleven_turbo_v2_5',
    voiceStability: 0.45,
    voiceSpeed: 1.05,
    loopPrompt: 'Check triggers, review PRs, monitor deployments, process engineering tasks.',
    roleDefinition: '# Chief Technology Officer (CTO)\n\nYou are the CTO...',
  },
  cpo: {
    title: 'Chief Product Officer (CPO)',
    botUsername: 'cabinet_cpo_bot',
    voiceId: 'EXAVITQu4vr4xnSDxMaL',
    voicePrompt: 'Speak as a thoughtful product leader. User-focused and strategic.',
    voiceModel: 'eleven_turbo_v2_5',
    voiceStability: 0.5,
    voiceSpeed: 1.0,
    loopPrompt: 'Check triggers, refine backlog, review specs, process product tasks.',
    roleDefinition: '# Chief Product Officer (CPO)\n\nYou are the CPO...',
  },
  cro: {
    title: 'Chief Research Officer (CRO)',
    botUsername: 'cabinet_cro_bot',
    voiceId: 'onwK4e9ZLuTAKqWW03F9',
    voicePrompt: 'Speak as a curious, analytical researcher. Data-driven and thorough.',
    voiceModel: 'eleven_turbo_v2_5',
    voiceStability: 0.55,
    voiceSpeed: 0.95,
    loopPrompt: 'Check triggers, sweep research sources, publish briefs, process research tasks.',
    roleDefinition: '# Chief Research Officer (CRO)\n\nYou are the CRO...',
  },
  coo: {
    title: 'Chief Operations Officer (COO)',
    botUsername: 'cabinet_coo_bot',
    voiceId: '',
    voicePrompt: '',
    voiceModel: '',
    voiceStability: 0.5,
    voiceSpeed: 1.0,
    loopPrompt: 'Check triggers, monitor infrastructure, review ops metrics.',
    roleDefinition: '# Chief Operations Officer (COO)\n\nYou are the COO...',
  },
}

function readFileOrEmpty(filePath: string): string {
  try {
    return fs.readFileSync(filePath, 'utf8')
  } catch {
    return ''
  }
}

function extractTitle(roleDefinition: string, role: string): string {
  const match = roleDefinition.match(/^#\s+(.+)/m)
  if (match) return match[1].trim()
  return role.toUpperCase()
}

function getNestedValue(obj: Record<string, unknown>, path: string): unknown {
  const parts = path.split('.')
  let current: unknown = obj
  for (const part of parts) {
    if (current === null || current === undefined || typeof current !== 'object') return undefined
    current = (current as Record<string, unknown>)[part]
  }
  return current
}

export function getOfficerConfig(role: string): OfficerConfig {
  if (IS_MOCK) {
    return mockOfficerConfigs[role] || {
      title: role.toUpperCase(),
      botUsername: '',
      voiceId: '',
      voicePrompt: '',
      voiceModel: '',
      voiceStability: 0.5,
      voiceSpeed: 1.0,
      loopPrompt: '',
      roleDefinition: '',
    }
  }

  const config = getConfig()
  const roleDefinition = readFileOrEmpty(`${AGENTS_DIR}/${role}.md`)
  const loopPrompt = readFileOrEmpty(`${LOOP_PROMPTS_DIR}/${role}.txt`)
  const title = extractTitle(roleDefinition, role)

  const botUsername = (getNestedValue(config, `telegram.officers.${role}`) as string) || ''
  const voiceId = (getNestedValue(config, `voice.voices.${role}`) as string) || ''
  const voicePrompt = (getNestedValue(config, `voice.naturalize_prompts.${role}`) as string) || ''
  const voiceModel = (getNestedValue(config, `voice.models.${role}`) as string) || ''
  const voiceStability = (getNestedValue(config, `voice.stability.${role}`) as number) ?? 0.5
  const voiceSpeed = (getNestedValue(config, `voice.speeds.${role}`) as number) ?? 1.0

  return {
    title,
    botUsername,
    voiceId,
    voicePrompt,
    voiceModel,
    voiceStability,
    voiceSpeed,
    loopPrompt: loopPrompt.trim(),
    roleDefinition,
  }
}

export interface GlobalConfig {
  product: {
    name: string
    description: string
    captain_name: string
    repo: string
    repo_branch: string
  }
  voice: {
    enabled: boolean
    naturalize: boolean
    mode: string
    provider: string
    model: string
  }
  image_generation: {
    enabled: boolean
    provider: string
    model: string
  }
  embeddings: {
    provider: string
    models: { storage: string; query: string }
    dimensions: number
  }
}

export function getGlobalConfig(): GlobalConfig {
  const config = getConfig()
  const product = (config.product || {}) as Record<string, unknown>
  const voice = (config.voice || {}) as Record<string, unknown>
  const imageGen = (config.image_generation || {}) as Record<string, unknown>
  const embeddings = (config.embeddings || {}) as Record<string, unknown>
  const embModels = (embeddings.models || {}) as Record<string, unknown>

  return {
    product: {
      name: (product.name as string) || '',
      description: (product.description as string) || '',
      captain_name: (product.captain_name as string) || '',
      repo: (product.repo as string) || '',
      repo_branch: (product.repo_branch as string) || '',
    },
    voice: {
      enabled: (voice.enabled as boolean) ?? false,
      naturalize: (voice.naturalize as boolean) ?? false,
      mode: (voice.mode as string) || '',
      provider: (voice.provider as string) || '',
      model: (voice.model as string) || '',
    },
    image_generation: {
      enabled: (imageGen.enabled as boolean) ?? false,
      provider: (imageGen.provider as string) || '',
      model: (imageGen.model as string) || '',
    },
    embeddings: {
      provider: (embeddings.provider as string) || '',
      models: {
        storage: (embModels.storage as string) || '',
        query: (embModels.query as string) || '',
      },
      dimensions: (embeddings.dimensions as number) || 0,
    },
  }
}

export function getNotionConfig(): Record<string, string> {
  const config = getConfig()
  const notion = (config.notion || {}) as Record<string, unknown>
  const result: Record<string, string> = {}
  for (const [key, value] of Object.entries(notion)) {
    if (typeof value === 'string') {
      result[key] = value
    }
  }
  return result
}

export function getLinearConfig(): { team_key: string; workspace_url: string } {
  const config = getConfig()
  const linear = (config.linear || {}) as Record<string, unknown>
  return {
    team_key: (linear.team_key as string) || '',
    workspace_url: (linear.workspace_url as string) || '',
  }
}

export function getActiveProjectSlug(): string {
  if (IS_MOCK) {
    return 'sensed'
  }
  try {
    const content = fs.readFileSync(ACTIVE_PROJECT_FILE, 'utf8')
    return content.trim() || 'sensed'
  } catch {
    return 'sensed'
  }
}

export interface ProjectListItem {
  slug: string
  name: string
}

/* ------------------------------------------------------------------ */
/*  Project-level config (reads the active project's full YAML)        */
/* ------------------------------------------------------------------ */

const mockProjectConfig: Record<string, unknown> = {
  product: {
    name: 'Sensed',
    description: 'Dual-map product for meaningful and anomalous human experiences',
    repo: 'https://github.com/nate-step/Sensed',
    repo_branch: 'main',
    mount_path: '/workspace/product',
  },
  notion: {
    cabinet_hq_id: '331412e2-7cc5-815c-b533-e18353773815',
    dashboard: {
      page_id: '331412e2-7cc5-81ac-9a8f-f56812925c93',
      decision_queue_db: '6d81d3e6-a022-4f81-b361-88b15bd496c5',
      daily_briefings_db: '49ce66ef-144a-453b-8868-ff45f09fabf7',
      weekly_reports_db: '27b2d483-3b43-4280-8e10-2ddb96be1d12',
    },
    business_brain: {
      page_id: '331412e2-7cc5-812f-aa5a-fa5c1f022d5e',
      vision_id: '327412e2-7cc5-810a-9f9a-f8484fcca6fc',
      strategy_brief_id: 'e740b7a7-d9a2-4171-9f37-21f759921187',
      brand_guidelines_id: '12d016b9-d22e-44cc-b18b-178ddb8ad88a',
      messaging_pillars_id: 'b0b04025-97d4-423c-8b1a-0f9f68221e79',
      growth_guardrails_id: 'd7df68f2-7071-4125-be4d-e9e90355d631',
      pricing_id: '329412e2-7cc5-81da-a742-eb44dfe0fe95',
    },
    research_hub: {
      page_id: '331412e2-7cc5-8142-8eec-db661c07398a',
      research_briefs_db: 'a65d1718-a57f-4661-827d-bd18031f7f19',
      competitive_intel_db: '0ba5e403-9a0c-4a2c-8c9e-0f2ba42c3f41',
      market_trends_db: '69b63e5a-8e63-4a25-8913-ef1d068f3255',
    },
    product_hub: {
      page_id: '331412e2-7cc5-8100-8647-c6f41abcbf04',
      product_roadmap_db: '0af3ecf2-21d8-44a7-b0ec-3e15806c6d8a',
      feature_specs_db: 'b8005591-a238-4fad-acee-80adb022ad32',
      user_feedback_db: 'ee0c6f7d-e509-44b0-a008-630ab2abe105',
    },
    engineering_hub: {
      page_id: '331412e2-7cc5-8114-ae84-f6dbbdfa84ea',
      architecture_decisions_db: '63b6c6ff-7f31-4841-9072-bb91241d3fcc',
      tech_debt_db: '4d25e734-ffa2-4b1c-bb04-b4141cb72d01',
    },
    cabinet_ops: {
      page_id: '331412e2-7cc5-8190-84ab-cbadcc2573ca',
      decision_journal_db: '62ef4861-4d21-4283-a1df-f833b00dc144',
      improvement_proposals_db: '71131823-c6f2-4cf9-8fb1-dae1365dc097',
    },
    reference: {
      page_id: '331412e2-7cc5-8108-ac5d-f45de40c8e2e',
    },
    archive: {
      page_id: '331412e2-7cc5-81a7-bc2b-f9795afe0233',
    },
  },
  linear: {
    team_key: 'sensed',
    workspace_url: 'https://linear.app/sensed',
  },
  neon: {
    project: 'sensed',
  },
  telegram: {
    officers: {
      cos: 'sensed_cos_bot',
      cto: 'sensed_cto_bot',
      cro: 'sensed_cro_bot',
      cpo: 'sensed_cpo_bot',
      coo: 'sensed_coo_bot',
    },
  },
}

/**
 * Read the active project's source YAML (instance/config/projects/<slug>.yml).
 * Falls back to mock data when running outside Docker.
 */
export function getProjectConfig(): Record<string, unknown> {
  if (IS_MOCK) {
    return mockProjectConfig
  }
  try {
    const slug = getActiveProjectSlug()
    const filePath = `${PROJECTS_DIR}/${slug}.yml`
    const content = fs.readFileSync(filePath, 'utf8')
    return yaml.load(content) as Record<string, unknown>
  } catch {
    return mockProjectConfig
  }
}

export function getProjectsList(): ProjectListItem[] {
  if (IS_MOCK) {
    return [
      { slug: 'sensed', name: 'Sensed' },
      { slug: 'demo-project', name: 'Demo Project' },
    ]
  }
  try {
    const files = fs.readdirSync(PROJECTS_DIR).filter((f) => f.endsWith('.yml'))
    return files.map((f) => {
      const slug = f.replace('.yml', '')
      try {
        const content = fs.readFileSync(`${PROJECTS_DIR}/${f}`, 'utf8')
        const parsed = yaml.load(content) as Record<string, unknown>
        const product = (parsed.product || parsed) as Record<string, unknown>
        const name = (product.name as string) || slug
        return { slug, name }
      } catch {
        return { slug, name: slug }
      }
    })
  } catch {
    // Fallback: return from active config
    const config = getConfig()
    const product = (config.product || {}) as Record<string, unknown>
    const name = (product.name as string) || 'Unknown'
    return [{ slug: getActiveProjectSlug(), name }]
  }
}
