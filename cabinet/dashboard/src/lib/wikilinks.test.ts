// Spec 037 Phase A — wikilinks.ts pure-logic coverage

import { describe, it, expect } from 'vitest'
import {
  parseWikilinks,
  slugify,
  extractHeadings,
  renderWikilinks,
  type ResolvedWikilink,
} from './wikilinks'

// ============================================================
// parseWikilinks
// ============================================================

describe('parseWikilinks — valid syntax', () => {
  it('plain target — no alias, no section', () => {
    const results = parseWikilinks('[[Title]]')
    expect(results).toHaveLength(1)
    expect(results[0].target).toBe('Title')
    expect(results[0].alias).toBeNull()
    expect(results[0].section).toBeNull()
    expect(results[0].raw).toBe('[[Title]]')
  })

  it('alias only', () => {
    const results = parseWikilinks('[[Title|Alias]]')
    expect(results).toHaveLength(1)
    expect(results[0].target).toBe('Title')
    expect(results[0].alias).toBe('Alias')
    expect(results[0].section).toBeNull()
  })

  it('space-qualified target — colon preserved, not split', () => {
    const results = parseWikilinks('[[space:title]]')
    expect(results).toHaveLength(1)
    expect(results[0].target).toBe('space:title')
    expect(results[0].alias).toBeNull()
    expect(results[0].section).toBeNull()
  })

  it('section only', () => {
    const results = parseWikilinks('[[Title#Section]]')
    expect(results).toHaveLength(1)
    expect(results[0].target).toBe('Title')
    expect(results[0].section).toBe('Section')
    expect(results[0].alias).toBeNull()
  })

  it('section + alias combo', () => {
    const results = parseWikilinks('[[Title#Section|Alias]]')
    expect(results).toHaveLength(1)
    expect(results[0].target).toBe('Title')
    expect(results[0].section).toBe('Section')
    expect(results[0].alias).toBe('Alias')
  })

  it('all 4 components: space:title#section|alias', () => {
    const results = parseWikilinks('[[space:title#section|alias]]')
    expect(results).toHaveLength(1)
    expect(results[0].target).toBe('space:title')
    expect(results[0].section).toBe('section')
    expect(results[0].alias).toBe('alias')
  })

  it('multiple links in one string — returns all', () => {
    const results = parseWikilinks('Start [[A]] middle [[B|C]] end')
    expect(results).toHaveLength(2)
    expect(results[0].target).toBe('A')
    expect(results[1].target).toBe('B')
    expect(results[1].alias).toBe('C')
  })

  it('whitespace trimmed from target', () => {
    const results = parseWikilinks('[[  Title  ]]')
    expect(results).toHaveLength(1)
    expect(results[0].target).toBe('Title')
  })

  it('whitespace trimmed from alias', () => {
    const results = parseWikilinks('[[Title|  My Alias  ]]')
    expect(results).toHaveLength(1)
    expect(results[0].alias).toBe('My Alias')
  })

  it('whitespace trimmed from section', () => {
    const results = parseWikilinks('[[Title#  My Section  ]]')
    expect(results).toHaveLength(1)
    expect(results[0].section).toBe('My Section')
  })
})

describe('parseWikilinks — indices', () => {
  it('startIdx and endIdx are correct for a plain link', () => {
    const md = 'pre [[Title]] post'
    const results = parseWikilinks(md)
    expect(results).toHaveLength(1)
    expect(results[0].startIdx).toBe(4)
    expect(results[0].endIdx).toBe(13)
    expect(md.slice(results[0].startIdx, results[0].endIdx)).toBe('[[Title]]')
  })

  it('startIdx and endIdx are correct for second link', () => {
    const md = '[[A]] and [[B]]'
    const results = parseWikilinks(md)
    expect(results[1].startIdx).toBe(10)
    expect(results[1].endIdx).toBe(15)
    expect(md.slice(results[1].startIdx, results[1].endIdx)).toBe('[[B]]')
  })
})

describe('parseWikilinks — rejected / malformed', () => {
  it('escaped \\\\[[ is ignored', () => {
    const results = parseWikilinks('\\[[Title]]')
    expect(results).toHaveLength(0)
  })

  it('bold inside target is rejected', () => {
    expect(parseWikilinks('[[Title *bold*]]')).toHaveLength(0)
  })

  it('italic inside target is rejected', () => {
    expect(parseWikilinks('[[Title _italic_]]')).toHaveLength(0)
  })

  it('backtick inside target is rejected', () => {
    expect(parseWikilinks('[[Title `code`]]')).toHaveLength(0)
  })

  it('empty string returns empty array', () => {
    expect(parseWikilinks('')).toHaveLength(0)
  })

  it('unclosed [[ returns no results', () => {
    expect(parseWikilinks('[[Title')).toHaveLength(0)
  })

  it('unmatched ]] returns no results', () => {
    expect(parseWikilinks('Title]]')).toHaveLength(0)
  })

  it('empty content [[]] returns no results — regex requires non-empty target', () => {
    // [^\]|#\n]+? requires at least one char; empty target matches nothing
    expect(parseWikilinks('[[]]')).toHaveLength(0)
  })

  it('nested brackets [[[[Title]]]] — regex lazy-matches target with leading [[', () => {
    // Regex target set [^\]|#\n] allows `[`, so lazy target expands past the
    // inner `[[` until the first `]]`. Match is `[[[[Title]]` with target=`[[Title`.
    // This pins the current behavior — if target charset is tightened to reject `[`,
    // this test will need updating.
    const results = parseWikilinks('[[[[Title]]]]')
    expect(results).toHaveLength(1)
    expect(results[0].target).toBe('[[Title')
  })
})

describe('parseWikilinks — lastIndex regression (stateful regex)', () => {
  it('calling parseWikilinks twice returns identical results (no lastIndex leak)', () => {
    const md = '[[Foo]] and [[Bar]]'
    const first = parseWikilinks(md)
    const second = parseWikilinks(md)
    expect(first).toEqual(second)
  })

  it('calling with different inputs back-to-back yields correct results', () => {
    const a = parseWikilinks('[[Alpha]]')
    const b = parseWikilinks('[[Beta]]')
    expect(a[0].target).toBe('Alpha')
    expect(b[0].target).toBe('Beta')
  })
})

// ============================================================
// slugify
// ============================================================

describe('slugify', () => {
  it('lowercases and hyphenates spaces', () => {
    expect(slugify('Hello World')).toBe('hello-world')
  })

  it('case insensitivity — all uppercase input', () => {
    expect(slugify('HELLO')).toBe('hello')
  })

  it('special characters stripped, keeps word chars and hyphens', () => {
    expect(slugify('foo!@#$%^&*()bar')).toBe('foobar')
  })

  it('underscores collapse to hyphens', () => {
    expect(slugify('foo_bar')).toBe('foo-bar')
  })

  it('multiple spaces collapse to single hyphen', () => {
    expect(slugify('foo    bar')).toBe('foo-bar')
  })

  it('leading and trailing hyphens are trimmed', () => {
    expect(slugify('--foo--')).toBe('foo')
  })

  it('empty string falls back to "section"', () => {
    expect(slugify('')).toBe('section')
  })

  it('all-special-chars falls back to "section"', () => {
    expect(slugify('!@#$%')).toBe('section')
  })

  it('mixed: leading/trailing spaces + punctuation', () => {
    expect(slugify('  Hello, World!  ')).toBe('hello-world')
  })

  it('hyphen preserved in the middle', () => {
    expect(slugify('foo-bar')).toBe('foo-bar')
  })

  it('consecutive hyphens in source — only leading/trailing are trimmed', () => {
    // Internal consecutive hyphens are NOT collapsed by the current impl
    expect(slugify('foo---bar')).toBe('foo---bar')
  })

  it('unicode non-ASCII stripped (ASCII-only \\w)', () => {
    // é, ö are non-ASCII — stripped by [^\w\s-] before the space-collapse pass,
    // so 'héllo wörld' → 'hllo wrld' → 'hllo-wrld' (NOT 'h-llo-w-rld').
    expect(slugify('Héllo Wörld')).toBe('hllo-wrld')
  })

  it('single word, no specials', () => {
    expect(slugify('introduction')).toBe('introduction')
  })

  it('heading with only special chars falls back to "section"', () => {
    expect(slugify('!!!')).toBe('section')
  })
})

// ============================================================
// extractHeadings
// ============================================================

describe('extractHeadings — basic matching', () => {
  it('basic H1 produces correct shape', () => {
    const headings = extractHeadings('# Title')
    expect(headings).toHaveLength(1)
    expect(headings[0].text).toBe('Title')
    expect(headings[0].level).toBe(1)
    expect(headings[0].slug).toBe('title')
    expect(headings[0].position).toBe(0)
  })

  it('all 6 heading levels in sequence', () => {
    const md = '# a\n## b\n### c\n#### d\n##### e\n###### f'
    const headings = extractHeadings(md)
    expect(headings).toHaveLength(6)
    expect(headings.map(h => h.level)).toEqual([1, 2, 3, 4, 5, 6])
    expect(headings.map(h => h.text)).toEqual(['a', 'b', 'c', 'd', 'e', 'f'])
  })

  it('H7+ is not matched', () => {
    expect(extractHeadings('####### too-deep')).toHaveLength(0)
  })

  it('no space after # is not matched', () => {
    expect(extractHeadings('#Title')).toHaveLength(0)
  })

  it('indented heading is not matched (regex anchors at ^)', () => {
    expect(extractHeadings('  # Indented')).toHaveLength(0)
  })

  it('trailing whitespace on heading text is trimmed', () => {
    const headings = extractHeadings('# Title   ')
    expect(headings[0].text).toBe('Title')
  })

  it('non-heading lines are ignored', () => {
    const md = 'Regular paragraph\n# Heading\nAnother para'
    const headings = extractHeadings(md)
    expect(headings).toHaveLength(1)
    expect(headings[0].text).toBe('Heading')
  })

  it('empty string returns empty array', () => {
    expect(extractHeadings('')).toHaveLength(0)
  })

  it('heading with only special chars — slug falls back to "section"', () => {
    const headings = extractHeadings('# !!!')
    expect(headings).toHaveLength(1)
    expect(headings[0].slug).toBe('section')
  })
})

describe('extractHeadings — position index', () => {
  it('position is 0-based occurrence index among headings, not line number', () => {
    const md = 'Some text\n# First\nMore text\n# Second'
    const headings = extractHeadings(md)
    expect(headings).toHaveLength(2)
    expect(headings[0].position).toBe(0)
    expect(headings[1].position).toBe(1)
  })

  it('preceding non-heading lines do not increment position', () => {
    const md = 'line1\nline2\nline3\n# Only Heading'
    const headings = extractHeadings(md)
    expect(headings[0].position).toBe(0)
  })
})

describe('extractHeadings — duplicate disambiguation', () => {
  it('3 identical headings → suffix appended from second onward', () => {
    const headings = extractHeadings('# Foo\n# Foo\n# Foo')
    expect(headings).toHaveLength(3)
    expect(headings[0].slug).toBe('foo')
    expect(headings[1].slug).toBe('foo-1')
    expect(headings[2].slug).toBe('foo-2')
  })

  it('duplicates across different levels still collide on slug', () => {
    const headings = extractHeadings('# Foo\n## Foo')
    expect(headings).toHaveLength(2)
    expect(headings[0].slug).toBe('foo')
    expect(headings[1].slug).toBe('foo-1')
  })

  it('second "section" fallback slug gets suffix', () => {
    const headings = extractHeadings('# !!!\n# ???')
    expect(headings[0].slug).toBe('section')
    expect(headings[1].slug).toBe('section-1')
  })
})

describe('extractHeadings — CRLF normalization (regression pin)', () => {
  it('CRLF line endings produce clean text without trailing \\r', () => {
    const headings = extractHeadings('# A\r\n# B')
    expect(headings).toHaveLength(2)
    expect(headings[0].text).toBe('A')
    expect(headings[1].text).toBe('B')
    expect(headings[0].slug).not.toContain('\r')
    expect(headings[1].slug).not.toContain('\r')
  })

  it('lone \\r (old Mac line endings) normalized correctly', () => {
    const headings = extractHeadings('# A\r# B')
    expect(headings).toHaveLength(2)
    expect(headings[0].text).toBe('A')
    expect(headings[1].text).toBe('B')
  })

  it('CRLF heading text has no \\r artifact in slug', () => {
    const headings = extractHeadings('# Hello World\r\n## Sub Section')
    expect(headings[0].slug).toBe('hello-world')
    expect(headings[1].slug).toBe('sub-section')
  })
})

// ============================================================
// renderWikilinks
// ============================================================

// Helpers to build fake ResolvedWikilink objects without hitting the DB.

function makeUnresolved(
  target: string,
  opts: { alias?: string; section?: string; startIdx?: number; endIdx?: number } = {}
): ResolvedWikilink {
  const raw = `[[${target}${opts.section ? '#' + opts.section : ''}${opts.alias ? '|' + opts.alias : ''}]]`
  const start = opts.startIdx ?? 0
  return {
    raw,
    target,
    alias: opts.alias ?? null,
    section: opts.section ?? null,
    startIdx: start,
    endIdx: start + raw.length,
    resolved: null,
    reason: 'not-found',
  }
}

function makeResolved(
  target: string,
  recordId: string,
  spaceId: string,
  opts: {
    alias?: string
    section?: string
    sectionValid?: boolean | null
    title?: string
    spaceName?: string
    startIdx?: number
    endIdx?: number
  } = {}
): ResolvedWikilink {
  const raw = `[[${target}${opts.section ? '#' + opts.section : ''}${opts.alias ? '|' + opts.alias : ''}]]`
  const start = opts.startIdx ?? 0
  return {
    raw,
    target,
    alias: opts.alias ?? null,
    section: opts.section ?? null,
    startIdx: start,
    endIdx: start + raw.length,
    resolved: {
      recordId,
      title: opts.title ?? target,
      spaceId,
      spaceName: opts.spaceName ?? 'Test Space',
      sectionValid: opts.sectionValid ?? null,
    },
  }
}

describe('renderWikilinks — unresolved links', () => {
  it('unresolved: href points to /library/new with encoded title', () => {
    const link = makeUnresolved('My Title')
    const html = renderWikilinks('[[My Title]]', [link])
    expect(html).toContain('href="/library/new?title=My%20Title"')
  })

  it('unresolved: class includes wikilink wikilink-unresolved', () => {
    const link = makeUnresolved('X')
    const html = renderWikilinks('[[X]]', [link])
    expect(html).toContain('class="wikilink wikilink-unresolved"')
  })

  it('unresolved: data-wikilink-target contains escaped target', () => {
    const link = makeUnresolved('X')
    const html = renderWikilinks('[[X]]', [link])
    expect(html).toContain('data-wikilink-target="X"')
  })

  it('unresolved: display text is the target when no alias', () => {
    const link = makeUnresolved('SomeTitle')
    const html = renderWikilinks('[[SomeTitle]]', [link])
    expect(html).toContain('>SomeTitle<')
  })

  it('unresolved: alias preferred over target as display text', () => {
    const link = makeUnresolved('X', { alias: 'click me' })
    const html = renderWikilinks('[[X|click me]]', [link])
    expect(html).toContain('>click me<')
    expect(html).not.toContain('>X<')
  })
})

describe('renderWikilinks — XSS escaping on unresolved', () => {
  it('target with < > & is escaped in data attribute', () => {
    const link = makeUnresolved('<script>')
    const html = renderWikilinks('[[<script>]]', [link])
    expect(html).toContain('data-wikilink-target="&lt;script&gt;"')
    expect(html).not.toContain('data-wikilink-target="<script>"')
  })

  it('target with " is escaped in data attribute', () => {
    const link = makeUnresolved('say "hi"')
    const html = renderWikilinks('[[say "hi"]]', [link])
    expect(html).toContain('data-wikilink-target="say &quot;hi&quot;"')
  })

  it('target with & is escaped in display text', () => {
    const link = makeUnresolved('A & B')
    const html = renderWikilinks('[[A & B]]', [link])
    expect(html).toContain('>A &amp; B<')
  })

  it('alias with HTML tags is escaped in display text', () => {
    const link = makeUnresolved('X', { alias: '<b>bold</b>' })
    const html = renderWikilinks('[[X|<b>bold</b>]]', [link])
    expect(html).toContain('>&lt;b&gt;bold&lt;/b&gt;<')
  })

  it('target with special URL chars is encodeURIComponent in query param', () => {
    const link = makeUnresolved('foo & bar?')
    const html = renderWikilinks('[[foo & bar?]]', [link])
    expect(html).toContain('href="/library/new?title=foo%20%26%20bar%3F"')
  })
})

describe('renderWikilinks — resolved links', () => {
  it('resolved: href is /library/{spaceId}/{recordId}', () => {
    const link = makeResolved('Title', 'rec1', 'sp1')
    const html = renderWikilinks('[[Title]]', [link])
    expect(html).toContain('href="/library/sp1/rec1"')
  })

  it('resolved: class includes wikilink wikilink-resolved', () => {
    const link = makeResolved('Title', 'rec1', 'sp1')
    const html = renderWikilinks('[[Title]]', [link])
    expect(html).toContain('class="wikilink wikilink-resolved"')
  })

  it('resolved with valid section: href ends in slugified #section', () => {
    const link = makeResolved('Title', 'rec1', 'sp1', {
      section: 'Hello World',
      sectionValid: true,
    })
    const html = renderWikilinks('[[Title#Hello World]]', [link])
    expect(html).toContain('href="/library/sp1/rec1#hello-world"')
  })

  it('resolved with null section (no section given): no # in href', () => {
    const link = makeResolved('Title', 'rec1', 'sp1', { sectionValid: null })
    const html = renderWikilinks('[[Title]]', [link])
    expect(html).toContain('href="/library/sp1/rec1"')
    expect(html).not.toContain('#')
  })

  it('resolved with sectionValid=false: class is wikilink-section-missing', () => {
    const link = makeResolved('Title', 'rec1', 'sp1', {
      section: 'Missing',
      sectionValid: false,
      title: 'Title',
    })
    const html = renderWikilinks('[[Title#Missing]]', [link])
    expect(html).toContain('class="wikilink wikilink-section-missing"')
  })

  it('resolved with sectionValid=false: href drops the #section suffix', () => {
    const link = makeResolved('Title', 'rec1', 'sp1', {
      section: 'Missing',
      sectionValid: false,
    })
    const html = renderWikilinks('[[Title#Missing]]', [link])
    expect(html).toContain('href="/library/sp1/rec1"')
    expect(html).not.toMatch(/href="\/library\/sp1\/rec1#/)
  })

  it('resolved with sectionValid=false: title attribute contains escaped section name', () => {
    const link = makeResolved('Title', 'rec1', 'sp1', {
      section: 'My Section',
      sectionValid: false,
      title: 'Title',
    })
    const html = renderWikilinks('[[Title#My Section]]', [link])
    expect(html).toContain('My Section')
    expect(html).toContain('not found')
  })

  it('resolved with sectionValid=false: section with special chars is escaped in title attr', () => {
    const link = makeResolved('Doc', 'r2', 's2', {
      section: '<evil>',
      sectionValid: false,
      title: 'Doc',
    })
    const html = renderWikilinks('[[Doc#<evil>]]', [link])
    expect(html).not.toContain('title="Section \'<evil>\'')
    expect(html).toContain('&lt;evil&gt;')
  })
})

describe('renderWikilinks — display text and surrounding text', () => {
  it('surrounding text is preserved', () => {
    const link = makeUnresolved('X', { startIdx: 4 })
    // fix endIdx
    link.endIdx = link.startIdx + link.raw.length
    const html = renderWikilinks('pre [[X]] post', [link])
    expect(html).toContain('pre ')
    expect(html).toContain(' post')
  })

  it('no links → markdown unchanged', () => {
    expect(renderWikilinks('Just plain text', [])).toBe('Just plain text')
  })

  it('empty markdown → empty string', () => {
    expect(renderWikilinks('', [])).toBe('')
  })
})

describe('renderWikilinks — multi-link index preservation (reverse-sort regression)', () => {
  it('3 links: out-of-order resolutions still render correctly', () => {
    // Build markdown with 3 links
    const md = '[[A]] then [[B]] then [[C]]'
    const linkA: ResolvedWikilink = makeUnresolved('A', { startIdx: 0 })
    const linkB: ResolvedWikilink = makeUnresolved('B', { startIdx: 11 })
    const linkC: ResolvedWikilink = makeUnresolved('C', { startIdx: 22 })

    // Fix endIdx values to match exact positions
    linkA.endIdx = 5   // '[[A]]'.length = 5
    linkB.endIdx = 16  // start 11 + 5
    linkC.endIdx = 27  // start 22 + 5

    // Pass resolutions in reverse order (C, A, B) — renderer must sort by startIdx desc
    const html = renderWikilinks(md, [linkC, linkA, linkB])

    // All three anchors must appear
    expect(html).toContain('data-wikilink-target="A"')
    expect(html).toContain('data-wikilink-target="B"')
    expect(html).toContain('data-wikilink-target="C"')

    // 'then' separators must survive
    expect(html).toContain(' then ')
  })

  it('resolved and unresolved links mixed render in correct positions', () => {
    const md = '[[Alpha]] and [[Beta]]'
    const linkAlpha = makeUnresolved('Alpha', { startIdx: 0 })
    linkAlpha.endIdx = 9

    const linkBeta = makeResolved('Beta', 'r1', 's1', { startIdx: 14 })
    linkBeta.endIdx = 22

    const html = renderWikilinks(md, [linkBeta, linkAlpha]) // deliberately reversed

    expect(html).toContain('wikilink-unresolved')
    expect(html).toContain('wikilink-resolved')
    expect(html).toContain(' and ')
  })
})
