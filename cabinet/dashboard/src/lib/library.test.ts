// library.ts — pure-logic slice.
// library.ts is ~745 LOC but almost every export is async + DB-bound.
// The pure export is STATUS_TRANSITIONS — the v3.2 state-machine table
// that updateRecordStatus() + the PATCH /api/library/records/:id/status
// route handler both depend on. Pinning the table catches accidental
// edits and graph regressions (e.g., if someone accidentally removes
// the author-rescind edge in_review→draft).
//
// DB-touching functions (listSpaces, createRecord, updateRecord, search,
// etc.) are deferred — they require pg-pool mocking + fixtures. The
// state-machine pin is the highest-leverage pure test available here.
//
// Spec reference: Spec 037 §12, AC #16 (v3.2).

import { describe, it, expect } from 'vitest'

import { STATUS_TRANSITIONS, type RecordStatus } from './library'

const ALL_STATUSES: RecordStatus[] = [
  'draft',
  'in_review',
  'approved',
  'implemented',
  'superseded',
]

describe('STATUS_TRANSITIONS — shape', () => {
  it('has an entry for every RecordStatus', () => {
    for (const s of ALL_STATUSES) {
      expect(STATUS_TRANSITIONS).toHaveProperty(s)
    }
  })

  it('has exactly 5 entries (no extras)', () => {
    expect(Object.keys(STATUS_TRANSITIONS).sort()).toEqual(
      [...ALL_STATUSES].sort()
    )
  })

  it('every value is an array', () => {
    for (const s of ALL_STATUSES) {
      expect(Array.isArray(STATUS_TRANSITIONS[s])).toBe(true)
    }
  })

  it('every listed target is itself a valid RecordStatus', () => {
    for (const s of ALL_STATUSES) {
      for (const target of STATUS_TRANSITIONS[s]) {
        expect(ALL_STATUSES).toContain(target)
      }
    }
  })
})

describe('STATUS_TRANSITIONS — exact edges per spec 037 §12 v3.2', () => {
  it('draft → {in_review, superseded}', () => {
    expect(STATUS_TRANSITIONS.draft.sort()).toEqual(['in_review', 'superseded'])
  })

  it('in_review → {draft, approved, superseded}', () => {
    // draft = author rescind; approved = normal approval; superseded = kill
    expect(STATUS_TRANSITIONS.in_review.sort()).toEqual(
      ['approved', 'draft', 'superseded']
    )
  })

  it('approved → {in_review, implemented, superseded}', () => {
    // in_review = re-open (review cycles not one-shot — v3 addition)
    expect(STATUS_TRANSITIONS.approved.sort()).toEqual(
      ['implemented', 'in_review', 'superseded']
    )
  })

  it('implemented → {superseded} only', () => {
    expect(STATUS_TRANSITIONS.implemented).toEqual(['superseded'])
  })

  it('superseded is strictly terminal ({})', () => {
    expect(STATUS_TRANSITIONS.superseded).toEqual([])
  })
})

describe('STATUS_TRANSITIONS — graph invariants', () => {
  it('no self-loops (no status transitions to itself)', () => {
    for (const s of ALL_STATUSES) {
      expect(STATUS_TRANSITIONS[s]).not.toContain(s)
    }
  })

  it('every non-terminal state can reach superseded (kill-switch always available)', () => {
    // superseded should be reachable from every other state — directly or transitively
    // Direct check: every non-terminal lists 'superseded' as a direct edge
    for (const s of ALL_STATUSES) {
      if (s === 'superseded') continue
      expect(STATUS_TRANSITIONS[s]).toContain('superseded')
    }
  })

  it('superseded has zero outbound edges (strict terminal)', () => {
    expect(STATUS_TRANSITIONS.superseded.length).toBe(0)
  })

  it('implemented has exactly 1 outbound edge (superseded only)', () => {
    expect(STATUS_TRANSITIONS.implemented.length).toBe(1)
  })

  it('draft has no direct edge to approved (must go through in_review)', () => {
    expect(STATUS_TRANSITIONS.draft).not.toContain('approved')
  })

  it('draft has no direct edge to implemented', () => {
    expect(STATUS_TRANSITIONS.draft).not.toContain('implemented')
  })

  it('in_review has no direct edge to implemented (must go via approved)', () => {
    expect(STATUS_TRANSITIONS.in_review).not.toContain('implemented')
  })

  it('approved can bounce back to in_review (review cycles not one-shot)', () => {
    expect(STATUS_TRANSITIONS.approved).toContain('in_review')
  })

  it('in_review can bounce back to draft (author rescind)', () => {
    expect(STATUS_TRANSITIONS.in_review).toContain('draft')
  })

  it('implemented cannot bounce back to approved (one-way after ship)', () => {
    expect(STATUS_TRANSITIONS.implemented).not.toContain('approved')
  })

  it('implemented cannot revert to draft or in_review', () => {
    expect(STATUS_TRANSITIONS.implemented).not.toContain('draft')
    expect(STATUS_TRANSITIONS.implemented).not.toContain('in_review')
  })
})

describe('STATUS_TRANSITIONS — reachability (used by updateRecordStatus)', () => {
  // updateRecordStatus builds reachableFrom = statuses S where TARGET ∈ TRANSITIONS[S]
  // and uses that as the CAS guard in the UPDATE's status = ANY(...) clause.
  // These tests pin that reachableFrom is well-formed for each target.

  const reachableFrom = (target: RecordStatus): RecordStatus[] =>
    (Object.keys(STATUS_TRANSITIONS) as RecordStatus[]).filter((from) =>
      STATUS_TRANSITIONS[from].includes(target)
    )

  it('target=in_review reachable from {draft, approved}', () => {
    expect(reachableFrom('in_review').sort()).toEqual(['approved', 'draft'])
  })

  it('target=approved reachable from {in_review} only', () => {
    expect(reachableFrom('approved')).toEqual(['in_review'])
  })

  it('target=implemented reachable from {approved} only', () => {
    expect(reachableFrom('implemented')).toEqual(['approved'])
  })

  it('target=superseded reachable from every non-terminal (kill-switch)', () => {
    expect(reachableFrom('superseded').sort()).toEqual(
      ['approved', 'draft', 'implemented', 'in_review']
    )
  })

  it('target=draft reachable from {in_review} only (author rescind)', () => {
    expect(reachableFrom('draft')).toEqual(['in_review'])
  })

  it('no status is reachable from superseded (terminal)', () => {
    for (const target of ALL_STATUSES) {
      expect(reachableFrom(target)).not.toContain('superseded')
    }
  })
})
