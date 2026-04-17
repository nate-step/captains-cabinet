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
# Apply framework base + preset schemas (idempotent)
# Phase 1 CP1 (Captain 2026-04-16): no contexts DB table. YAML files at
# instance/config/contexts/*.yml are source of truth. Target tables carry
# a context_slug column; validation in pre-tool-use hook (CP2).
# ---------------------------------------------------------------

# Product Neon schemas (external)
if [ -n "${NEON_CONNECTION_STRING:-}" ]; then
  for schema in \
    "$CABINET_ROOT/cabinet/sql/cabinet_memory.sql" \
    "$CABINET_ROOT/cabinet/sql/library.sql" \
    "$CABINET_ROOT/cabinet/sql/contexts-neon-phase1.sql"; do
    if [ -f "$schema" ]; then
      if psql "$NEON_CONNECTION_STRING" -q -f "$schema" > /dev/null 2>&1; then
        log "Applied framework schema (neon): $(basename "$schema")"
      else
        log "WARN: failed to apply $schema to Neon (Cabinet will still boot; fix before new records)"
      fi
    fi
  done

  # Preset-specific schemas (Neon)
  if [ -f "$PRESET_DIR/schemas.sql" ]; then
    if psql "$NEON_CONNECTION_STRING" -q -f "$PRESET_DIR/schemas.sql" > /dev/null 2>&1; then
      log "Applied preset schema: $ACTIVE_PRESET/schemas.sql"
    else
      log "WARN: failed to apply preset schema"
    fi
  fi
else
  log "WARN: NEON_CONNECTION_STRING not set — skipping Neon schema application"
fi

# Cabinet postgres schemas (internal) — additive migrations for Phase 1+
if [ -n "${DATABASE_URL:-}" ]; then
  for schema in \
    "$CABINET_ROOT/cabinet/sql/contexts-cabinet-phase1.sql"; do
    if [ -f "$schema" ]; then
      if psql "$DATABASE_URL" -q -f "$schema" > /dev/null 2>&1; then
        log "Applied framework schema (cabinet-pg): $(basename "$schema")"
      else
        log "WARN: failed to apply $schema to cabinet postgres"
      fi
    fi
  done
else
  log "WARN: DATABASE_URL not set — skipping cabinet postgres schema application"
fi

# ---------------------------------------------------------------
# Populate .claude/agents/ from preset + instance overlay
# ---------------------------------------------------------------
AGENTS_DIR="$CABINET_ROOT/.claude/agents"
mkdir -p "$AGENTS_DIR"

# 1. Copy preset agents (baseline). Skip TEMPLATE and SCAFFOLD role defs —
# scaffolds (Phase 1 CP4+) are staged role definitions that Captain hasn't
# hired yet. A scaffold is identified by a first-line SCAFFOLD banner block
# (`> **SCAFFOLD...` within the first 5 lines). Hiring via
# `cabinet/scripts/create-officer.sh` removes the banner and the loader
# starts copying it on next boot.
if [ -d "$PRESET_DIR/agents" ]; then
  copied=0
  skipped=0
  for src in "$PRESET_DIR/agents"/*.md; do
    [ -f "$src" ] || continue
    basename=$(basename "$src")
    # Skip TEMPLATE.md
    [ "$basename" = "TEMPLATE.md" ] && continue
    # Skip SCAFFOLD role defs — not yet hired
    if head -5 "$src" | grep -q 'SCAFFOLD'; then
      skipped=$((skipped + 1))
      continue
    fi
    cp "$src" "$AGENTS_DIR/$basename"
    copied=$((copied + 1))
  done
  log "Populated agents from preset: $copied hired, $skipped scaffolds skipped"
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
