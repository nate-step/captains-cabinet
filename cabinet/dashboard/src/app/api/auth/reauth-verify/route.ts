/**
 * Spec 034 PR 5 — POST /api/auth/reauth-verify
 *
 * Step 2 of re-auth flow. Verifies Captain's password against the challenge token
 * issued by POST /api/auth/reauth-challenge, then returns a one-time-use (OTU) token.
 *
 * OTU token properties:
 *  - 5-minute TTL (same window as challenge, not additive)
 *  - One-time-use: first destructive endpoint to consume it marks it 'used'
 *  - Stored in Redis: key = cabinet:reauth:otu:<token>, value = 'valid' → 'used'
 *
 * Client flow:
 *  1. POST /api/auth/reauth-challenge → { challenge_token }
 *  2. POST /api/auth/reauth-verify { challenge_token, password } → { otu_token }
 *  3. POST /api/cabinets/:id/archive { confirm_name, otu_token }
 *     - Archive route calls consumeOtuToken() which atomically checks + marks used
 *
 * Passkey (WebAuthn) re-auth: deferred to Phase 3. Password-only for v1.
 *
 * Spec refs: AC 15, COO 034.7, PR 5 scope "password-only for v1; passkey is future".
 */

import { NextRequest, NextResponse } from 'next/server'
import { requireProvisioningAccess } from '@/lib/provisioning/guard'
import { checkPassword } from '@/lib/auth'
import crypto from 'crypto'
import redis from '@/lib/redis'

export const dynamic = 'force-dynamic'

const OTU_TTL_SECONDS = 5 * 60 // 5-minute window for the destructive op

function challengeKey(token: string): string {
  return `cabinet:reauth:challenge:${token}`
}

export function otuKey(token: string): string {
  return `cabinet:reauth:otu:${token}`
}

interface VerifyBody {
  challenge_token: string
  password: string
}

export async function POST(req: NextRequest) {
  const guard = await requireProvisioningAccess()
  if (guard.response) return guard.response

  let body: VerifyBody
  try {
    body = (await req.json()) as VerifyBody
  } catch {
    return NextResponse.json({ ok: false, message: 'Invalid JSON body' }, { status: 400 })
  }

  if (!body.challenge_token) {
    return NextResponse.json(
      { ok: false, message: 'challenge_token is required' },
      { status: 400 }
    )
  }
  if (!body.password) {
    return NextResponse.json(
      { ok: false, message: 'password is required' },
      { status: 400 }
    )
  }

  // Verify challenge token exists and is still 'pending'
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = redis as any
  let challengeState: string | null = null
  try {
    challengeState = await redis.get(challengeKey(body.challenge_token))
  } catch (err) {
    console.error('[reauth-verify] Redis error reading challenge', err)
    return NextResponse.json({ ok: false, message: 'Could not verify challenge token' }, { status: 500 })
  }

  if (!challengeState || challengeState !== 'pending') {
    return NextResponse.json(
      { ok: false, message: 'Challenge token is invalid, expired, or already used' },
      { status: 401 }
    )
  }

  // Verify password using constant-time comparison
  if (!checkPassword(body.password)) {
    return NextResponse.json(
      { ok: false, message: 'Incorrect password' },
      { status: 401 }
    )
  }

  // Password correct: consume challenge + issue OTU token
  try {
    // Mark challenge as consumed (so it can't be reused even if TTL hasn't expired)
    if (typeof r.set === 'function') {
      await r.set(challengeKey(body.challenge_token), 'consumed', 'EX', 60)
    } else {
      await redis.set(challengeKey(body.challenge_token), 'consumed')
    }
  } catch (err) {
    console.warn('[reauth-verify] Could not mark challenge consumed', err)
  }

  const otuToken = crypto.randomBytes(32).toString('hex')
  try {
    if (typeof r.set === 'function') {
      await r.set(otuKey(otuToken), 'valid', 'EX', OTU_TTL_SECONDS)
    } else {
      await redis.set(otuKey(otuToken), 'valid')
    }
  } catch (err) {
    console.error('[reauth-verify] Redis error storing OTU token', err)
    return NextResponse.json({ ok: false, message: 'Could not issue OTU token' }, { status: 500 })
  }

  return NextResponse.json(
    {
      ok: true,
      otu_token: otuToken,
      expires_in_seconds: OTU_TTL_SECONDS,
    },
    { status: 200 }
  )
}
