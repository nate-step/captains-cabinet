/**
 * Spec 034 — Route guards for the Provisioning API
 *
 * Provides:
 *  - featureFlagCheck() — returns 503 if provisioning is disabled
 *  - authCheck() — returns 401 if no valid session
 *
 * Every mutating provisioning route calls both before doing any work.
 */

import { NextResponse } from 'next/server'
import { verifySession } from '@/lib/auth'
import { getDashboardConfig } from '@/lib/config'

/** Session user context extracted from cookie */
export interface SessionUser {
  /** Opaque token value used as actor ID in audit events */
  token: string
}

/**
 * Check if the CABINETS_PROVISIONING_ENABLED feature flag is active.
 * Returns a 503 Response if disabled, or null if enabled.
 *
 * Flag logic (per PR 1 plan):
 *   If consumer_mode_enabled === false AND env var not set → disabled.
 *   If either is true → enabled.
 */
export function featureFlagCheck(): NextResponse | null {
  const dashConfig = getDashboardConfig()
  const envEnabled = process.env.CABINETS_PROVISIONING_ENABLED === 'true'

  if (!dashConfig.consumerModeEnabled && !envEnabled) {
    return NextResponse.json(
      { ok: false, disabled: true, message: 'Cabinet provisioning not configured' },
      { status: 503 }
    )
  }
  return null
}

/**
 * Check that the request has a valid session cookie.
 * Returns a 401 Response if not authenticated, or null + session user if OK.
 */
export async function authCheck(): Promise<{ response: NextResponse; user: null } | { response: null; user: SessionUser }> {
  const valid = await verifySession()
  if (!valid) {
    return {
      response: NextResponse.json({ ok: false, message: 'Unauthorized' }, { status: 401 }),
      user: null,
    }
  }
  // The session is a signed token — use a stable identifier for audit actor.
  // For now we use a constant sentinel; PR 5 wires real user identity.
  return {
    response: null,
    user: { token: 'captain' },
  }
}

/**
 * Combined guard — feature flag + auth. Returns the first failure response,
 * or null + session user if both pass.
 */
export async function requireProvisioningAccess(): Promise<
  { response: NextResponse; user: null } | { response: null; user: SessionUser }
> {
  const flagResponse = featureFlagCheck()
  if (flagResponse) return { response: flagResponse, user: null }
  return authCheck()
}
