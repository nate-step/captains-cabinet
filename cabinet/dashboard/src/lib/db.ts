import { Pool } from 'pg'

// Singleton connection pool — reused across requests in the same process.
// Next.js in development hot-reloads; store the pool on globalThis to avoid
// exhausting connections during HMR.

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

const pool: Pool =
  process.env.NODE_ENV === 'development'
    ? (globalThis.__pgPool ??= createPool())
    : createPool()

if (process.env.NODE_ENV === 'development') {
  globalThis.__pgPool = pool
}

export default pool

/** Convenience: run a parameterized query and return rows */
export async function query<T extends Record<string, unknown>>(
  text: string,
  values?: unknown[]
): Promise<T[]> {
  const result = await pool.query<T>(text, values)
  return result.rows
}
