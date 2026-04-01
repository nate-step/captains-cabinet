import fs from 'fs'
import yaml from 'js-yaml'

const CONFIG_PATH = process.env.CONFIG_PATH || '/opt/founders-cabinet/config/product.yml'
const IS_MOCK = process.env.MOCK_DATA === 'true' || !fs.existsSync(CONFIG_PATH)

const mockConfig = {
  product: {
    name: 'Sensed',
    description: 'Dual-map product for meaningful and anomalous human experiences',
    captain_name: 'Nate',
  },
  voice: {
    enabled: true,
    naturalize: true,
    mode: 'group',
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
