import { Pool } from 'pg'

// Lazy singleton connection pool — created on first use rather than at import
// time. This matters because Next.js's build step collects page data and
// imports every server module; creating the Pool at import time means the
// build fails if NEON_CONNECTION_STRING isn't in the BUILD env (env_file in
// docker-compose.yml only applies at RUNTIME).
//
// In dev (HMR), the pool is cached on globalThis to avoid exhausting
// connections across hot reloads.

declare global {
  // eslint-disable-next-line no-var
  var __pgPool: Pool | undefined
}

function createPool(): Pool {
  const connectionString = process.env.NEON_CONNECTION_STRING
  if (!connectionString) {
    throw new Error('NEON_CONNECTION_STRING env var is not set')
  }
  return new Pool({
    connectionString,
    max: 5,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
    ssl: { rejectUnauthorized: false },
  })
}

function getPool(): Pool {
  if (process.env.NODE_ENV === 'development') {
    return (globalThis.__pgPool ??= createPool())
  }
  // In production, recreate per process; Next.js server runs one process
  // so this effectively caches too.
  if (!globalThis.__pgPool) {
    globalThis.__pgPool = createPool()
  }
  return globalThis.__pgPool
}

/** Convenience: run a parameterized query and return rows */
export async function query<T extends Record<string, unknown>>(
  text: string,
  values?: unknown[]
): Promise<T[]> {
  const result = await getPool().query<T>(text, values)
  return result.rows
}

/** Direct pool accessor if a caller needs transactions / custom client usage */
export function getDbPool(): Pool {
  return getPool()
}
