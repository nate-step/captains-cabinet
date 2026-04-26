#!/bin/bash
# cabinet/scripts/captain-rules/query.sh — Spec 042 Phase 2 retrieval
#
# Scores entries in shared/interfaces/captain-rules-index.yaml against an
# incoming Captain DM and emits a structured markdown block ready for
# system-reminder injection.
#
# Match logic (V1 keep-it-stupid):
#   1. Always include all `section: anchor` entries.
#   2. Score remaining entries by trigger-word match in dm_text. Each
#      hit = 1 point. Officer-slug-relevant scope bumps by 0.5.
#   3. Return top N non-anchor entries above threshold (default 1).
#
# Native: bash entrypoint + Python stdlib parser (no PyYAML, no deps).
# Latency budget per Spec 042 AC #4: <100ms for index up to 50 entries.
#
# Usage:
#   bash cabinet/scripts/captain-rules/query.sh <officer_slug> <dm_text> [<context_hint>]
#   QUERY_TOP_N=3 QUERY_THRESHOLD=2 bash cabinet/scripts/captain-rules/query.sh ...

set -eu

if [ $# -lt 2 ]; then
  cat >&2 <<EOF
Usage: $(basename "$0") <officer_slug> <dm_text> [<context_hint>]

Reads shared/interfaces/captain-rules-index.yaml and emits the retrieval
block to stdout. Empty stdout = no anchors + no scored hits (caller may
suppress injection).

Env knobs:
  INDEX_FILE       — override index path (default: shared/interfaces/captain-rules-index.yaml)
  QUERY_TOP_N      — top-N non-anchor entries (default: 5)
  QUERY_THRESHOLD  — minimum score for non-anchor entry (default: 1)
EOF
  exit 1
fi

OFFICER="$1"
DM_TEXT="$2"
CTX="${3:-}"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || echo /opt/founders-cabinet)}"
INDEX_FILE="${INDEX_FILE:-$REPO_ROOT/shared/interfaces/captain-rules-index.yaml}"

if [ ! -f "$INDEX_FILE" ]; then
  echo "[query] index not found at $INDEX_FILE" >&2
  exit 0  # No index = no injection. Don't fail the hook.
fi

# Freshness warning: index older than either source file → log to stderr.
for src in "$REPO_ROOT/shared/interfaces/captain-patterns.md" "$REPO_ROOT/shared/interfaces/captain-intents.md"; do
  if [ -f "$src" ] && [ "$src" -nt "$INDEX_FILE" ]; then
    echo "[query] WARN: $(basename "$src") newer than index — re-run cabinet/scripts/captain-rules/index.sh" >&2
  fi
done

exec python3 - "$INDEX_FILE" "$OFFICER" "$DM_TEXT" "$CTX" <<'PYEOF'
import sys, os, re

index_path = sys.argv[1]
officer = sys.argv[2].strip().lower()
dm_text = sys.argv[3]
ctx = sys.argv[4]

TOP_N = int(os.environ.get('QUERY_TOP_N', '5'))
THRESHOLD = float(os.environ.get('QUERY_THRESHOLD', '1'))

# ---- YAML parser: hand-rolled for our fixed indexer-emitted schema ----
# We control the input format, so a line-state-machine handles it without PyYAML.

def parse_index(path):
    """Parse our deterministic 2-space-indent YAML index. Returns list of entry dicts."""
    entries = []
    cur = None
    in_entries = False
    with open(path) as f:
        for line in f:
            line = line.rstrip('\n')
            if not in_entries:
                if line.strip() == 'entries:':
                    in_entries = True
                continue
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            if line.startswith('  - id:'):
                if cur:
                    entries.append(cur)
                cur = {'id': stripped[len('- id:'):].strip()}
                continue
            if line.startswith('    ') and cur is not None and ':' in stripped:
                # Split only on the first colon — values may contain colons
                # (e.g., title: "Build vs. buy: tradeoffs").
                key, _, val = stripped.partition(':')
                key = key.strip()
                val = val.lstrip()
                # Unwrap double-quoted scalars
                if len(val) >= 2 and val[0] == '"' and val[-1] == '"':
                    val = val[1:-1].replace('\\"', '"').replace('\\\\', '\\')
                cur[key] = val
        if cur:
            entries.append(cur)
    return entries


def parse_trigger_words(raw, entry_id=None):
    """Extract list-of-strings from `["a", "b", ...]` literal. Tolerates quoted commas.
    Warns on malformed (unquoted, no brackets) input so author errors aren't silent."""
    if not raw:
        return []
    raw = raw.strip()
    if not (raw.startswith('[') and raw.endswith(']')):
        sys.stderr.write(f"[query] WARN: trigger_words for {entry_id or '?'} is not a YAML list literal: {raw!r}\n")
        return []
    inner = raw[1:-1]
    out = []
    buf = []
    in_quote = False
    escape = False
    for ch in inner:
        if escape:
            buf.append(ch); escape = False; continue
        if ch == '\\':
            escape = True; continue
        if ch == '"':
            in_quote = not in_quote; continue
        if ch == ',' and not in_quote:
            s = ''.join(buf).strip()
            if s:
                out.append(s)
            buf = []
            continue
        if in_quote:
            buf.append(ch)
    s = ''.join(buf).strip()
    if s:
        out.append(s)
    if not out and inner.strip():
        sys.stderr.write(f"[query] WARN: trigger_words for {entry_id or '?'} parsed empty from non-empty list: {raw!r}\n")
    return out


def score_entry(entry, dm_lower, officer):
    """Count trigger-word hits + scope bump. Returns (score, hits, scope_match).
    scope_match=True means this entry's scope is officer-specific and matches —
    callers may use that to apply a softer threshold so officer-targeted rules
    surface even with weak trigger-word coverage."""
    triggers = parse_trigger_words(entry.get('trigger_words', ''), entry.get('id'))
    score = 0.0
    hits = []
    for t in triggers:
        if not t:
            continue
        # Substring match (lowercased on both sides). Word-boundary would be
        # tighter but trigger phrases often contain punctuation/spaces — Spec
        # 042 V1 calls keyword baseline; tighten in Phase 3 if eval shows FPs.
        if t.lower() in dm_lower:
            score += 1.0
            hits.append(t)
    scope = entry.get('scope', '').strip().lower()
    scope_match = bool(scope and scope != 'all_officers' and scope == officer)
    if scope_match:
        score += 0.5
    return score, hits, scope_match


def emit_block(anchors, scored_hits):
    """Format the retrieval block per Spec 042 §Captain-DM-incoming-hook."""
    lines = ["🎯 RULES IN PLAY FOR THIS DM (auto-retrieved):", ""]
    if anchors:
        lines.append("ANCHORS (always apply):")
        for e in anchors:
            lines.append(f"  {e['id']} {e.get('title', '').strip()}: {e.get('excerpt', '').strip()}")
        lines.append("")

    patterns = [(s, h, e) for s, h, e in scored_hits if e.get('section') == 'pattern']
    intents = [(s, h, e) for s, h, e in scored_hits if e.get('section') == 'intent']

    if patterns:
        lines.append("RELEVANT PATTERNS:")
        for score, hits, e in patterns:
            hit_note = f" [hits: {', '.join(hits)}]" if hits else ""
            lines.append(f"  {e['id']} {e.get('title', '').strip()}: {e.get('excerpt', '').strip()}{hit_note}")
        lines.append("")
    if intents:
        lines.append("RELEVANT INTENTS:")
        for score, hits, e in intents:
            hit_note = f" [hits: {', '.join(hits)}]" if hits else ""
            lines.append(f"  {e['id']} {e.get('title', '').strip()}: {e.get('excerpt', '').strip()}{hit_note}")
        lines.append("")

    lines.append("(full text + evidence at shared/interfaces/captain-patterns.md / captain-intents.md)")
    return "\n".join(lines)


# ---- Run ----
entries = parse_index(index_path)
if not entries:
    sys.exit(0)

anchors = [e for e in entries if e.get('section') == 'anchor']
non_anchors = [e for e in entries if e.get('section') != 'anchor']

dm_lower = dm_text.lower()
scored = []
for e in non_anchors:
    score, hits, scope_match = score_entry(e, dm_lower, officer)
    # Officer-scoped entries surface at a softer threshold so a CTO-only rule
    # with poor trigger coverage isn't permanently invisible. all_officers
    # entries still need to clear THRESHOLD on trigger hits alone.
    effective_threshold = THRESHOLD / 2 if scope_match else THRESHOLD
    if score >= effective_threshold:
        scored.append((score, hits, e))

# Sort by score DESC, then by id ASC for tie-break determinism.
scored.sort(key=lambda x: (-x[0], x[2]['id']))
top = scored[:TOP_N]

# If no anchors AND no scored hits → emit nothing (caller suppresses injection).
if not anchors and not top:
    sys.exit(0)

print(emit_block(anchors, top))
PYEOF
