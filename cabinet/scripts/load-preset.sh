#!/bin/bash
# load-preset.sh — Assemble the Cabinet runtime state from framework + preset + instance.
#
# Called at container/officer start. Safe to run multiple times — idempotent.
# The loader produces runtime artifacts at /tmp/cabinet-runtime/:
#   - constitution.md     (framework constitution-base + preset addendum)
#   - safety-boundaries.md (framework base + preset safety addendum)
#
# These are the files CLAUDE.md references at session start. The loader also:
# - Applies framework base schemas + preset schemas to Neon (idempotent)
# - Populates .claude/agents/ from presets/<slug>/agents/ (with instance overlay)
#
# Usage:
#   bash cabinet/scripts/load-preset.sh         # use active preset from instance/config/active-preset
#   bash cabinet/scripts/load-preset.sh <slug>  # force a specific preset (mostly for testing)

set -uo pipefail

CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
RUNTIME_DIR="/tmp/cabinet-runtime"
ACTIVE_PRESET_FILE="$CABINET_ROOT/instance/config/active-preset"

mkdir -p "$RUNTIME_DIR"

log() {
  echo "[load-preset $(date -u +%H:%M:%S)] $1" >&2
}

# ---------------------------------------------------------------
# Determine active preset
# ---------------------------------------------------------------
if [ -n "${1:-}" ]; then
  ACTIVE_PRESET="$1"
else
  if [ -f "$ACTIVE_PRESET_FILE" ]; then
    ACTIVE_PRESET=$(cat "$ACTIVE_PRESET_FILE" | tr -d '[:space:]')
  else
    # Default for forkers who haven't set anything
    ACTIVE_PRESET="work"
    log "WARN: $ACTIVE_PRESET_FILE not found — defaulting to 'work'"
  fi
fi

PRESET_DIR="$CABINET_ROOT/presets/$ACTIVE_PRESET"
if [ ! -d "$PRESET_DIR" ]; then
  log "ERROR: active preset '$ACTIVE_PRESET' not found at $PRESET_DIR"
  exit 1
fi

# Reject _template as an active preset — it's a scaffolding skeleton
if [ "$ACTIVE_PRESET" = "_template" ]; then
  log "ERROR: _template is not a loadable preset. Copy it to presets/<your-slug>/ first."
  exit 1
fi

# Reject empty presets (e.g. personal/ is a placeholder until Phase 2)
if [ ! -f "$PRESET_DIR/preset.yml" ]; then
  log "ERROR: preset '$ACTIVE_PRESET' is not populated (no preset.yml). Populate it first or switch to a populated preset."
  exit 1
fi

log "Loading preset: $ACTIVE_PRESET"

# ---------------------------------------------------------------
# Assemble constitution = framework base + preset addendum
# ---------------------------------------------------------------
CONSTITUTION_TMP="$RUNTIME_DIR/.constitution.md.tmp.$$"
{
  cat "$CABINET_ROOT/framework/constitution-base.md"
  echo ""
  echo "---"
  echo ""
  echo "# Preset Addendum: $ACTIVE_PRESET"
  echo ""
  if [ -f "$PRESET_DIR/constitution-addendum.md" ]; then
    # Skip the first `# ...` heading from the addendum (we just wrote one above)
    awk 'NR==1 && /^# / {next} {print}' "$PRESET_DIR/constitution-addendum.md"
  fi
} > "$CONSTITUTION_TMP"
mv "$CONSTITUTION_TMP" "$RUNTIME_DIR/constitution.md"
log "Assembled constitution → $RUNTIME_DIR/constitution.md ($(wc -l < "$RUNTIME_DIR/constitution.md") lines)"

# ---------------------------------------------------------------
# Assemble safety boundaries = framework base + preset addendum
# ---------------------------------------------------------------
SAFETY_TMP="$RUNTIME_DIR/.safety-boundaries.md.tmp.$$"
{
  cat "$CABINET_ROOT/framework/safety-boundaries-base.md"
  echo ""
  echo "---"
  echo ""
  echo "# Preset Safety Addendum: $ACTIVE_PRESET"
  echo ""
  if [ -f "$PRESET_DIR/safety-addendum.md" ]; then
    awk 'NR==1 && /^# / {next} {print}' "$PRESET_DIR/safety-addendum.md"
  fi
} > "$SAFETY_TMP"
mv "$SAFETY_TMP" "$RUNTIME_DIR/safety-boundaries.md"
log "Assembled safety boundaries → $RUNTIME_DIR/safety-boundaries.md"

# ---------------------------------------------------------------
# Apply framework base + preset schemas to Neon (idempotent)
# ---------------------------------------------------------------
if [ -n "${NEON_CONNECTION_STRING:-}" ]; then
  # Framework base schemas (all CREATE TABLE IF NOT EXISTS via the individual files)
  for schema in \
    "$CABINET_ROOT/cabinet/sql/cabinet_memory.sql" \
    "$CABINET_ROOT/cabinet/sql/library.sql"; do
    if [ -f "$schema" ]; then
      if psql "$NEON_CONNECTION_STRING" -q -f "$schema" > /dev/null 2>&1; then
        log "Applied framework schema: $(basename "$schema")"
      else
        log "WARN: failed to apply $schema (Cabinet will still boot; fix before new Spaces created)"
      fi
    fi
  done

  # Preset-specific schemas
  if [ -f "$PRESET_DIR/schemas.sql" ]; then
    if psql "$NEON_CONNECTION_STRING" -q -f "$PRESET_DIR/schemas.sql" > /dev/null 2>&1; then
      log "Applied preset schema: $ACTIVE_PRESET/schemas.sql"
    else
      log "WARN: failed to apply preset schema"
    fi
  fi
else
  log "WARN: NEON_CONNECTION_STRING not set — skipping schema application"
fi

# ---------------------------------------------------------------
# Populate .claude/agents/ from preset + instance overlay
# ---------------------------------------------------------------
AGENTS_DIR="$CABINET_ROOT/.claude/agents"
mkdir -p "$AGENTS_DIR"

# 1. Copy preset agents (baseline)
if [ -d "$PRESET_DIR/agents" ]; then
  for src in "$PRESET_DIR/agents"/*.md; do
    [ -f "$src" ] || continue
    basename=$(basename "$src")
    # Skip TEMPLATE.md
    [ "$basename" = "TEMPLATE.md" ] && continue
    cp "$src" "$AGENTS_DIR/$basename"
  done
  log "Populated agents from preset: $(ls "$PRESET_DIR/agents"/*.md 2>/dev/null | grep -v TEMPLATE | wc -l) files"
fi

# 2. Instance overrides (take precedence)
if [ -d "$CABINET_ROOT/instance/agents" ]; then
  for src in "$CABINET_ROOT/instance/agents"/*.md; do
    [ -f "$src" ] || continue
    basename=$(basename "$src")
    cp "$src" "$AGENTS_DIR/$basename"
    log "Instance agent override: $basename"
  done
fi

log "Preset '$ACTIVE_PRESET' loaded successfully"
