/**
 * Spec 034 PR 3 — POST /api/cabinets/[id]/adopt-bot-from-forward
 *
 * Accepts a raw Telegram-forwarded message body (JSON with the forwarded text),
 * extracts the bot token via regex, and returns the token's last-4-chars for
 * the dashboard confirmation prompt.
 *
 * IMPORTANT: This endpoint does NOT auto-register the token. It returns the
 * extracted token + last-4-chars so the UI can display:
 *   "Got token ending ...{lastFour} — adopt as {officer}?"
 * The Captain must confirm, then the UI calls POST /api/cabinets/[id]/adopt-bot
 * with the full token.
 *
 * Spec §3: "return the last 4 chars of the extracted token so the dashboard can
 * display a confirmation prompt before registering. No auto-registration without
 * display."
 *
 * Idempotency: This endpoint is read-only (no state mutation). The adopt-bot
 * endpoint handles (cabinet_id, officer_slot) idempotency.
 *
 * Auth: Requires Captain session (same guard as adopt-bot endpoint).
 *
 * Feature flag: Returns 503 if CABINETS_PROVISIONING_ENABLED is not set.
 */

import { NextRequest, NextResponse } from 'next/server'
import { requireProvisioningAccess } from '@/lib/provisioning/guard'
import { extractTokenFromForward } from '@/lib/botfather'

export const dynamic = 'force-dynamic'

interface ForwardBody {
  /** Raw text from a Telegram-forwarded message */
  raw_text: string
  /** Officer slot this forward is intended for (for logging/context) */
  officer?: string
}

interface ForwardResponse {
  ok: true
  /** Last 4 characters of the extracted token (for confirmation UI) */
  last_four: string
  /**
   * The extracted token — returned so the client can submit it to adopt-bot
   * after showing the confirmation prompt. Treat as sensitive; don't log.
   *
   * Security: This endpoint is behind session auth (Captain only). The token
   * is not persisted here — it's returned to the client for one-time use.
   * It will be redacted automatically by writeAuditEvent's redactPayload if
   * it ever appears in an audit payload (key contains 'token').
   */
  token: string
  /** Human-readable confirmation message for the UI to display */
  confirmation_message: string
}

export async function POST(
  req: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  // Auth + feature flag guard (same as adopt-bot)
  const guard = await requireProvisioningAccess()
  if (guard.response) return guard.response

  const { id } = await params

  let body: ForwardBody
  try {
    body = (await req.json()) as ForwardBody
  } catch {
    return NextResponse.json({ ok: false, message: 'Invalid JSON body' }, { status: 400 })
  }

  if (!body.raw_text || typeof body.raw_text !== 'string') {
    return NextResponse.json(
      { ok: false, message: 'raw_text is required' },
      { status: 400 }
    )
  }

  if (body.raw_text.length > 4096) {
    // Telegram message max is 4096 chars; reject oversized payloads
    return NextResponse.json(
      { ok: false, message: 'raw_text exceeds maximum length of 4096 characters' },
      { status: 400 }
    )
  }

  const extracted = extractTokenFromForward(body.raw_text)

  if (!extracted) {
    return NextResponse.json(
      {
        ok: false,
        message:
          'No valid bot token found in the message. ' +
          'Expected format: forward the message BotFather sent after creating a bot. ' +
          'It should contain a token like: 123456789:ABCdef...',
      },
      { status: 422 }
    )
  }

  const { token, lastFour } = extracted
  const officerLabel = body.officer ? ` as "${body.officer}"` : ''

  const response: ForwardResponse = {
    ok: true,
    last_four: lastFour,
    token,
    confirmation_message: `Got token ending ...${lastFour} — adopt${officerLabel}?`,
  }

  // Note: token appears in the response body (intentional — client needs it for
  // the subsequent adopt-bot call). It is transmitted over HTTPS/TLS only.
  // The dashboard input field uses type="password" semantics for display.
  return NextResponse.json(response)
}
