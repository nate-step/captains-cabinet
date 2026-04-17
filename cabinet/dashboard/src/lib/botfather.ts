/**
 * Spec 034 PR 3 — BotFather utility helpers
 *
 * Provides:
 *   - BOT_TOKEN_RE: canonical regex for Telegram bot token validation
 *   - generateBotFatherLink: BotFather deep-link for a given cabinet/officer pair
 *   - extractTokenFromForward: pull token out of raw BotFather message text
 *   - tokenLastFour: return last 4 chars of a token (for confirmation display)
 *   - isValidToken: boolean convenience wrapper
 *
 * Token format (per Telegram docs, current as of Apr 2026):
 *   {8-12 digits}:{35 base64url chars}
 * e.g. 123456789:ABCDEFabcdef_-1234567890ABCDEFabcde
 *
 * Security note: token values MUST NOT be logged. Callers are responsible for
 * ensuring they don't embed raw tokens in error messages or audit payloads that
 * aren't redacted. The audit.ts layer handles redaction automatically for any
 * payload key matching /token|secret|key|password/i.
 */

/** Canonical Telegram bot token regex (spec §3 + CTO Y2). */
export const BOT_TOKEN_RE = /[0-9]{8,12}:[a-zA-Z0-9_-]{35,}/

/**
 * Strict full-match version for input validation.
 * Requires exactly one token with no surrounding content.
 */
export const BOT_TOKEN_STRICT_RE = /^[0-9]{8,12}:[a-zA-Z0-9_-]{35}$/

/**
 * Generate a BotFather deep-link for a given cabinet slug and officer role.
 *
 * Telegram /start params allow only A-Z, a-z, 0-9, underscore and hyphen.
 * We construct: {cabinet-slug}-{officer-role} and replace any non-conforming
 * chars with hyphens.
 *
 * Spec §3: `https://t.me/BotFather?start={cabinet-slug}-{officer-role}`
 * Example: `https://t.me/BotFather?start=personal-executive-coach`
 */
export function generateBotFatherLink(cabinetSlug: string, officerRole: string): string {
  const sanitize = (s: string) => s.toLowerCase().replace(/[^a-z0-9-]/g, '-')
  const param = `${sanitize(cabinetSlug)}-${sanitize(officerRole)}`
  return `https://t.me/BotFather?start=${param}`
}

export interface ExtractedToken {
  /** The raw bot token string */
  token: string
  /** Last 4 characters of the token (post-colon portion), shown in confirmation UI */
  lastFour: string
}

/**
 * Extract a Telegram bot token from raw forwarded BotFather message text.
 *
 * BotFather sends something like:
 *   "Use this token to access the HTTP API: 1234567890:AAFabcdefghij-KLMNO_pqrstuvwxyz123"
 *   or just the token on its own line in some flows.
 *
 * Returns null if no valid token is found. Never throws.
 */
export function extractTokenFromForward(rawText: string): ExtractedToken | null {
  if (!rawText || typeof rawText !== 'string') return null

  const match = BOT_TOKEN_RE.exec(rawText)
  if (!match) return null

  const token = match[0]
  return {
    token,
    lastFour: tokenLastFour(token),
  }
}

/**
 * Return the last 4 characters of the token's secret part (after the colon).
 * Used in confirmation prompts: "Got token ending ...XYZ — adopt as {officer}?"
 *
 * Always returns exactly 4 chars. If the token is malformed, returns '????'.
 */
export function tokenLastFour(token: string): string {
  const colonIdx = token.indexOf(':')
  if (colonIdx < 0) return '????'
  const secret = token.slice(colonIdx + 1)
  if (secret.length < 4) return secret.padStart(4, '?')
  return secret.slice(-4)
}

/**
 * Validate a bot token string against the strict regex.
 * Safe to call client-side. Does not make network requests.
 */
export function isValidToken(token: string): boolean {
  return BOT_TOKEN_STRICT_RE.test(token.trim())
}
