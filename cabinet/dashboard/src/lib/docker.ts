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
