import { NextRequest, NextResponse } from 'next/server'

async function verify(
  token: string,
  sig: string,
  secret: string
): Promise<boolean> {
  const encoder = new TextEncoder()
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign']
  )
  const signature = await crypto.subtle.sign('HMAC', key, encoder.encode(token))
  const expected = Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
  return expected === sig
}

export async function middleware(request: NextRequest) {
  // Skip auth in mock/dev mode when no password is configured
  if (process.env.MOCK_DATA === 'true' || (!process.env.DASHBOARD_PASSWORD && process.env.NODE_ENV === 'development')) {
    return NextResponse.next()
  }

  if (request.nextUrl.pathname.startsWith('/login')) {
    return NextResponse.next()
  }

  const cookie = request.cookies.get('cabinet_session')
  if (!cookie) {
    return NextResponse.redirect(new URL('/login', request.url))
  }

  const [token, sig] = cookie.value.split('.')
  if (!token || !sig) {
    return NextResponse.redirect(new URL('/login', request.url))
  }

  const secret = process.env.DASHBOARD_PASSWORD || 'changeme'
  const valid = await verify(token, sig, secret)
  if (!valid) {
    return NextResponse.redirect(new URL('/login', request.url))
  }

  return NextResponse.next()
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
}
