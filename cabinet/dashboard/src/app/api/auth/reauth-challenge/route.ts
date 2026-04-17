/**
 * Spec 034 PR 5 — POST /api/auth/reauth-challenge
 *
 * Issues a short-lived re-authentication challenge token (step 1 of 2).
 * The client calls this when the Captain is about to perform a destructive op
 * (archive). The challenge token is stored in Redis with a 5-minute TTL.
 *
 * Step 2: POST /api/auth/reauth-verify — Captain submits password + challenge token.
 * Step 3: Destructive endpoint receives one-time-use (OTU) token from verify.
 *
 * Flow:
 *  1. POST /api/auth/reauth-challenge → { challenge_token }
 *  2. Captain enters password
 *  3. POST /api/auth/reauth-verify { challenge_token, password } → { otu_token }
 *  4. POST /api/cabinets/:id/archive { confirm_name, otu_token } — OTU validated + consumed
 *
 * Why a two-step challenge vs direct password POST:
 *  The challenge token binds the re-auth attempt to a specific client/session,
 *  preventing replay attacks where an intercepted verify request is reused.
 *
 * Spec refs: AC 15 (re-auth for archive), COO 034.7.
 */

import { NextRequest, NextResponse } from 'next/server'
import { requireProvisioningAccess } from '@/lib/provisioning/guard'
import crypto from 'crypto'
import redis from '@/lib/redis'

export const dynamic = 'force-dynamic'

const CHALLENGE_TTL_SECONDS = 5 * 60 // 5 minutes

function challengeKey(token: string): string {
  return `cabinet:reauth:challenge:${token}`
}

export async function POST(req: NextRequest) {
  // Must have an active session to request a re-auth challenge
  const guard = await requireProvisioningAccess()
  if (guard.response) return guard.response

  // Generate a cryptographically random challenge token
  const challengeToken = crypto.randomBytes(32).toString('hex')

  // Store in Redis with TTL (value = 'pending' — verify step marks it 'consumed')
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const r = redis as any
    if (typeof r.set === 'function') {
      await r.set(challengeKey(challengeToken), 'pending', 'EX', CHALLENGE_TTL_SECONDS)
    } else {
      await redis.set(challengeKey(challengeToken), 'pending')
    }
  } catch (err) {
    console.error('[reauth-challenge] Redis error', err)
    return NextResponse.json(
      { ok: false, message: 'Failed to issue challenge token' },
      { status: 500 }
    )
  }

  return NextResponse.json(
    {
      ok: true,
      challenge_token: challengeToken,
      expires_in_seconds: CHALLENGE_TTL_SECONDS,
    },
    { status: 200 }
  )
}
