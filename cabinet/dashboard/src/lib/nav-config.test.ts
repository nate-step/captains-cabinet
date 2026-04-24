// Spec 032 — nav-config.ts coverage for navForMode + the two static nav arrays.
// These drive the dashboard nav surface across consumer + advanced modes;
// pinning the shape prevents silent regressions when routes get renamed or
// mode-gated links drift between the two sets.

import { describe, it, expect } from 'vitest'
import { ADVANCED_NAV, CONSUMER_NAV, navForMode } from './nav-config'

describe('ADVANCED_NAV — static shape', () => {
  it('has 13 items (12 internal + 1 external Terminal)', () => {
    expect(ADVANCED_NAV).toHaveLength(13)
  })

  it('every link has an href and a label', () => {
    for (const link of ADVANCED_NAV) {
      expect(link.href).toBeTruthy()
      expect(link.label).toBeTruthy()
    }
  })

  it('starts with Dashboard at href "/"', () => {
    expect(ADVANCED_NAV[0]).toEqual({ href: '/', label: 'Dashboard' })
  })

  it('contains all Spec 032 advanced-mode routes', () => {
    const labels = ADVANCED_NAV.map(l => l.label)
    expect(labels).toContain('Dashboard')
    expect(labels).toContain('Project')
    expect(labels).toContain('Cabinets')
    expect(labels).toContain('Officers')
    expect(labels).toContain('Tasks')
    expect(labels).toContain('Health')
    expect(labels).toContain('Settings')
    expect(labels).toContain('Governance')
    expect(labels).toContain('Integrations')
    expect(labels).toContain('Costs')
    expect(labels).toContain('Crons')
    expect(labels).toContain('Library')
    expect(labels).toContain('Terminal')
  })

  it('Terminal is the only external link (target=_blank affordance)', () => {
    const externals = ADVANCED_NAV.filter(l => l.external)
    expect(externals).toHaveLength(1)
    expect(externals[0].label).toBe('Terminal')
    expect(externals[0].href).toMatch(/^https:\/\//)
  })

  it('all internal links start with "/" (not absolute URLs)', () => {
    for (const link of ADVANCED_NAV) {
      if (!link.external) {
        expect(link.href.startsWith('/')).toBe(true)
      }
    }
  })

  it('no duplicate hrefs', () => {
    const hrefs = ADVANCED_NAV.map(l => l.href)
    expect(new Set(hrefs).size).toBe(hrefs.length)
  })
})

describe('CONSUMER_NAV — static shape', () => {
  it('has 5 items (the 4 content cards + Cabinets per Spec 034)', () => {
    expect(CONSUMER_NAV).toHaveLength(5)
  })

  it('contains exactly Dashboard / Cabinets / Costs / Library / Settings', () => {
    expect(CONSUMER_NAV.map(l => l.label)).toEqual([
      'Dashboard',
      'Cabinets',
      'Costs',
      'Library',
      'Settings',
    ])
  })

  it('every consumer link also exists in ADVANCED_NAV (consumer is a subset)', () => {
    const advHrefs = new Set(ADVANCED_NAV.map(l => l.href))
    for (const link of CONSUMER_NAV) {
      expect(advHrefs.has(link.href)).toBe(true)
    }
  })

  it('no external links (consumer mode is in-app only)', () => {
    expect(CONSUMER_NAV.every(l => !l.external)).toBe(true)
  })

  it('no duplicate hrefs', () => {
    const hrefs = CONSUMER_NAV.map(l => l.href)
    expect(new Set(hrefs).size).toBe(hrefs.length)
  })
})

describe('navForMode — routing function', () => {
  it('returns ADVANCED_NAV when consumerEnabled=false, regardless of mode', () => {
    expect(navForMode('consumer', false)).toBe(ADVANCED_NAV)
    expect(navForMode('advanced', false)).toBe(ADVANCED_NAV)
  })

  it('returns CONSUMER_NAV when mode=consumer + consumerEnabled=true', () => {
    expect(navForMode('consumer', true)).toBe(CONSUMER_NAV)
  })

  it('returns ADVANCED_NAV when mode=advanced + consumerEnabled=true', () => {
    expect(navForMode('advanced', true)).toBe(ADVANCED_NAV)
  })

  it('returns references (not copies) — callers may rely on identity', () => {
    // Pinning this matters if a caller does `useMemo` keyed on reference equality
    expect(navForMode('consumer', true)).toBe(CONSUMER_NAV)
    expect(navForMode('advanced', true)).toBe(ADVANCED_NAV)
    expect(navForMode('consumer', false)).toBe(ADVANCED_NAV)
  })

  it('consumerEnabled gate takes precedence over mode', () => {
    // If feature flag is off, we never serve consumer nav even if mode requests it
    const result = navForMode('consumer', false)
    expect(result).toBe(ADVANCED_NAV)
    expect(result).not.toBe(CONSUMER_NAV)
  })
})
