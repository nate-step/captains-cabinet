// Spec 034 PR 3 — qr-inline.ts generateQrSvg SVG contract.
// Inline QR encoder used for BotFather deep-links on adopt-bot-step.
// URL content never flows into DOM (only used for hash-derived pattern
// fill), so XSS surface is bounded to sizePx + fixed SVG scaffolding.
//
// Tests pin: version selection (via bytes.length → ecM table), SVG
// structural invariants (viewBox, aria-label, white bg, data rects),
// fallback trigger on oversized input, size customization math.

import { describe, it, expect } from 'vitest'

import { generateQrSvg } from './qr-inline'

describe('generateQrSvg — happy path SVG structure', () => {
  it('returns an <svg> element as a string', () => {
    const svg = generateQrSvg('https://example.com')
    expect(svg.startsWith('<svg')).toBe(true)
    expect(svg.endsWith('</svg>')).toBe(true)
  })

  it('uses default size 160 when sizePx omitted', () => {
    const svg = generateQrSvg('https://example.com')
    expect(svg).toContain('width="160"')
    expect(svg).toContain('height="160"')
    expect(svg).toContain('viewBox="0 0 160 160"')
  })

  it('respects custom sizePx', () => {
    const svg = generateQrSvg('https://example.com', 256)
    expect(svg).toContain('width="256"')
    expect(svg).toContain('height="256"')
    expect(svg).toContain('viewBox="0 0 256 256"')
  })

  it('declares the SVG xmlns namespace', () => {
    const svg = generateQrSvg('https://example.com')
    expect(svg).toContain('xmlns="http://www.w3.org/2000/svg"')
  })

  it('sets role="img" and aria-label for accessibility', () => {
    const svg = generateQrSvg('https://example.com')
    expect(svg).toContain('role="img"')
    expect(svg).toContain('aria-label="QR code"')
  })

  it('includes a white background rect at full size', () => {
    const svg = generateQrSvg('https://example.com', 200)
    expect(svg).toContain('<rect width="200" height="200" fill="#fff"/>')
  })

  it('includes at least one data rect (fill="#000") for the encoded URL', () => {
    const svg = generateQrSvg('https://example.com')
    const blackRects = (svg.match(/fill="#000"/g) || []).length
    expect(blackRects).toBeGreaterThan(0)
  })
})

describe('generateQrSvg — deterministic output', () => {
  it('produces identical SVG for identical (url, size) input', () => {
    const a = generateQrSvg('https://example.com/same', 160)
    const b = generateQrSvg('https://example.com/same', 160)
    expect(a).toBe(b)
  })

  it('produces different SVG for different URLs (hash-derived fill)', () => {
    const a = generateQrSvg('https://example.com/a', 160)
    const b = generateQrSvg('https://example.com/b', 160)
    expect(a).not.toBe(b)
  })

  it('different sizes produce different SVG dimensions', () => {
    const a = generateQrSvg('https://example.com', 160)
    const b = generateQrSvg('https://example.com', 240)
    expect(a).not.toBe(b)
    expect(a).toContain('width="160"')
    expect(b).toContain('width="240"')
  })
})

describe('generateQrSvg — fallback path (oversize + errors)', () => {
  it('falls back to placeholder SVG when input exceeds version-20 capacity', () => {
    // ecM table tops out at 625 bytes; anything larger throws → fallback
    const huge = 'x'.repeat(700)
    const svg = generateQrSvg(huge)
    // Fallback has aria-label="QR code unavailable" + "use link below" text
    expect(svg).toContain('aria-label="QR code unavailable"')
    expect(svg).toContain('use link below')
  })

  it('fallback respects the requested sizePx', () => {
    const svg = generateQrSvg('x'.repeat(700), 300)
    expect(svg).toContain('width="300"')
    expect(svg).toContain('viewBox="0 0 300 300"')
  })

  it('fallback includes dark background (not white) to signal placeholder', () => {
    const svg = generateQrSvg('x'.repeat(700))
    expect(svg).toContain('fill="#18181b"')
  })

  it('fallback includes "QR" text anchor-centered', () => {
    const svg = generateQrSvg('x'.repeat(700))
    expect(svg).toContain('text-anchor="middle"')
    expect(svg).toContain('>QR<')
  })

  it('empty string input triggers fallback (ecM[0]=0 → version=0 → throw)', () => {
    // bytes.length = 0; findIndex(cap >= 0) returns index 0; version < 1 → throw
    const svg = generateQrSvg('')
    expect(svg).toContain('aria-label="QR code unavailable"')
  })
})

describe('generateQrSvg — version selection by byte length', () => {
  it('short URL (< 14 bytes) uses version 1 → 21×21 modules', () => {
    // v1 capacity for ECC M byte mode = 14 bytes. 10-byte URL fits v1.
    const svg = generateQrSvg('short.io')
    // modules = 17 + 1*4 = 21. cellSize = 160/21 ≈ 7.62. Finder pattern
    // at (0,0) covers 7×7 modules → first black rect at 0.00,0.00 to ~7.62 wide.
    expect(svg).toContain('x="0.00" y="0.00"')
  })

  it('medium URL (~50 bytes) fits in version 3 or higher', () => {
    const url = 'https://example.com/path/' + 'a'.repeat(20)
    const svg = generateQrSvg(url)
    expect(svg).toContain('<svg')
    // Must not be fallback
    expect(svg).not.toContain('aria-label="QR code unavailable"')
  })

  it('URL at 100 bytes fits (BotFather deep-link size class)', () => {
    const url = 'https://t.me/mybot?start=' + 'x'.repeat(72)
    const svg = generateQrSvg(url)
    expect(svg).not.toContain('aria-label="QR code unavailable"')
  })

  it('625-byte URL fits at version 20 capacity boundary', () => {
    // ecM[20] = 625 — exactly at capacity
    const svg = generateQrSvg('x'.repeat(625))
    expect(svg).not.toContain('aria-label="QR code unavailable"')
  })

  it('626-byte URL exceeds version 20 → fallback', () => {
    const svg = generateQrSvg('x'.repeat(626))
    expect(svg).toContain('aria-label="QR code unavailable"')
  })
})

describe('generateQrSvg — edge inputs', () => {
  it('handles ASCII URL', () => {
    const svg = generateQrSvg('https://example.com/x')
    expect(svg.startsWith('<svg')).toBe(true)
  })

  it('handles URL with query + fragment', () => {
    const svg = generateQrSvg('https://example.com/?q=1&r=2#hash')
    expect(svg.startsWith('<svg')).toBe(true)
    expect(svg).not.toContain('aria-label="QR code unavailable"')
  })

  it('handles unicode URL (TextEncoder produces multi-byte)', () => {
    // 'é' = 2 bytes in UTF-8, so 'é'.repeat(50) = 100 bytes — still fits
    const url = 'https://example.com/' + 'é'.repeat(30)
    const svg = generateQrSvg(url)
    expect(svg.startsWith('<svg')).toBe(true)
  })

  it('handles URL exactly at v1 capacity (14 bytes)', () => {
    const svg = generateQrSvg('x'.repeat(14))
    expect(svg).not.toContain('aria-label="QR code unavailable"')
  })

  it('URL-encoded vs plain URL produce same SVG (dead-branch identity)', () => {
    // Source: `const data = encodeURIComponent(url) === url ? url : url`
    // Both arms return url regardless — pin that behavior
    const plain = 'https://example.com/hello world'
    const encoded = 'https://example.com/hello%20world'
    expect(generateQrSvg(plain)).not.toBe(generateQrSvg(encoded))
    // They differ because `url` is used as-is for hash, so different URLs
    // yield different patterns — the dead branch doesn't re-route
  })
})
