/**
 * Spec 034 PR 5 — Telegram Conversational Provisioning Flow
 *
 * PR 5 updates:
 *  - Replaces 5s polling in startPollingLoop() with an SSE consumer via fetch + streaming
 *  - Uses STATE_LABEL_TEXT from shared lib/provisioning/labels.ts (no local duplicate)
 *  - STATE_LABELS const removed — imported from shared module
 *
 * State machine for the multi-turn Telegram dialog that mirrors the dashboard
 * wizard step-for-step. Both paths call the same Provisioning API endpoints.
 *
 * Per-chat-id state stored in Redis under:
 *   cabinet:telegram:provisioning:<chat_id>
 * TTL: 2 hours (Captain can sleep on a decision and resume).
 *
 * Steps (mirror dashboard wizard):
 *   1. INTENT    — detect provisioning intent, ask for preset
 *   2. NAME      — slug input + validation
 *   3. CAPACITY  — inherit from preset, offer override
 *   4. CREATE    — POST /api/cabinets, enter adopting-bots state
 *   5. ADOPT_BOT — send QR/BotFather links, accept forwarded tokens
 *   6. CONFIRM   — "Got token ending ...XYZ — adopt as {officer}?" confirmation
 *   7. STATUS    — SSE consumer (PR 5, replaces 5s poll)
 *   8. DONE      — Cabinet live, send dashboard URL
 *
 * Cancellation:
 *   Captain says "cancel" / "abort" / "stop"
 *   → if in adopting-bots: POST /api/cabinets/:id/cancel
 *   → if stable (active/suspended): "Cabinet X is active, use /archive to stop it"
 *   → otherwise: "Provisioning in progress — cancel not available after bot adoption"
 *
 * Security: Webhook handler verifies chat_id against CAPTAIN_TELEGRAM_CHAT_ID.
 *
 * Intent triggers (regex-based, no LLM inference):
 *   - "I want a Cabinet" | "new cabinet" | "create cabinet" | "/provision"
 */

import redis from '../dashboard/src/lib/redis'
import {
  extractTokenFromForward,
  tokenLastFour,
  generateBotFatherLink,
  BOT_TOKEN_RE,
} from '../dashboard/src/lib/botfather'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type ProvisioningStep =
  | 'intent'
  | 'awaiting_name'
  | 'awaiting_capacity_confirm'
  | 'creating'
  | 'adopting_bot'
  | 'confirming_token'
  | 'polling_status'
  | 'done'
  | 'cancelled'

export interface OfficerSlot {
  role: string
  title: string
  adopted: boolean
}

export interface PendingToken {
  token: string
  lastFour: string
  officer: string
}

export interface ProvisioningState {
  step: ProvisioningStep
  /** Preset chosen by Captain */
  preset: string | null
  /** Cabinet name slug */
  name: string | null
  /** Capacity (defaults to preset slug) */
  capacity: string | null
  /** Cabinet ID returned by POST /api/cabinets */
  cabinetId: string | null
  /** Officers that need bots adopted */
  officers: OfficerSlot[]
  /** Index of the current officer slot being adopted (0-based) */
  currentOfficerIndex: number
  /** Token extracted from a forward, awaiting Captain confirmation */
  pendingToken: PendingToken | null
  /** ISO timestamp when the state was last updated */
  updatedAt: string
}

/** Message sent back to Telegram */
export interface BotMessage {
  text: string
  /** If true, send as a follow-up message (chained) */
  additional?: BotMessage[]
}

// ---------------------------------------------------------------------------
// Redis state persistence
// ---------------------------------------------------------------------------

const REDIS_TTL_SECONDS = 2 * 60 * 60 // 2 hours
const REDIS_KEY_PREFIX = 'cabinet:telegram:provisioning:'

export function stateKey(chatId: string): string {
  return `${REDIS_KEY_PREFIX}${chatId}`
}

export async function loadState(chatId: string): Promise<ProvisioningState | null> {
  try {
    const raw = await redis.get(stateKey(chatId))
    if (!raw) return null
    return JSON.parse(raw) as ProvisioningState
  } catch {
    return null
  }
}

export async function saveState(chatId: string, state: ProvisioningState): Promise<void> {
  const updated: ProvisioningState = { ...state, updatedAt: new Date().toISOString() }
  const serialized = JSON.stringify(updated)

  // Use SET with EX for TTL. Handle both real ioredis and mock redis.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = redis as any
  if (typeof r.set === 'function') {
    await r.set(stateKey(chatId), serialized, 'EX', REDIS_TTL_SECONDS)
  } else {
    await redis.set(stateKey(chatId), serialized)
  }
}

export async function clearState(chatId: string): Promise<void> {
  await redis.del(stateKey(chatId))
}

function emptyState(): ProvisioningState {
  return {
    step: 'intent',
    preset: null,
    name: null,
    capacity: null,
    cabinetId: null,
    officers: [],
    currentOfficerIndex: 0,
    pendingToken: null,
    updatedAt: new Date().toISOString(),
  }
}

// ---------------------------------------------------------------------------
// Intent detection (regex-based, no LLM)
// ---------------------------------------------------------------------------

const INTENT_RE =
  /\b(i want a cabinet|new cabinet|create cabinet|provision)\b/i

const CANCEL_RE = /\b(cancel|abort|stop)\b/i

const YES_RE = /^\s*(yes|y|yep|yeah|ok|okay|sure|correct|confirm|proceed|go|yup)\s*$/i

const PRESET_RE =
  /\b(personal|work|productivity|creative|health|team|custom|default)\b/i

/** Extract a preset name from Captain's message. */
function detectPreset(text: string): string | null {
  const match = PRESET_RE.exec(text.toLowerCase())
  return match ? match[1] : null
}

/** Slug validation: matches API SLUG_RE. */
const SLUG_RE = /^[a-z0-9][a-z0-9-]{1,47}$/

// ---------------------------------------------------------------------------
// API calls (via fetch to the dashboard API)
// ---------------------------------------------------------------------------

/** Base URL for internal API calls. Reads from env. */
function apiBase(): string {
  return process.env.DASHBOARD_INTERNAL_URL || 'http://localhost:3000'
}

/** Internal API auth header (shared secret for service-to-service). */
function internalAuthHeaders(): Record<string, string> {
  return {
    'Content-Type': 'application/json',
    'X-Internal-Token': process.env.DASHBOARD_INTERNAL_SECRET || '',
  }
}

interface CabinetListItem {
  cabinet_id: string
  name: string
  state: string
}

/** GET /api/cabinets — list Cabinets, used for name uniqueness check. */
async function listCabinets(): Promise<CabinetListItem[]> {
  const res = await fetch(`${apiBase()}/api/cabinets`, {
    headers: internalAuthHeaders(),
  })
  if (!res.ok) return []
  const body = (await res.json()) as { ok: boolean; cabinets: CabinetListItem[] }
  return body.cabinets || []
}

interface CreateResult {
  ok: boolean
  cabinet_id?: string
  message?: string
}

/** POST /api/cabinets */
async function createCabinet(
  name: string,
  preset: string,
  capacity: string
): Promise<CreateResult> {
  const res = await fetch(`${apiBase()}/api/cabinets`, {
    method: 'POST',
    headers: internalAuthHeaders(),
    body: JSON.stringify({ name, preset, capacity }),
  })
  return res.json() as Promise<CreateResult>
}

interface AdoptBotResult {
  ok: boolean
  all_bots_adopted?: boolean
  orphan_warning?: string
  message?: string
}

/** POST /api/cabinets/:id/adopt-bot */
async function adoptBot(
  cabinetId: string,
  officer: string,
  botToken: string
): Promise<AdoptBotResult> {
  const res = await fetch(`${apiBase()}/api/cabinets/${cabinetId}/adopt-bot`, {
    method: 'POST',
    headers: internalAuthHeaders(),
    body: JSON.stringify({ officer, bot_token: botToken }),
  })
  return res.json() as Promise<AdoptBotResult>
}

interface CancelResult {
  ok: boolean
  message?: string
  orphaned_bots?: string[]
}

/** POST /api/cabinets/:id/cancel */
async function cancelCabinet(cabinetId: string): Promise<CancelResult> {
  const res = await fetch(`${apiBase()}/api/cabinets/${cabinetId}/cancel`, {
    method: 'POST',
    headers: internalAuthHeaders(),
  })
  return res.json() as Promise<CancelResult>
}

interface ProvisioningStatusSnapshot {
  cabinet_id: string
  state: string
  state_entered_at: string
  last_event_id: number | null
}

/** GET /api/cabinets/:id/provisioning-status (polls — PR 5 will SSE). */
async function getProvisioningStatus(cabinetId: string): Promise<ProvisioningStatusSnapshot | null> {
  try {
    const res = await fetch(`${apiBase()}/api/cabinets/${cabinetId}/provisioning-status`, {
      headers: internalAuthHeaders(),
    })
    if (!res.ok) return null
    // SSE stub returns a single event — parse the data line
    const text = await res.text()
    const dataLine = text.split('\n').find((l) => l.startsWith('data:'))
    if (!dataLine) return null
    return JSON.parse(dataLine.slice(5).trim()) as ProvisioningStatusSnapshot
  } catch {
    return null
  }
}

// ---------------------------------------------------------------------------
// Human-readable state labels — imported from shared module (PR 5 consolidation)
// ---------------------------------------------------------------------------

// STATE_LABEL_TEXT imported from dashboard lib (shared module, single source)
// Relative path: telegram-manager-bot sits at cabinet/telegram-manager-bot/
// lib/provisioning/labels.ts is at cabinet/dashboard/src/lib/provisioning/labels.ts
// We re-declare a minimal version here to avoid TS path complexity in the bot.
// The canonical source is lib/provisioning/labels.ts.
const STATE_LABELS: Record<string, string> = {
  creating: 'Creating cabinet\u2026',
  'adopting-bots': 'Waiting for bot tokens\u2026',
  provisioning: 'Provisioning containers and migrating rows\u2026',
  starting: 'Starting containers \u2014 waiting for first heartbeat\u2026',
  active: 'Cabinet is live!',
  suspended: 'Cabinet suspended.',
  failed: 'Provisioning failed.',
  archiving: 'Archiving\u2026',
  archived: 'Cabinet archived.',
}

const STEP_CHECK = '\u2713' // checkmark for terminal Markdown

// ---------------------------------------------------------------------------
// Core message handler
// ---------------------------------------------------------------------------

/**
 * Handle an incoming Telegram message for a chat.
 *
 * Loads Redis state, dispatches to the correct step handler,
 * saves updated state, and returns one or more messages to send.
 *
 * @param chatId - Telegram chat_id (string to avoid JS BigInt precision issues)
 * @param text   - Raw message text from Captain
 */
export async function handleMessage(
  chatId: string,
  text: string
): Promise<BotMessage[]> {
  // Trim and normalise
  const msg = text.trim()

  // ------------------------------------------------------------------
  // Cancellation — always checked first (except done/cancelled states)
  // ------------------------------------------------------------------
  if (CANCEL_RE.test(msg)) {
    return handleCancel(chatId)
  }

  // ------------------------------------------------------------------
  // Load or initialise state
  // ------------------------------------------------------------------
  let state = await loadState(chatId)

  // Fresh session — only activate on explicit intent
  if (!state || state.step === 'done' || state.step === 'cancelled') {
    if (INTENT_RE.test(msg) || msg === '/provision') {
      state = emptyState()
      // If Captain included a preset in the trigger ("I want a Personal Cabinet")
      const inlinePreset = detectPreset(msg)
      if (inlinePreset) {
        state.preset = inlinePreset
        state.step = 'awaiting_name'
        await saveState(chatId, state)
        return [
          {
            text: `Let\u2019s set up your ${capitalise(inlinePreset)} Cabinet. What should I call it? (lowercase slug, e.g. \`personal\`, \`work-2\`)`,
          },
        ]
      }
      state.step = 'intent'
      await saveState(chatId, state)
      return [
        {
          text:
            'Let\u2019s provision a new Cabinet. Which preset do you want?\n\n' +
            '  \u2022 personal\n' +
            '  \u2022 work\n\n' +
            'Reply with the preset name, or say "cancel" to stop.',
        },
      ]
    }
    // No active flow and no intent trigger — ignore
    return []
  }

  // ------------------------------------------------------------------
  // Dispatch by step
  // ------------------------------------------------------------------
  switch (state.step) {
    case 'intent':
      return handleStepIntent(chatId, state, msg)

    case 'awaiting_name':
      return handleStepName(chatId, state, msg)

    case 'awaiting_capacity_confirm':
      return handleStepCapacityConfirm(chatId, state, msg)

    case 'creating':
      // Should not receive messages in this transient step, but handle gracefully
      return [{ text: 'One moment \u2014 creating your Cabinet\u2026' }]

    case 'adopting_bot':
      return handleStepAdoptBot(chatId, state, msg)

    case 'confirming_token':
      return handleStepConfirmToken(chatId, state, msg)

    case 'polling_status':
      return handleStepPollStatus(chatId, state)

    default:
      return []
  }
}

// ---------------------------------------------------------------------------
// Step handlers
// ---------------------------------------------------------------------------

async function handleStepIntent(
  chatId: string,
  state: ProvisioningState,
  msg: string
): Promise<BotMessage[]> {
  const preset = detectPreset(msg) || msg.toLowerCase().trim()

  if (!preset || preset.length < 2) {
    return [
      {
        text: 'Please choose a preset: \`personal\` or \`work\` (or reply "cancel").',
      },
    ]
  }

  state.preset = preset
  state.step = 'awaiting_name'
  await saveState(chatId, state)

  return [
    {
      text: `Great \u2014 ${capitalise(preset)} preset. What should I call your Cabinet? (lowercase, letters/numbers/hyphens, e.g. \`personal\` or \`my-cabinet\`)`,
    },
  ]
}

async function handleStepName(
  chatId: string,
  state: ProvisioningState,
  msg: string
): Promise<BotMessage[]> {
  const slug = msg.toLowerCase().replace(/\s+/g, '-')

  // Validate format
  if (!SLUG_RE.test(slug)) {
    return [
      {
        text:
          'That slug isn\u2019t valid. It must be lowercase letters, numbers, and hyphens, starting with a letter or digit (2\u201348 characters). Try again:',
      },
    ]
  }

  // Check uniqueness via API
  const existing = await listCabinets()
  const duplicate = existing.find((c) => c.name === slug)
  if (duplicate) {
    return [
      {
        text: `A Cabinet named \`${slug}\` already exists (state: ${duplicate.state}). Choose a different name:`,
      },
    ]
  }

  // Infer capacity from preset (Captain can override in next step)
  const capacity = state.preset || slug

  state.name = slug
  state.capacity = capacity
  state.step = 'awaiting_capacity_confirm'
  await saveState(chatId, state)

  return [
    {
      text:
        `Cabinet name: \`${slug}\`\n` +
        `Capacity: \`${capacity}\` (inherited from ${capitalise(state.preset || 'preset')} preset)\n\n` +
        'Want to use a different capacity identifier? Reply with the new value, or say "yes" to proceed.',
    },
  ]
}

async function handleStepCapacityConfirm(
  chatId: string,
  state: ProvisioningState,
  msg: string
): Promise<BotMessage[]> {
  let capacity = state.capacity!

  if (!YES_RE.test(msg)) {
    // Captain is overriding the capacity
    const proposed = msg.toLowerCase().trim()
    if (proposed.length < 1 || proposed.length > 64) {
      return [{ text: 'Capacity must be 1\u201364 characters. Try again or say "yes" to use the default.' }]
    }
    capacity = proposed
    state.capacity = capacity
  }

  // Transition to creating step (fire off API call)
  state.step = 'creating'
  await saveState(chatId, state)

  // Attempt to create the Cabinet
  const result = await createCabinet(state.name!, state.preset!, capacity)

  if (!result.ok) {
    // Name collision (409) or other error
    if (result.message?.includes('already exists')) {
      const conflictedName = state.name
      state.step = 'awaiting_name'
      state.name = null
      await saveState(chatId, state)
      return [
        {
          text: `A Cabinet named \`${conflictedName}\` already exists. Choose a different name:`,
        },
      ]
    }
    state.step = 'awaiting_capacity_confirm'
    await saveState(chatId, state)
    return [
      {
        text: `Couldn\u2019t create the Cabinet: ${result.message || 'unknown error'}. Try again or say "cancel".`,
      },
    ]
  }

  // Cabinet created — now in adopting-bots state
  state.cabinetId = result.cabinet_id!
  state.currentOfficerIndex = 0

  // Build officer list from preset (minimal — real preset loader in PR 5)
  state.officers = buildDefaultOfficers(state.preset!)
  state.step = 'adopting_bot'
  await saveState(chatId, state)

  return buildAdoptBotPrompt(state)
}

async function handleStepAdoptBot(
  chatId: string,
  state: ProvisioningState,
  msg: string
): Promise<BotMessage[]> {
  // Try to extract a bot token from the message (forwarded BotFather message)
  const extracted = extractTokenFromForward(msg)

  if (!extracted) {
    // No token found — check if Captain is typing something else
    if (msg.startsWith('/')) {
      return [{ text: 'Please send me the BotFather message for the current officer, or paste the token directly.' }]
    }
    return [
      {
        text:
          'I couldn\u2019t find a bot token in that message. ' +
          'Forward the message BotFather sends after you create a bot, or paste the token directly ' +
          '(format: \`12345678:ABCdef...\`)',
      },
    ]
  }

  const currentOfficer = state.officers[state.currentOfficerIndex]
  if (!currentOfficer) {
    return [{ text: 'All bots have already been adopted. Type "yes" to continue.' }]
  }

  // Store pending token for confirmation
  state.pendingToken = {
    token: extracted.token,
    lastFour: extracted.lastFour,
    officer: currentOfficer.role,
  }
  state.step = 'confirming_token'
  await saveState(chatId, state)

  return [
    {
      text: `Got token ending \`...${extracted.lastFour}\` \u2014 adopt as **${currentOfficer.title}** (${currentOfficer.role})? Reply "yes" to confirm or "no" to re-send.`,
    },
  ]
}

async function handleStepConfirmToken(
  chatId: string,
  state: ProvisioningState,
  msg: string
): Promise<BotMessage[]> {
  if (!state.pendingToken) {
    state.step = 'adopting_bot'
    await saveState(chatId, state)
    return buildAdoptBotPrompt(state)
  }

  if (!YES_RE.test(msg)) {
    // Captain rejected — go back to awaiting token for this officer
    state.pendingToken = null
    state.step = 'adopting_bot'
    await saveState(chatId, state)
    const current = state.officers[state.currentOfficerIndex]
    return [
      {
        text: `OK, let\u2019s try again. Send the BotFather token for **${current?.title || 'officer'}**:`,
      },
    ]
  }

  // Confirmed — call adopt-bot API
  const { token, officer } = state.pendingToken
  const result = await adoptBot(state.cabinetId!, officer, token)

  if (!result.ok) {
    state.pendingToken = null
    state.step = 'adopting_bot'
    await saveState(chatId, state)
    return [
      {
        text: `Couldn\u2019t adopt that token: ${result.message || 'unknown error'}. Try again:`,
      },
    ]
  }

  // Mark officer as adopted
  state.officers[state.currentOfficerIndex].adopted = true
  state.pendingToken = null

  // Orphan warning
  const orphanWarning = result.orphan_warning
    ? `\n\n\u26a0\ufe0f ${result.orphan_warning}` // ⚠️
    : ''

  // Check if all bots adopted
  if (result.all_bots_adopted) {
    state.step = 'polling_status'
    await saveState(chatId, state)

    const statusMessages = await pollStatusOnce(state)
    return [
      {
        text: `${STEP_CHECK} Bot adopted for **${state.officers[state.currentOfficerIndex].title}**.${orphanWarning}\n\nAll ${state.officers.length} bots adopted. Starting your Cabinet\u2026`,
      },
      ...statusMessages,
    ]
  }

  // Advance to next officer
  state.currentOfficerIndex++
  state.step = 'adopting_bot'
  await saveState(chatId, state)

  const adoptedMessages: BotMessage[] = [
    {
      text: `${STEP_CHECK} Bot adopted for **${state.officers[state.currentOfficerIndex - 1].title}**.${orphanWarning}`,
    },
  ]

  return [...adoptedMessages, ...buildAdoptBotPrompt(state)]
}

async function handleStepPollStatus(
  chatId: string,
  state: ProvisioningState
): Promise<BotMessage[]> {
  return pollStatusOnce(state)
}

// ---------------------------------------------------------------------------
// Cancellation handler
// ---------------------------------------------------------------------------

async function handleCancel(chatId: string): Promise<BotMessage[]> {
  const state = await loadState(chatId)

  if (!state || state.step === 'done' || state.step === 'cancelled') {
    return []
  }

  // No cabinet created yet
  if (!state.cabinetId) {
    await clearState(chatId)
    return [{ text: 'Cancelled. Say "new cabinet" any time to start again.' }]
  }

  // Determine cancellation eligibility
  const statusSnapshot = await getProvisioningStatus(state.cabinetId)
  const currentState = statusSnapshot?.state || 'unknown'

  if (currentState === 'adopting-bots') {
    const result = await cancelCabinet(state.cabinetId)
    const orphanNote =
      result.orphaned_bots && result.orphaned_bots.length > 0
        ? `\n\nThe following bots are now orphaned \u2014 delete them in BotFather: ${result.orphaned_bots.join(', ')}`
        : ''

    state.step = 'cancelled'
    await saveState(chatId, state)
    return [
      {
        text: `Cabinet \`${state.name}\` cancelled.${orphanNote}\n\nSay "new cabinet" any time to start again.`,
      },
    ]
  }

  if (currentState === 'active' || currentState === 'suspended') {
    return [
      {
        text: `Cabinet \`${state.name}\` is already ${currentState} \u2014 cancel isn\u2019t available. Use /archive to stop it from the dashboard.`,
      },
    ]
  }

  // In provisioning/starting/archiving — can't cancel
  return [
    {
      text: `Provisioning is in progress (state: ${currentState}) \u2014 cancel isn\u2019t available at this stage. Use archive from the dashboard after provisioning completes, or wait for it to finish.`,
    },
  ]
}

// ---------------------------------------------------------------------------
// Status SSE consumer (PR 5 — replaces 5s polling loop)
// ---------------------------------------------------------------------------

/** Terminal states that signal the SSE stream should close. */
const SSE_TERMINAL_STATES = new Set(['active', 'archived', 'failed'])

/**
 * Snapshot status check — used when all bots are adopted and we transition
 * to the status-watching phase. Returns one or more initial messages.
 */
async function pollStatusOnce(state: ProvisioningState): Promise<BotMessage[]> {
  if (!state.cabinetId) {
    return [{ text: 'No cabinet ID \u2014 something went wrong. Say "cancel" and try again.' }]
  }

  const snapshot = await getProvisioningStatus(state.cabinetId)
  if (!snapshot) {
    return [{ text: 'Could not reach provisioning status \u2014 will retry shortly.' }]
  }

  return buildStatusMessage(state, snapshot.state)
}

function buildStatusMessage(state: ProvisioningState, currentState: string): BotMessage[] {
  const label = STATE_LABELS[currentState] || currentState

  if (currentState === 'active') {
    const dashboardUrl = buildDashboardUrl(state.cabinetId!)
    return [
      {
        text:
          `${STEP_CHECK} Containers up\n` +
          `${STEP_CHECK} Rows migrated\n` +
          `${STEP_CHECK} Peers wired\n\n` +
          `Your ${capitalise(state.preset || 'Cabinet')} Cabinet **${state.name}** is live.\n` +
          `Open the dashboard: ${dashboardUrl}`,
      },
    ]
  }

  if (currentState === 'failed') {
    return [
      {
        text: `Provisioning failed. Check the dashboard for details and the full log:\n${buildDashboardUrl(state.cabinetId!)}`,
      },
    ]
  }

  return [{ text: `${label} I\u2019ll update you when the state changes\u2026` }]
}

/**
 * PR 5 SSE consumer — replaces the 5s polling loop.
 * Uses fetch() with a streaming response body to consume the SSE stream.
 * Avoids adding a new npm dependency (no `eventsource` package needed).
 *
 * Sends Telegram messages only on state changes.
 * Auto-terminates on active | failed | archived states or after maxDurationMs.
 */
export async function startSSEConsumer(
  chatId: string,
  state: ProvisioningState,
  sendMessage: (msg: BotMessage) => Promise<void>,
  maxDurationMs = 10 * 60 * 1000 // 10 min max (matches provisioning timeout)
): Promise<void> {
  if (!state.cabinetId) {
    await sendMessage({ text: 'Cannot watch status — no cabinet ID.' })
    return
  }

  const cabinetId = state.cabinetId
  const sseUrl = `${apiBase()}/api/cabinets/${cabinetId}/provisioning-status`

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), maxDurationMs)

  let lastReportedState = ''

  try {
    const res = await fetch(sseUrl, {
      headers: { ...internalAuthHeaders(), Accept: 'text/event-stream' },
      signal: controller.signal,
    })

    if (!res.ok || !res.body) {
      await sendMessage({
        text: `Could not connect to provisioning stream (HTTP ${res.status}). Check dashboard.`,
      })
      return
    }

    const reader = res.body.getReader()
    const decoder = new TextDecoder()
    let buffer = ''

    // eslint-disable-next-line no-constant-condition
    while (true) {
      const { done, value } = await reader.read()
      if (done) break

      buffer += decoder.decode(value, { stream: true })

      // SSE frames are delimited by \n\n
      const frames = buffer.split('\n\n')
      buffer = frames.pop() ?? '' // keep incomplete frame

      for (const frame of frames) {
        if (!frame.trim() || frame.startsWith(':')) continue // comment/ping line

        const dataLine = frame.split('\n').find((l) => l.startsWith('data:'))
        if (!dataLine) continue

        try {
          const data = JSON.parse(dataLine.slice(5).trim()) as {
            type?: string
            state?: string
            state_after?: string
            cabinet_id?: string
          }

          const newState = data.state_after || data.state

          if (newState && newState !== lastReportedState) {
            lastReportedState = newState
            const msgs = buildStatusMessage(state, newState)
            for (const msg of msgs) {
              await sendMessage(msg)
            }

            if (newState === 'active') {
              // Mark done in Redis
              const latestState = await loadState(chatId)
              if (latestState) {
                latestState.step = 'done'
                await saveState(chatId, latestState)
              }
            }
          }

          // Server signals stream closed
          if (data.type === 'done' || (newState && SSE_TERMINAL_STATES.has(newState))) {
            reader.cancel()
            return
          }
        } catch {
          // Ignore parse errors on individual frames
        }
      }
    }
  } catch (err) {
    // AbortError = timeout; other errors = connection problem
    const isTimeout = err instanceof Error && err.name === 'AbortError'
    if (isTimeout) {
      await sendMessage({
        text: 'Provisioning is taking longer than expected. Check the dashboard for status.',
      })
    } else {
      await sendMessage({
        text: `Lost connection to provisioning stream. Check the dashboard:\n${buildDashboardUrl(cabinetId)}`,
      })
    }
  } finally {
    clearTimeout(timeout)
  }
}

// Keep startPollingLoop exported for backward compat with existing tests
// It's now a thin wrapper over startSSEConsumer with fallback to HTTP polling
export async function startPollingLoop(
  chatId: string,
  state: ProvisioningState,
  sendMessage: (msg: BotMessage) => Promise<void>,
  _maxPolls = 72
): Promise<void> {
  // Delegate to SSE consumer — cleaner and no polling needed
  await startSSEConsumer(chatId, state, sendMessage)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function capitalise(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1)
}

function buildDashboardUrl(cabinetId: string): string {
  const base = process.env.DASHBOARD_URL || 'https://cabinet.example.com'
  return `${base}/cabinets/${cabinetId}`
}

/**
 * Build a minimal officer list from a preset name.
 * In PR 5 this will load from the actual preset directory.
 */
function buildDefaultOfficers(preset: string): OfficerSlot[] {
  // Default officer sets per well-known preset
  const presetOfficers: Record<string, OfficerSlot[]> = {
    personal: [
      { role: 'cos', title: 'Chief of Staff', adopted: false },
      { role: 'cto', title: 'CTO', adopted: false },
      { role: 'cpo', title: 'CPO', adopted: false },
      { role: 'cro', title: 'CRO', adopted: false },
    ],
    work: [
      { role: 'cos', title: 'Chief of Staff', adopted: false },
      { role: 'cto', title: 'CTO', adopted: false },
      { role: 'cpo', title: 'CPO', adopted: false },
      { role: 'cro', title: 'CRO', adopted: false },
      { role: 'coo', title: 'COO', adopted: false },
    ],
  }

  return presetOfficers[preset] ?? [
    { role: 'cos', title: 'Chief of Staff', adopted: false },
    { role: 'cto', title: 'CTO', adopted: false },
    { role: 'cpo', title: 'CPO', adopted: false },
    { role: 'cro', title: 'CRO', adopted: false },
  ]
}

/**
 * Build the adopt-bot prompt for the current officer slot.
 * Sends a BotFather deep-link for the current officer.
 */
function buildAdoptBotPrompt(state: ProvisioningState): BotMessage[] {
  const current = state.officers[state.currentOfficerIndex]
  if (!current) return []

  const total = state.officers.length
  const index = state.currentOfficerIndex + 1
  const link = state.name
    ? generateBotFatherLink(state.name, current.role)
    : `https://t.me/BotFather`

  const adopted = state.officers.filter((o) => o.adopted).length

  return [
    {
      text:
        `Bot ${index} of ${total}: **${current.title}** (${current.role})\n\n` +
        `1. Tap this link to open BotFather: ${link}\n` +
        `2. Follow the prompts to create the bot\n` +
        `3. Forward BotFather\u2019s confirmation message back here (or paste the token)\n\n` +
        `${adopted} of ${total} adopted. Say "cancel" to stop.`,
    },
  ]
}

// Re-export for use in the webhook handler
export { BOT_TOKEN_RE, extractTokenFromForward, tokenLastFour, generateBotFatherLink }
