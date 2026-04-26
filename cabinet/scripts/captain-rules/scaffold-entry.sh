#!/bin/bash
# cabinet/scripts/captain-rules/scaffold-entry.sh — Spec 042 author helper
#
# Interactive scaffold for the <!-- index: ... --> block authors paste alongside
# every new entry in captain-patterns.md / captain-intents.md.
#
# Asks 7 questions, emits a copy-paste-ready block to stdout. Doesn't auto-extract
# (V1 stays curated per Spec 042 §Out-of-scope) — just removes the "remember the
# YAML shape" friction so authors don't have to keep referring to the README.
#
# Usage:
#   bash cabinet/scripts/captain-rules/scaffold-entry.sh
#   bash cabinet/scripts/captain-rules/scaffold-entry.sh > /tmp/block.txt && cat /tmp/block.txt

set -u

usage() {
  cat <<EOF
Usage: $(basename "$0")
Emits a <!-- index: ... --> block to stdout. Paste it directly above your
new entry in captain-patterns.md or captain-intents.md.

Questions asked:
  1) ID            — short identifier (e.g., A1, P-Proactive-Task-Creation, I-W-005)
  2) Section       — anchor | pattern | intent
  3) Title         — short imperative phrase (matches the markdown heading)
  4) Trigger words — comma-separated, lowercase. Hand-curated; the floor for
                     keyword retrieval. Pick 4–8 distinctive phrases that would
                     appear in a Captain DM where this rule should fire.
  5) Scope         — all_officers | cos | cto | etc.
  6) Author        — defaults to the active git user.name (lowercased, slug)
  7) Excerpt       — one-paragraph distilled rule body (what to do, not the
                     full evidence trail). 1–2 sentences.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

prompt() {
  local q="$1"
  local default="${2:-}"
  local ans=""
  if [ -n "$default" ]; then
    read -r -p "$q [$default]: " ans
    ans="${ans:-$default}"
  else
    read -r -p "$q: " ans
  fi
  printf '%s' "$ans"
}

today=$(date -u +%Y-%m-%d)
default_author=$(git config user.name 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -d ' ')
default_author="${default_author:-cos}"

id=$(prompt "ID")
if [ -z "$id" ] || ! echo "$id" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_/.\-]*$'; then
  echo "ERROR: id required, must be [A-Za-z0-9_/-.]+ (got: ${id:-<empty>})" >&2
  exit 1
fi

section=$(prompt "Section (anchor|pattern|intent)" "pattern")
case "$section" in
  anchor|pattern|intent) ;;
  *) echo "ERROR: section must be one of: anchor, pattern, intent (got: $section)" >&2; exit 1 ;;
esac

title=$(prompt "Title")
[ -z "$title" ] && { echo "ERROR: title required" >&2; exit 1; }

triggers=$(prompt "Trigger words (comma-separated)")
[ -z "$triggers" ] && { echo "ERROR: trigger words required (4-8 distinctive phrases)" >&2; exit 1; }

scope=$(prompt "Scope" "all_officers")
if ! echo "$scope" | grep -Eq '^[a-z0-9_]+$'; then
  echo "ERROR: scope must be lowercase identifier (got: $scope)" >&2
  exit 1
fi

author=$(prompt "Added by" "$default_author")
if ! echo "$author" | grep -Eq '^[a-z0-9_-]+$'; then
  echo "ERROR: added_by must be lowercase slug (got: $author)" >&2
  exit 1
fi

excerpt=$(prompt "Excerpt (1-2 sentences)")
[ -z "$excerpt" ] && { echo "ERROR: excerpt required (1-2 sentences)" >&2; exit 1; }

# Format trigger words as a YAML list literal: ["a", "b", "c"]
trig_yaml=""
IFS=',' read -ra arr <<< "$triggers"
for w in "${arr[@]}"; do
  w_trim=$(echo "$w" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$w_trim" ] && continue
  esc=$(echo "$w_trim" | sed 's/"/\\"/g')
  if [ -z "$trig_yaml" ]; then
    trig_yaml="\"$esc\""
  else
    trig_yaml="$trig_yaml, \"$esc\""
  fi
done
trig_yaml="[$trig_yaml]"

# Quote-escape title and excerpt for embedding in the YAML key:value lines.
title_esc=$(echo "$title" | sed 's/"/\\"/g')
excerpt_esc=$(echo "$excerpt" | sed 's/"/\\"/g')

cat <<EOF
<!-- index:
id: $id
section: $section
title: "$title_esc"
trigger_words: $trig_yaml
scope: $scope
added: $today
added_by: $author
excerpt: "$excerpt_esc"
-->
EOF
