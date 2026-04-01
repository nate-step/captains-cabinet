import fs from 'fs'
import yaml from 'js-yaml'

const CONFIG_PATH = '/opt/founders-cabinet/config/product.yml'

export function getConfig(): Record<string, unknown> {
  try {
    const content = fs.readFileSync(CONFIG_PATH, 'utf8')
    return yaml.load(content) as Record<string, unknown>
  } catch {
    return {}
  }
}
