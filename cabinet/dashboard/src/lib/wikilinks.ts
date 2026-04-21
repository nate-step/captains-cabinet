/**
 * wikilinks.ts — Spec 037 Phase A: A1 + A6 wikilink + section anchor utilities.
 *
 * Parse `[[Target]]`, `[[Target|Alias]]`, `[[space:title]]`, `[[Target#section]]`
 * from markdown source, resolve against DB, and render as HTML anchors.
 *
 * Also exports:
 *   - extractHeadings() for A6 section-anchor indexing
 *   - slugify() deterministic heading → slug (github-slugger compatible)
 *   - indexLinks() transactional DB write path (called by saveRecord)
 *   - indexSections() transactional DB write path (called by saveRecord)
 */

import { query } from './db'

// ============================================================
// Types
// ============================================================

export interface ParsedWikilink {
  raw: string       // full [[...]] match including brackets
  target: string    // the left side: record title or space:title or title#section
  alias: string | null  // the right side of | (display text)
  section: string | null // #heading if present
  startIdx: number
  endIdx: number
}

export interface ResolvedWikilink extends ParsedWikilink {
  resolved: {
    recordId: string
    title: string
    spaceId: string
    spaceName: string
    sectionValid: boolean | null // null if no section; true if slug found; false if missing
  } | null
  reason?: 'not-found' | 'section-missing'
}

export interface ExtractedHeading {
  text: string
  level: number  // 1–6
  slug: string
  position: number  // 0-based occurrence index in document
}

export interface SectionRow {
  record_id: string
  section_slug: string
  heading_text: string
  heading_level: number
  position: number
  [key: string]: unknown
}

export interface LinkRow {
  id: string
  source_record_id: string
  target_record_id: string
  link_text: string
  link_context: string | null
  link_position: number
  [key: string]: unknown
}

// ============================================================
// Regex — no nested brackets, no bold-inside-wikilink
// Escape: \[[ treated as literal [[
// ============================================================

const WIKILINK_REGEX = /(?<!\\)\[\[([^\]|#\n]+?)(?:#([^\]|]+?))?(?:\|([^\]]+?))?\]\]/g

// ============================================================
// Parse
// ============================================================

/**
 * Parse all [[...]] wikilinks from a markdown string.
 * Returns array of parsed matches with positions.
 */
export function parseWikilinks(markdown: string): ParsedWikilink[] {
  const results: ParsedWikilink[] = []
  let match: RegExpExecArray | null

  WIKILINK_REGEX.lastIndex = 0
  while ((match = WIKILINK_REGEX.exec(markdown)) !== null) {
    const [raw, target, section, alias] = match
    // Reject markdown inside target (bold, italic, etc.)
    if (target.includes('*') || target.includes('_') || target.includes('`')) {
      continue
    }
    results.push({
      raw,
      target: target.trim(),
      alias: alias?.trim() ?? null,
      section: section?.trim() ?? null,
      startIdx: match.index,
      endIdx: match.index + raw.length,
    })
  }

  return results
}

// ============================================================
// Slugify — github-slugger compatible deterministic slug
// ============================================================

export function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\w\s-]/g, '')  // remove non-word chars except space/hyphen
    .replace(/[\s_]+/g, '-')   // spaces → hyphens
    .replace(/^-+|-+$/g, '')   // trim leading/trailing hyphens
    || 'section'
}

// ============================================================
// Extract headings from markdown for A6
// ============================================================

export function extractHeadings(markdown: string): ExtractedHeading[] {
  // Normalize CRLF + lone CR to LF so headings imported from Windows-authored
  // markdown don't end up with trailing \r in text/slug (FW-024 bulk loader
  // preserves source line endings).
  const lines = markdown.replace(/\r\n?/g, '\n').split('\n')
  const slugCount: Record<string, number> = {}
  const headings: ExtractedHeading[] = []
  let position = 0

  for (const line of lines) {
    const match = line.match(/^(#{1,6})\s+(.+)$/)
    if (match) {
      const level = match[1].length
      const text = match[2].trim()
      const baseSlug = slugify(text)

      // Disambiguate duplicates with occurrence suffix
      const count = slugCount[baseSlug] ?? 0
      slugCount[baseSlug] = count + 1
      const slug = count === 0 ? baseSlug : `${baseSlug}-${count}`

      headings.push({ text, level, slug, position })
      position++
    }
  }

  return headings
}

// ============================================================
// Resolve wikilinks against DB (batched)
// ============================================================

interface RecordLookupRow {
  [key: string]: unknown
  id: string
  title: string
  space_id: string
  space_name: string
}

/**
 * Resolve parsed wikilinks against the DB.
 * Looks up by title (ILIKE) — prefers current-space first, then cross-space.
 * For `space:title` syntax, looks up by space name then title.
 */
export async function resolveWikilinks(
  links: ParsedWikilink[],
  currentSpaceId?: string
): Promise<ResolvedWikilink[]> {
  if (links.length === 0) return []

  // Separate targets: space:title vs plain title
  const plainTargets = links.filter(l => !l.target.includes(':')).map(l => l.target)

  // Batch lookup all plain titles
  const lookup: Record<string, RecordLookupRow> = {}

  if (plainTargets.length > 0) {
    const unique = [...new Set(plainTargets)]

    // Prefer records in current space; fall back to most-recently-updated globally
    const rows = await query<RecordLookupRow>(
      `
      SELECT DISTINCT ON (LOWER(r.title))
        r.id::text,
        r.title,
        r.space_id::text,
        s.name AS space_name
      FROM library_records r
      JOIN library_spaces s ON s.id = r.space_id
      WHERE r.superseded_by IS NULL
        AND LOWER(r.title) = ANY(
          SELECT LOWER(unnest($1::text[]))
        )
      ORDER BY
        LOWER(r.title),
        CASE WHEN r.space_id = $2::bigint THEN 0 ELSE 1 END,
        r.updated_at DESC
      `,
      [unique, currentSpaceId ?? '0']
    )

    for (const row of rows) {
      lookup[row.title.toLowerCase()] = row
    }
  }

  // Resolve each link
  const resolved: ResolvedWikilink[] = []

  for (const link of links) {
    let row: RecordLookupRow | null = null

    if (link.target.includes(':')) {
      // space:title syntax — lookup by space name + title
      const [spacePart, titlePart] = link.target.split(':', 2)
      const spaceRows = await query<RecordLookupRow>(
        `
        SELECT r.id::text, r.title, r.space_id::text, s.name AS space_name
        FROM library_records r
        JOIN library_spaces s ON s.id = r.space_id
        WHERE r.superseded_by IS NULL
          AND LOWER(s.name) = LOWER($1)
          AND LOWER(r.title) = LOWER($2)
        ORDER BY r.updated_at DESC
        LIMIT 1
        `,
        [spacePart.trim(), titlePart.trim()]
      )
      row = spaceRows[0] ?? null
    } else {
      row = lookup[link.target.toLowerCase()] ?? null
    }

    if (!row) {
      resolved.push({ ...link, resolved: null, reason: 'not-found' })
      continue
    }

    // If there's a section, check if it exists
    let sectionValid: boolean | null = null
    if (link.section) {
      const sectRows = await query<{ [key: string]: unknown; count: string }>(
        `SELECT COUNT(*)::text AS count FROM library_record_sections
         WHERE record_id = $1::bigint AND section_slug = $2`,
        [row.id, slugify(link.section)]
      )
      sectionValid = parseInt(sectRows[0]?.count ?? '0', 10) > 0
    }

    resolved.push({
      ...link,
      resolved: {
        recordId: row.id,
        title: row.title,
        spaceId: row.space_id,
        spaceName: row.space_name,
        sectionValid,
      },
      reason: sectionValid === false ? 'section-missing' : undefined,
    })
  }

  return resolved
}

// ============================================================
// Render wikilinks → HTML anchor tags
// Replaces [[...]] in raw markdown with <a> tags before the
// rehype/markdown pipeline renders the rest.
// ============================================================

export function renderWikilinks(
  markdown: string,
  resolutions: ResolvedWikilink[]
): string {
  // Process in reverse order to preserve indices
  const sorted = [...resolutions].sort((a, b) => b.startIdx - a.startIdx)
  let result = markdown

  for (const link of sorted) {
    const displayText = link.alias ?? link.target
    let html: string

    if (!link.resolved) {
      // Unresolved link — dashed/dim style with create affordance
      const createTitle = encodeURIComponent(link.target)
      html = `<a href="/library/new?title=${createTitle}" class="wikilink wikilink-unresolved" title="No such record. Click to create." data-wikilink-target="${link.target}">${displayText}</a>`
    } else {
      const { recordId, spaceId, sectionValid } = link.resolved
      const section = link.section ? slugify(link.section) : null
      const sectionSuffix = section ? `#${section}` : ''
      const href = `/library/${spaceId}/${recordId}${sectionSuffix}`

      if (link.section && sectionValid === false) {
        // Record exists but section is missing — warn + still link to record
        html = `<a href="/library/${spaceId}/${recordId}" class="wikilink wikilink-section-missing" title="Section '${link.section}' not found in ${link.resolved.title}." data-wikilink-target="${link.target}">${displayText}</a>`
      } else {
        html = `<a href="${href}" class="wikilink wikilink-resolved" data-wikilink-target="${link.target}">${displayText}</a>`
      }
    }

    result = result.slice(0, link.startIdx) + html + result.slice(link.endIdx)
  }

  return result
}

// ============================================================
// Write-path indexer — call inside saveRecord transaction
// ============================================================

/**
 * Index all wikilinks for a record.
 * Deletes existing rows for sourceRecordId, then inserts fresh ones.
 * Call within the same DB transaction as the record save.
 */
export async function indexLinks(
  sourceRecordId: string,
  markdown: string,
  spaceId: string
): Promise<void> {
  // Delete existing link rows for this source
  await query('DELETE FROM library_record_links WHERE source_record_id = $1::bigint', [sourceRecordId])

  const parsed = parseWikilinks(markdown)
  if (parsed.length === 0) return

  const resolved = await resolveWikilinks(parsed, spaceId)

  // Filter to resolved-only links and build insert rows
  const rows = resolved.filter(l => l.resolved !== null)
  if (rows.length === 0) return

  // Extract ±40 char context around each link
  for (let i = 0; i < rows.length; i++) {
    const link = rows[i]
    const ctx = extractContext(markdown, link.startIdx, link.endIdx, 40)

    await query(
      `INSERT INTO library_record_links
         (source_record_id, target_record_id, link_text, link_context, link_position)
       VALUES ($1::bigint, $2::bigint, $3, $4, $5)
       ON CONFLICT DO NOTHING`,
      [
        sourceRecordId,
        link.resolved!.recordId,
        link.alias ?? link.target,
        ctx,
        i,
      ]
    )
  }
}

/**
 * Index all headings for a record.
 * DELETE + INSERT pattern (refresh-only, idempotent).
 */
export async function indexSections(
  recordId: string,
  markdown: string
): Promise<void> {
  await query('DELETE FROM library_record_sections WHERE record_id = $1::bigint', [recordId])

  const headings = extractHeadings(markdown)
  if (headings.length === 0) return

  for (const h of headings) {
    await query(
      `INSERT INTO library_record_sections (record_id, section_slug, heading_text, heading_level, position)
       VALUES ($1::bigint, $2, $3, $4, $5)
       ON CONFLICT (record_id, section_slug) DO UPDATE SET
         heading_text = EXCLUDED.heading_text,
         heading_level = EXCLUDED.heading_level,
         position = EXCLUDED.position`,
      [recordId, h.slug, h.text, h.level, h.position]
    )
  }
}

// ============================================================
// Helpers
// ============================================================

function extractContext(markdown: string, start: number, end: number, radius: number): string {
  const ctxStart = Math.max(0, start - radius)
  const ctxEnd = Math.min(markdown.length, end + radius)
  let ctx = markdown.slice(ctxStart, ctxEnd).replace(/\n+/g, ' ').trim()
  if (ctxStart > 0) ctx = '…' + ctx
  if (ctxEnd < markdown.length) ctx = ctx + '…'
  return ctx
}

// ============================================================
// Backlinks query — used by the backlinks panel on record pages
// ============================================================

export interface BacklinkEntry {
  [key: string]: unknown
  source_record_id: string
  source_title: string
  source_space_id: string
  source_space_name: string
  link_text: string
  link_context: string | null
  link_position: number
}

export async function getBacklinks(targetRecordId: string): Promise<BacklinkEntry[]> {
  return query<BacklinkEntry>(
    `
    SELECT
      lrl.source_record_id::text,
      r.title AS source_title,
      r.space_id::text AS source_space_id,
      s.name AS source_space_name,
      lrl.link_text,
      lrl.link_context,
      lrl.link_position
    FROM library_record_links lrl
    JOIN library_records r ON r.id = lrl.source_record_id AND r.superseded_by IS NULL
    JOIN library_spaces s ON s.id = r.space_id
    WHERE lrl.target_record_id = $1::bigint
    ORDER BY s.name, r.title, lrl.link_position
    LIMIT 50
    `,
    [targetRecordId]
  )
}

// ============================================================
// Typeahead records — used by autocomplete endpoint
// ============================================================

export interface TypeaheadRecord {
  [key: string]: unknown
  id: string
  title: string
  space_id: string
  space_name: string
  labels: string[]
  updated_at: string
}

export async function typeaheadRecords(
  q: string,
  opts?: { spaceId?: string; limit?: number }
): Promise<TypeaheadRecord[]> {
  const limit = opts?.limit ?? 10
  const spaceId = opts?.spaceId ?? null

  return query<TypeaheadRecord>(
    `
    SELECT
      r.id::text,
      r.title,
      r.space_id::text,
      s.name AS space_name,
      r.labels,
      r.updated_at::text
    FROM library_records r
    JOIN library_spaces s ON s.id = r.space_id
    WHERE r.superseded_by IS NULL
      AND ($1::bigint IS NULL OR r.space_id = $1::bigint)
      AND r.title ILIKE $2 || '%'
    ORDER BY
      CASE WHEN r.space_id = COALESCE($1::bigint, -1) THEN 0 ELSE 1 END,
      r.updated_at DESC
    LIMIT $3
    `,
    [spaceId, q, limit]
  )
}
