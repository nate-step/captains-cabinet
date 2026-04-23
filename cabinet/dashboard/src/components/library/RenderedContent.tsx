/**
 * RenderedContent — Spec 037 Q2 / Q4
 *
 * Server component that:
 *   1. Parses + resolves wikilinks in a record's markdown (server-side DB lookups).
 *   2. Calls renderWikilinks() to replace [[...]] with <a class="wikilink-*"> tags.
 *   3. Renders the resulting HTML via dangerouslySetInnerHTML.
 *   4. Wraps the container in the WikilinkHovercard client island so that hovering
 *      or focusing a resolved wikilink shows the Q2 preview card.
 *
 * Q4 dashed-dim styling lives in globals.css (.wikilink-unresolved, .wikilink-section-missing).
 * Q2 hovercard logic lives in WikilinkHovercard.tsx (event delegation on the container).
 *
 * The markdown itself is NOT processed through rehype/remark here — the existing
 * editor preview in record-editor.tsx uses plain text; this component is the
 * new read-mode view added by this PR. Full remark/rehype integration (code
 * highlighting, TOC) is a Phase B enhancement.
 */

import { parseWikilinks, resolveWikilinks, renderWikilinks } from '@/lib/wikilinks'
import WikilinkHovercard from './WikilinkHovercard'

interface Props {
  markdown: string
  spaceId: string
  className?: string
}

export default async function RenderedContent({ markdown, spaceId, className }: Props) {
  // 1. Parse all [[...]] wikilinks from the markdown source
  const parsed = parseWikilinks(markdown)

  // 2. Resolve against DB (batched; prefers current-space records first)
  const resolved = await resolveWikilinks(parsed, spaceId)

  // 3. Replace [[...]] tokens with <a class="wikilink-*"> HTML strings
  const withLinks = renderWikilinks(markdown, resolved)

  // 4. Convert newlines to <br> for very basic readability.
  //    paragraphs (double-newline) get a visual break; single newlines get <br>.
  //    This intentionally avoids a full markdown pipeline for Phase A — the spec
  //    focuses on navigation + linking, not editor-grade rendering.
  const html = withLinks
    .split('\n\n')
    .map((para) => `<p>${para.replace(/\n/g, '<br />')}</p>`)
    .join('\n')

  return (
    // WikilinkHovercard is a client island — wraps the static HTML container
    // and intercepts pointer/keyboard events via event delegation.
    <WikilinkHovercard className={`relative ${className ?? ''}`}>
      {/*
        prose-invert Tailwind typography styles are not installed, so we apply
        baseline readability styles inline. The wikilink-* classes from globals.css
        are applied to the <a> tags emitted by renderWikilinks().
      */}
      <div
        className="rendered-content text-sm text-zinc-300 leading-relaxed space-y-3"
        dangerouslySetInnerHTML={{ __html: html }}
      />
    </WikilinkHovercard>
  )
}
