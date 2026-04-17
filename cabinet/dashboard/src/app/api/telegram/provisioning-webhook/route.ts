/**
 * Spec 034 PR 4 — POST /api/telegram/provisioning-webhook
 *
 * Telegram webhook endpoint for the manager bot's conversational provisioning
 * flow. Telegram calls this URL with each incoming message.
 *
 * Auth: Verifies `chat_id` against `CAPTAIN_TELEGRAM_CHAT_ID` env var.
 *       Non-Captain chat_ids receive a 403 and no bot reply.
 *
 * Dispatches to `provisioning-flow.ts` for state machine logic.
 * Replies to Captain via Telegram Bot API (sendMessage).
 *
 * Feature flag: Returns 503 if CABINETS_PROVISIONING_ENABLED is not set.
 *
 * Polling: After all bots adopted, starts a background polling loop that
 * sends live status updates. PR 5 will replace this with SSE push.
 *
 * Spec refs: §2 "Conversational Telegram flow", AC 4, 11, 12
 */

import { NextRequest, NextResponse } from 'next/server'
import { featureFlagCheck } from '@/lib/provisioning/guard'
import {
  handleMessage,
  startPollingLoop,
  loadState,
} from '../../../../../../telegram-manager-bot/provisioning-flow'
import type { BotMessage } from '../../../../../../telegram-manager-bot/provisioning-flow'

export const dynamic = 'force-dynamic'

// ---------------------------------------------------------------------------
// Types — Telegram Update subset
// ---------------------------------------------------------------------------

interface TelegramUser {
  id: number
  first_name: string
  username?: string
}

interface TelegramChat {
  id: number
  type: string
}

interface TelegramMessage {
  message_id: number
  from?: TelegramUser
  chat: TelegramChat
  text?: string
  /** Set when message is a forward — present for BotFather forward flow */
  forward_from?: TelegramUser
  /** Caption for forwarded messages */
  caption?: string
  /** Date (Unix timestamp) */
  date: number
}

interface TelegramUpdate {
  update_id: number
  message?: TelegramMessage
}

// ---------------------------------------------------------------------------
// Captain authentication
// ---------------------------------------------------------------------------

/**
 * Verify that the incoming message is from the configured Captain chat.
 *
 * CAPTAIN_TELEGRAM_CHAT_ID is the Captain's personal chat_id (integer as string).
 * This single-Captain guard is intentional per spec §out-of-scope:
 * "Multi-Captain support is Phase 4".
 */
function isCaptainChat(chatId: number): boolean {
  const configured = process.env.CAPTAIN_TELEGRAM_CHAT_ID
  if (!configured) {
    // If not configured, fail-closed: reject all (safe default)
    console.warn('[provisioning-webhook] CAPTAIN_TELEGRAM_CHAT_ID not set — rejecting all messages')
    return false
  }
  return String(chatId) === configured.trim()
}

// ---------------------------------------------------------------------------
// Telegram API sender
// ---------------------------------------------------------------------------

const TELEGRAM_API_BASE = 'https://api.telegram.org/bot'

/**
 * Send a text message to a Telegram chat via the Bot API.
 * Uses MANAGER_BOT_TOKEN env var.
 *
 * Markdown parse_mode: 'Markdown' (v1) — safe for our backtick/bold patterns.
 * Messages longer than 4096 chars are truncated (Telegram limit).
 */
async function sendTelegramMessage(
  chatId: number,
  text: string,
  replyToMessageId?: number
): Promise<void> {
  const token = process.env.MANAGER_BOT_TOKEN
  if (!token) {
    console.error('[provisioning-webhook] MANAGER_BOT_TOKEN not set — cannot send message')
    return
  }

  const truncated = text.length > 4096 ? text.slice(0, 4093) + '…' : text

  const body: Record<string, unknown> = {
    chat_id: chatId,
    text: truncated,
    parse_mode: 'Markdown',
  }
  if (replyToMessageId) {
    body.reply_to_message_id = replyToMessageId
  }

  try {
    const res = await fetch(`${TELEGRAM_API_BASE}${token}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    if (!res.ok) {
      const err = await res.text()
      console.error('[provisioning-webhook] sendMessage failed:', err)
    }
  } catch (err) {
    console.error('[provisioning-webhook] sendMessage error:', err)
  }
}

/**
 * Send all BotMessages from the flow handler to Telegram.
 * First message threads to the Captain's original message_id.
 */
async function sendReplies(
  chatId: number,
  messages: BotMessage[],
  replyToId?: number
): Promise<void> {
  for (let i = 0; i < messages.length; i++) {
    const msg = messages[i]
    await sendTelegramMessage(chatId, msg.text, i === 0 ? replyToId : undefined)
    // If message has additional chained messages, send them too
    if (msg.additional) {
      for (const extra of msg.additional) {
        await sendTelegramMessage(chatId, extra.text)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Webhook handler
// ---------------------------------------------------------------------------

export async function POST(req: NextRequest): Promise<NextResponse> {
  // Feature flag guard
  const flagResponse = featureFlagCheck()
  if (flagResponse) return flagResponse

  // Parse update
  let update: TelegramUpdate
  try {
    update = (await req.json()) as TelegramUpdate
  } catch {
    // Telegram retries on non-200; return 200 to ack and drop
    return NextResponse.json({ ok: true })
  }

  const message = update.message
  if (!message) {
    // Non-message update (callback query, etc.) — not handled in PR 4
    return NextResponse.json({ ok: true })
  }

  const chatId = message.chat.id
  const messageId = message.message_id

  // --- Captain-auth guard ---
  if (!isCaptainChat(chatId)) {
    console.warn(`[provisioning-webhook] Rejected message from unauthorized chat_id: ${chatId}`)
    // 200 to stop Telegram retries; no reply to non-Captain chats
    return NextResponse.json({ ok: true })
  }

  // Extract text — prefer text field, fall back to caption (forwarded media)
  const rawText = message.text || message.caption || ''

  if (!rawText.trim()) {
    // Non-text message (photo, sticker, etc.) — ignore in PR 4
    return NextResponse.json({ ok: true })
  }

  // Token redaction for logging
  const logSafeText = rawText.replace(/[0-9]{8,12}:[a-zA-Z0-9_-]{35,}/g, '[TOKEN_REDACTED]')
  console.log(`[provisioning-webhook] chat=${chatId} text="${logSafeText}"`)

  // ------------------------------------------------------------------
  // Dispatch to state machine
  // ------------------------------------------------------------------
  let replies: BotMessage[]
  try {
    replies = await handleMessage(String(chatId), rawText)
  } catch (err) {
    console.error('[provisioning-webhook] handleMessage error:', err)
    await sendTelegramMessage(chatId, 'Something went wrong. Please try again or say "cancel".')
    return NextResponse.json({ ok: true })
  }

  // Send replies back to Captain
  if (replies.length > 0) {
    await sendReplies(chatId, replies, messageId)
  }

  // ------------------------------------------------------------------
  // Start polling loop if we just entered polling_status
  // ------------------------------------------------------------------
  const stateAfter = await loadState(String(chatId))
  if (stateAfter?.step === 'polling_status' && stateAfter.cabinetId) {
    // Fire-and-forget: polling loop runs in background
    // Note: In Vercel serverless, this runs until function timeout.
    // PR 5 will replace with a proper queue/SSE mechanism.
    startPollingLoop(
      String(chatId),
      stateAfter,
      async (msg) => {
        await sendTelegramMessage(chatId, msg.text)
      }
    ).catch((err) => {
      console.error('[provisioning-webhook] polling loop error:', err)
    })
  }

  // Always return 200 — Telegram retries on any non-2xx
  return NextResponse.json({ ok: true })
}

// ---------------------------------------------------------------------------
// GET — health check for webhook registration verification
// ---------------------------------------------------------------------------

export async function GET(): Promise<NextResponse> {
  return NextResponse.json({
    ok: true,
    endpoint: 'provisioning-webhook',
    note: 'POST only — this endpoint receives Telegram updates',
  })
}
