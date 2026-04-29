#!/usr/bin/env bash
# presets/work/validate.sh
# Preset validation gate (Spec 034 v3 AC #49 — CRO H3 fix).
# Run by cabinet-spawn.sh BEFORE any container starts. Non-zero exit aborts spawn.
#
# Mirrors the pattern in presets/step-network/validate.sh.
# Checks required files, addenda content, preset.yml schema, and agent role-defs.

set -euo pipefail

PRESET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRESET_NAME="$(basename "$PRESET_DIR")"

fail() {
  echo "Preset $PRESET_NAME validation FAILED: $1" >&2
  exit 1
}

ok() {
  echo "✓ $1"
}

echo "→ Validating preset: $PRESET_NAME"

# 1. Required-files presence
required_files=(
  "preset.yml"
  "constitution-addendum.md"
  "safety-addendum.md"
  "schemas.sql"
  "terminology.yml"
  "agents"
)

for f in "${required_files[@]}"; do
  if [ ! -e "$PRESET_DIR/$f" ]; then
    fail "missing required: $f"
  fi
done
ok "all required files present"

# 2. Addenda non-empty + length sanity (no placeholder-only)
for addendum in constitution-addendum.md safety-addendum.md; do
  size=$(wc -c < "$PRESET_DIR/$addendum")
  if [ "$size" -lt 200 ]; then
    fail "$addendum is suspiciously short ($size bytes; <200 = likely placeholder)"
  fi
done
ok "addenda non-empty"

# 3. preset.yml schema check (key fields)
preset_yml="$PRESET_DIR/preset.yml"
for key in name description naming_style agent_archetypes terminology workspace_mount; do
  if ! grep -q "^${key}:" "$preset_yml"; then
    fail "preset.yml missing required key: $key"
  fi
done
ok "preset.yml schema valid"

# 4. Agent role-defs parse (frontmatter + non-empty body)
agents_dir="$PRESET_DIR/agents"
if [ -z "$(ls -A "$agents_dir" 2>/dev/null | grep -v README)" ]; then
  if [ ! -f "$agents_dir/README.md" ]; then
    fail "agents/ is empty and no README.md describing inheritance source"
  fi
  ok "agents/ uses inheritance README pattern"
else
  for agent_md in "$agents_dir"/*.md; do
    [ -e "$agent_md" ] || continue
    [ "$(basename "$agent_md")" = "README.md" ] && continue
    if ! head -1 "$agent_md" | grep -q "^---$" 2>/dev/null && ! grep -q "^# " "$agent_md"; then
      fail "agent role-def missing frontmatter or top heading: $(basename "$agent_md")"
    fi
    body_size=$(wc -c < "$agent_md")
    if [ "$body_size" -lt 500 ]; then
      fail "agent role-def too short ($body_size bytes; likely placeholder): $(basename "$agent_md")"
    fi
  done
  ok "agent role-defs parse"
fi

# 5. mcp-scope.yml check (if preset declares one)
if [ -f "$PRESET_DIR/mcp-scope.yml" ]; then
  if ! grep -q "^agents:" "$PRESET_DIR/mcp-scope.yml" 2>/dev/null; then
    fail "mcp-scope.yml missing 'agents:' section"
  fi
  ok "mcp-scope.yml present + parsed"
fi

# 6. naming_style sanity
naming_style=$(grep "^naming_style:" "$preset_yml" | awk '{print $2}')
case "$naming_style" in
  functional|role-initials|personal) ok "naming_style: $naming_style" ;;
  *) fail "naming_style invalid: $naming_style (must be functional|role-initials|personal)" ;;
esac

echo "✅ Preset $PRESET_NAME validation PASSED"
exit 0
