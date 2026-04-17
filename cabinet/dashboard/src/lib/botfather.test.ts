/**
 * Spec 034 PR 3 — botfather.ts unit tests
 *
 * Reference tests (vitest, not yet wired into CI — PR 5 scope).
 * Run manually: npx vitest run src/lib/botfather.test.ts
 *
 * Covers:
 *   - Regex extracts valid BotFather tokens from message text
 *   - Regex rejects malformed tokens
 *   - tokenLastFour returns expected shape
 *   - generateBotFatherLink produces correct URLs
 */

// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore — vitest not yet installed (PR 5 wires test runner); remove when vitest added to devDeps
import { describe, it, expect } from 'vitest'
import {
  extractTokenFromForward,
  tokenLastFour,
  generateBotFatherLink,
  isValidToken,
  BOT_TOKEN_STRICT_RE,
} from './botfather'

// ---------------------------------------------------------------------------
// Regex: valid tokens
// ---------------------------------------------------------------------------
describe('extractTokenFromForward — valid tokens', () => {
  it('extracts token from full BotFather message', () => {
    const msg =
      "Done! Congratulations on your new bot. You will find it at t.me/mybot. " +
      "Use this token to access the HTTP API:\n1234567890:AAFabcdefghijKLMNO_pqrstuvwxyz123\n\nKeep your token secure."
    const result = extractTokenFromForward(msg)
    expect(result).not.toBeNull()
    expect(result!.token).toBe('1234567890:AAFabcdefghijKLMNO_pqrstuvwxyz123')
    expect(result!.lastFour).toBe('z123')
  })

  it('extracts token when message is just the token', () => {
    const msg = '987654321:ABCdef_GHIjklMNOpqr-STUvwxyz1234'
    const result = extractTokenFromForward(msg)
    expect(result).not.toBeNull()
    expect(result!.token).toBe('987654321:ABCdef_GHIjklMNOpqr-STUvwxyz1234')
  })

  it('handles 12-digit bot ID (upper bound)', () => {
    const msg = '123456789012:AAFabcdefghijKLMNO_pqrstuvwxy'
    // 30 chars in secret portion — still valid if >= 35 per lenient regex
    // but strict requires exactly 35, let's test a valid 35-char secret
    const msg2 = '123456789012:AAFabcdefghijKLMNO_pqrstuvwxyz1'
    const result = extractTokenFromForward(msg2)
    expect(result).not.toBeNull()
  })

  it('handles 8-digit bot ID (lower bound)', () => {
    const msg = '12345678:ABCdef_GHIjklMNOpqr-STUvwxyz1234'
    const result = extractTokenFromForward(msg)
    expect(result).not.toBeNull()
    expect(result!.token).toBe('12345678:ABCdef_GHIjklMNOpqr-STUvwxyz1234')
  })

  it('handles token with hyphens and underscores in secret', () => {
    const token = '99988877:_abcDEF-ghiJKL_mnoPQR-stuVWX_yz1'
    const result = extractTokenFromForward(`Here is your token: ${token}`)
    expect(result).not.toBeNull()
    expect(result!.token).toBe(token)
  })
})

// ---------------------------------------------------------------------------
// Regex: malformed tokens rejected by isValidToken (strict)
// ---------------------------------------------------------------------------
describe('isValidToken — rejects malformed tokens', () => {
  it('rejects empty string', () => {
    expect(isValidToken('')).toBe(false)
  })

  it('rejects too-short bot ID (7 digits)', () => {
    expect(isValidToken('1234567:ABCdef_GHIjklMNOpqr-STUvwxyz1234')).toBe(false)
  })

  it('rejects too-long bot ID (13 digits)', () => {
    expect(isValidToken('1234567890123:ABCdef_GHIjklMNOpqr-STUvwxyz1')).toBe(false)
  })

  it('rejects too-short secret (34 chars)', () => {
    // 34 chars after colon — one short
    expect(isValidToken('123456789:ABCdef_GHIjklMNOpqr-STUvwxyz123')).toBe(false)
  })

  it('rejects token with invalid characters in secret', () => {
    // Contains '@' which is not in [a-zA-Z0-9_-]
    expect(isValidToken('123456789:ABCdef_GHIjklMNOpqr-STUvwxy@12')).toBe(false)
  })

  it('rejects plain text', () => {
    expect(isValidToken('not a token at all')).toBe(false)
  })

  it('rejects token missing colon separator', () => {
    expect(isValidToken('1234567890ABCdef_GHIjklMNOpqrSTUvwxyz1234')).toBe(false)
  })

  it('rejects token with spaces', () => {
    expect(isValidToken('123456789: ABCdef_GHIjklMNOpqr-STUvwxyz123')).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// extractTokenFromForward: edge cases
// ---------------------------------------------------------------------------
describe('extractTokenFromForward — edge cases', () => {
  it('returns null for null-ish input', () => {
    expect(extractTokenFromForward('')).toBeNull()
    // @ts-expect-error — testing runtime guard
    expect(extractTokenFromForward(null)).toBeNull()
    // @ts-expect-error — testing runtime guard
    expect(extractTokenFromForward(undefined)).toBeNull()
  })

  it('returns null when no token present', () => {
    expect(extractTokenFromForward('Hello, please set up your bot!')).toBeNull()
  })

  it('extracts first token when multiple appear (unlikely in practice)', () => {
    const msg = '111111111:ABCdef_GHIjklMNOpqr-STUvwxyz1234 and 222222222:XYZdef_GHIjklMNOpqr-STUvwxyz5678'
    const result = extractTokenFromForward(msg)
    expect(result).not.toBeNull()
    expect(result!.token).toBe('111111111:ABCdef_GHIjklMNOpqr-STUvwxyz1234')
  })
})

// ---------------------------------------------------------------------------
// tokenLastFour
// ---------------------------------------------------------------------------
describe('tokenLastFour', () => {
  it('returns last 4 chars of secret portion', () => {
    expect(tokenLastFour('123456789:ABCdef_GHIjklMNOpqr-STUvwxyz1234')).toBe('1234')
  })

  it('returns last 4 chars when secret ends in underscores', () => {
    expect(tokenLastFour('123456789:ABCdef_GHIjklMNOpqr-STUvwxyz___')).toBe('x___')
  })

  it('returns ???? for token missing colon', () => {
    expect(tokenLastFour('notavalidtoken')).toBe('????')
  })

  it('handles short secret gracefully (edge case)', () => {
    // Only 2 chars after colon — returns '??ab' (padded)
    expect(tokenLastFour('123456789:ab')).toBe('??ab')
  })

  it('returns confirmation shape matching spec §3', () => {
    // Spec: "Got token ending `...XYZ` — adopt as {officer}?"
    // lastFour is what goes in ...XYZ
    const token = '987654321:ABCdef_GHIjklMNOpqr-STUvwxyzABCD'
    expect(tokenLastFour(token)).toBe('ABCD')
    // verify the caller can build "...ABCD" confirmation
    expect(`...${tokenLastFour(token)}`).toBe('...ABCD')
  })
})

// ---------------------------------------------------------------------------
// generateBotFatherLink
// ---------------------------------------------------------------------------
describe('generateBotFatherLink', () => {
  it('produces correct URL for work/cos', () => {
    expect(generateBotFatherLink('work', 'cos')).toBe('https://t.me/BotFather?start=work-cos')
  })

  it('produces correct URL for personal/executive-coach', () => {
    expect(generateBotFatherLink('personal', 'executive-coach')).toBe(
      'https://t.me/BotFather?start=personal-executive-coach'
    )
  })

  it('produces correct URL for team-ops/cto', () => {
    expect(generateBotFatherLink('team-ops', 'cto')).toBe(
      'https://t.me/BotFather?start=team-ops-cto'
    )
  })

  it('lowercases and sanitizes uppercase inputs', () => {
    expect(generateBotFatherLink('Work', 'CoS')).toBe('https://t.me/BotFather?start=work-cos')
  })

  it('replaces non-alphanumeric non-hyphen chars with hyphens', () => {
    // e.g. if role comes in with underscores
    expect(generateBotFatherLink('my_cabinet', 'chief_officer')).toBe(
      'https://t.me/BotFather?start=my-cabinet-chief-officer'
    )
  })

  it('handles spec example: personal preset executive coach', () => {
    // From spec §3 example comment
    expect(generateBotFatherLink('personal', 'executive-coach')).toBe(
      'https://t.me/BotFather?start=personal-executive-coach'
    )
  })
})
