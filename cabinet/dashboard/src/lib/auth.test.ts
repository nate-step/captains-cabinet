// Spec 034/FW-048 — auth.ts checkPassword coverage.
// Security-critical: this is the password gate for the provisioning dashboard
// (api/auth/reauth-verify/route.ts + actions/auth.ts). Regressions in the
// length gate or utf-8 byte semantics could let wrong-length inputs through
// to timingSafeEqual (which throws on length mismatch) or let multi-byte
// strings bypass the byte-count check.
//
// Dynamic import pattern: SECRET is captured at module load time from
// process.env.DASHBOARD_PASSWORD. We set the env BEFORE the first import so
// tests can assert against a known secret. Each vitest worker gets a fresh
// module cache, so this is one-shot per file.

import { describe, it, expect, beforeAll } from 'vitest'

const TEST_SECRET = 'correct-horse-battery-staple' // 28 ASCII bytes

describe('checkPassword — timing-safe password comparison', () => {
  let checkPassword: (password: string) => boolean

  beforeAll(async () => {
    process.env.DASHBOARD_PASSWORD = TEST_SECRET
    const mod = await import('./auth')
    checkPassword = mod.checkPassword
  })

  // ── Happy path ──────────────────────────────────────────────────────────────

  it('returns true when password matches SECRET exactly', () => {
    expect(checkPassword(TEST_SECRET)).toBe(true)
  })

  it('is deterministic — same match input yields same result across calls', () => {
    expect(checkPassword(TEST_SECRET)).toBe(true)
    expect(checkPassword(TEST_SECRET)).toBe(true)
    expect(checkPassword(TEST_SECRET)).toBe(true)
  })

  // ── Length gate (short-circuits BEFORE timingSafeEqual) ─────────────────────
  // timingSafeEqual throws "Input buffers must have the same byte length".
  // The length pre-check prevents that throw. If the gate regresses, these
  // tests will start throwing instead of returning false.

  it('returns false when password is empty', () => {
    expect(checkPassword('')).toBe(false)
  })

  it('returns false when password is shorter than SECRET', () => {
    expect(checkPassword(TEST_SECRET.slice(0, 5))).toBe(false)
  })

  it('returns false when password is longer than SECRET', () => {
    expect(checkPassword(TEST_SECRET + 'x')).toBe(false)
  })

  it('returns false for single-char input against 28-byte SECRET', () => {
    expect(checkPassword('a')).toBe(false)
  })

  // ── Content mismatch (same byte length) ─────────────────────────────────────
  // These reach timingSafeEqual. The timing-safe comparison returns false
  // on mismatch (not throw).

  it('returns false when same-length but different content', () => {
    const wrong = 'x'.repeat(TEST_SECRET.length)
    expect(checkPassword(wrong)).toBe(false)
  })

  it('is case-sensitive — uppercase variant rejected', () => {
    expect(checkPassword(TEST_SECRET.toUpperCase())).toBe(false)
  })

  it('rejects one-char-off variant (single-byte flip)', () => {
    // Flip last char: 'staple' → 'staplf' — same length, one byte differs
    const oneOff = TEST_SECRET.slice(0, -1) + 'f'
    expect(oneOff).not.toBe(TEST_SECRET)
    expect(oneOff.length).toBe(TEST_SECRET.length)
    expect(checkPassword(oneOff)).toBe(false)
  })

  // ── Byte vs char length semantics (utf-8) ───────────────────────────────────
  // Buffer.from(str) encodes as utf-8. Multi-byte code points inflate byte
  // count. A naive implementation using str.length would have different
  // behavior for these inputs; these tests pin the byte-based gate.

  it('multi-byte str with same CHAR count but larger BYTE count is rejected (byte gate)', () => {
    // 'é' is 2 bytes in utf-8. 'é' x 28 = 28 chars but 56 bytes.
    // Naive .length check (28 == 28) would skip to content compare, where
    // timingSafeEqual would THROW on unequal buffer lengths. The byte-based
    // gate correctly returns false before reaching timingSafeEqual.
    const tooManyBytes = 'é'.repeat(28)
    expect(tooManyBytes.length).toBe(28) // matches SECRET char-count
    expect(Buffer.from(tooManyBytes).length).toBe(56) // but NOT byte-count
    expect(checkPassword(tooManyBytes)).toBe(false)
  })

  it('multi-byte str with matching BYTE count but mismatched chars is rejected (content compare)', () => {
    // 'é' x 14 = 14 chars but 28 bytes — same byte length as SECRET.
    // Passes the length gate, fails content compare → false.
    // Exercises the post-gate path for utf-8 input.
    const sameBytes = 'é'.repeat(14)
    expect(Buffer.from(sameBytes).length).toBe(28) // matches SECRET byte-count
    expect(checkPassword(sameBytes)).toBe(false)
  })

  // ── Whitespace significance ─────────────────────────────────────────────────

  it('trailing whitespace changes length → rejected', () => {
    expect(checkPassword(TEST_SECRET + ' ')).toBe(false)
  })

  it('leading whitespace changes length → rejected', () => {
    expect(checkPassword(' ' + TEST_SECRET)).toBe(false)
  })

  // ── Return type invariant ───────────────────────────────────────────────────

  it('always returns a strict boolean (not truthy-ish)', () => {
    const matchResult = checkPassword(TEST_SECRET)
    const missResult = checkPassword('nope')
    expect(typeof matchResult).toBe('boolean')
    expect(typeof missResult).toBe('boolean')
    expect(matchResult).toBe(true)
    expect(missResult).toBe(false)
  })

  // ── Does not throw on adversarial input ─────────────────────────────────────
  // Pins the contract: callers rely on checkPassword to return false, never
  // throw, so route handlers can treat it as a pure predicate.

  it('does not throw on empty string', () => {
    expect(() => checkPassword('')).not.toThrow()
  })

  it('does not throw on very long input', () => {
    const longInput = 'a'.repeat(10_000)
    expect(() => checkPassword(longInput)).not.toThrow()
    expect(checkPassword(longInput)).toBe(false)
  })

  it('does not throw on null-byte input', () => {
    // A regression using naive string compare could behave oddly with NUL;
    // Buffer-based compare handles it as a normal byte.
    const nullByte = '\0'.repeat(TEST_SECRET.length)
    expect(() => checkPassword(nullByte)).not.toThrow()
    expect(checkPassword(nullByte)).toBe(false)
  })
})
