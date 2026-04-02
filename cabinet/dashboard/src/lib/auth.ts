import { cookies } from 'next/headers'
import crypto from 'crypto'

const SECRET = process.env.DASHBOARD_PASSWORD || 'changeme'
const COOKIE_NAME = 'cabinet_session'
const MAX_AGE = 7 * 24 * 60 * 60 // 7 days

function sign(value: string): string {
  return crypto.createHmac('sha256', SECRET).update(value).digest('hex')
}

export async function createSession() {
  const token = crypto.randomBytes(32).toString('hex')
  const signed = `${token}.${sign(token)}`
  const cookieStore = await cookies()
  cookieStore.set(COOKIE_NAME, signed, {
    httpOnly: true,
    secure: false, // Internal tool — HTTP is fine
    maxAge: MAX_AGE,
    path: '/',
    sameSite: 'lax',
  })
}

export async function verifySession(): Promise<boolean> {
  const cookieStore = await cookies()
  const cookie = cookieStore.get(COOKIE_NAME)
  if (!cookie) return false
  const [token, sig] = cookie.value.split('.')
  if (!token || !sig) return false
  return sig === sign(token)
}

export async function destroySession() {
  const cookieStore = await cookies()
  cookieStore.delete(COOKIE_NAME)
}

export function checkPassword(password: string): boolean {
  const a = Buffer.from(password)
  const b = Buffer.from(SECRET)
  if (a.length !== b.length) return false
  return crypto.timingSafeEqual(a, b)
}
