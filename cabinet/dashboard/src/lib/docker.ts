import { exec as execCb } from 'child_process'
import { promisify } from 'util'

const exec = promisify(execCb)
const prefix = process.env.CABINET_PREFIX || 'cabinet'
const container = `${prefix}-officers`
const IS_MOCK = process.env.MOCK_DATA === 'true' || !process.env.REDIS_URL

export async function dockerExec(command: string): Promise<{ stdout: string; stderr: string }> {
  if (IS_MOCK) {
    console.log(`[mock docker] Would exec: ${command}`)
    return { stdout: 'mock: command executed', stderr: '' }
  }
  const escaped = command.replace(/'/g, "'\\''")
  const { stdout, stderr } = await exec(
    `docker exec -u cabinet ${container} bash -c '${escaped}'`
  )
  return { stdout: stdout.trim(), stderr: stderr.trim() }
}

export async function getTmuxWindows(): Promise<string[]> {
  if (IS_MOCK) {
    return ['cos', 'cto', 'cpo', 'cro', 'coo']
  }
  try {
    const { stdout } = await dockerExec(
      'tmux list-windows -t cabinet -F "#{window_name}" 2>/dev/null'
    )
    return stdout
      .split('\n')
      .filter((w) => w.startsWith('officer-'))
      .map((w) => w.replace('officer-', ''))
  } catch {
    return []
  }
}

export async function isClaudeAlive(role: string): Promise<boolean> {
  if (IS_MOCK) {
    // In mock mode, most officers are alive except coo
    return role !== 'coo'
  }
  try {
    // Get the pane PID for this officer's tmux window
    const { stdout: panePid } = await dockerExec(
      `tmux list-panes -t cabinet:officer-${role} -F '#{pane_pid}' 2>/dev/null`
    )
    if (!panePid || panePid === 'mock: command executed') return false

    const pid = panePid.trim()
    if (!pid) return false

    // Check if there's a claude process as a child of the pane shell
    const { stdout: children } = await dockerExec(
      `ps --ppid ${pid} -o comm= 2>/dev/null`
    )
    // Claude Code runs as "claude" or "node" process
    const procs = children.toLowerCase()
    return procs.includes('claude') || procs.includes('node')
  } catch {
    return false
  }
}

export interface CronJob {
  schedule: string
  command: string
  description: string
}

export async function dockerWriteFile(path: string, content: string): Promise<void> {
  if (IS_MOCK) {
    console.log(`[mock docker] Would write file: ${path}`)
    return
  }
  // Base64 encode to avoid shell escaping issues
  const b64 = Buffer.from(content).toString('base64')
  await dockerExec(`echo '${b64}' | base64 -d > '${path}'`)
}

export async function dockerReadFile(path: string): Promise<string> {
  if (IS_MOCK) {
    console.log(`[mock docker] Would read file: ${path}`)
    return ''
  }
  const { stdout } = await dockerExec(`cat '${path}' 2>/dev/null || echo ''`)
  return stdout
}

export async function getCronSchedule(): Promise<CronJob[]> {
  if (IS_MOCK) {
    return [
      { schedule: '*/5 * * * *', command: 'health-check.sh', description: 'Health check' },
      { schedule: '*/15 * * * *', command: 'token-refresh.sh', description: 'Token refresh' },
      { schedule: '0 6 * * *', command: 'morning-briefing.sh', description: 'Morning briefing (07:00 CET)' },
      { schedule: '0 18 * * *', command: 'evening-briefing.sh', description: 'Evening briefing (19:00 CET)' },
      { schedule: '0 */4 * * *', command: 'research-sweep.sh', description: 'Research sweep' },
      { schedule: '0 */12 * * *', command: 'backlog-refinement.sh', description: 'Backlog refinement' },
      { schedule: '30 6 * * *', command: 'retrospective.sh', description: 'Retrospective (07:30 CET)' },
      { schedule: '0 19 * * *', command: 'cost-dashboard.sh', description: 'Cost dashboard (20:00 CET)' },
    ]
  }
  try {
    const watchdogContainer = `${prefix}-watchdog`
    const { stdout } = await exec(
      `docker exec ${watchdogContainer} crontab -l 2>/dev/null`
    )
    const lines = stdout.trim().split('\n').filter((l: string) => l && !l.startsWith('#'))
    return lines.map((line: string) => {
      const parts = line.trim().split(/\s+/)
      const schedule = parts.slice(0, 5).join(' ')
      const command = parts.slice(5).join(' ')
      const scriptName = command.split('/').pop() || command
      return { schedule, command, description: scriptName }
    })
  } catch {
    return []
  }
}

export async function getEnvVars(): Promise<Record<string, string>> {
  if (IS_MOCK) {
    return {
      ANTHROPIC_API_KEY: 'sk-ant-...mock1234',
      ELEVENLABS_API_KEY: 'el-...mock5678',
      GITHUB_PAT: 'ghp_...mock9012',
      LINEAR_API_KEY: 'lin_api_...mock3456',
      NOTION_API_KEY: 'ntn_...mock7890',
      NEON_CONNECTION_STRING: 'postgresql://...mock',
      VOYAGE_API_KEY: 'voy-...mock1111',
      PERPLEXITY_API_KEY: 'pplx-...mock2222',
      BRAVE_SEARCH_API_KEY: 'BSA-...mock3333',
      EXA_API_KEY: 'exa-...mock4444',
      MAPBOX_TOKEN: 'pk.ey...mock5555',
      TELEGRAM_HQ_CHAT_ID: '-1001234567890',
      CAPTAIN_TELEGRAM_ID: '123456789',
      TELEGRAM_COS_TOKEN: '7001234567:AAE...mock',
      TELEGRAM_CTO_TOKEN: '7001234568:AAE...mock',
      TELEGRAM_CPO_TOKEN: '7001234569:AAE...mock',
      TELEGRAM_CRO_TOKEN: '7001234570:AAE...mock',
    }
  }
  try {
    const { stdout } = await dockerExec(
      `grep -v '^#' /opt/founders-cabinet/cabinet/.env | grep -v '^$'`
    )
    const vars: Record<string, string> = {}
    for (const line of stdout.split('\n')) {
      const eqIdx = line.indexOf('=')
      if (eqIdx > 0) {
        const key = line.substring(0, eqIdx).trim()
        const value = line.substring(eqIdx + 1).trim()
        vars[key] = value
      }
    }
    return vars
  } catch {
    return {}
  }
}

export async function isTelegramConnected(role: string): Promise<boolean> {
  if (IS_MOCK) {
    // In mock mode, most officers are connected except coo
    return role !== 'coo'
  }
  try {
    // Read the bot token from .env inside the container
    const upperRole = role.toUpperCase()
    const { stdout: token } = await dockerExec(
      `grep "^TELEGRAM_${upperRole}_TOKEN=" /opt/founders-cabinet/cabinet/.env 2>/dev/null | cut -d= -f2`
    )
    const trimmedToken = token.trim()
    if (!trimmedToken || trimmedToken === 'mock: command executed') return false

    // Call Telegram getMe to verify the token is valid and bot is reachable
    const { stdout: response } = await dockerExec(
      `curl -s --max-time 5 "https://api.telegram.org/bot${trimmedToken}/getMe"`
    )
    try {
      const parsed = JSON.parse(response)
      return parsed.ok === true
    } catch {
      return false
    }
  } catch {
    return false
  }
}
