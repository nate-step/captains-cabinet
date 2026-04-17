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
# CABINET_ID validator (Phase 1 CP9b)
# ---------------------------------------------------------------
# cabinet_id lands in every officer-produced record. Phase 1 default is
# 'main' (single-Cabinet deployments). Phase 2 adds a second Cabinet
# instance via CABINET_MODE=multi + per-instance CABINET_ID — if the
# env var is unset in multi mode the boot aborts rather than silently
# joining the 'main' namespace. In Phase 1 default mode, the validator
# only enforces character safety so the value is safe to inject into
# JSONL log lines.
CABINET_ID="${CABINET_ID:-main}"
CABINET_MODE="${CABINET_MODE:-single}"

if ! [[ "$CABINET_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  log "ERROR: CABINET_ID='$CABINET_ID' contains invalid characters (allowed: [a-zA-Z0-9_-])"
  exit 1
fi

if [ "$CABINET_MODE" = "multi" ] && [ "$CABINET_ID" = "main" ]; then
  log "ERROR: CABINET_MODE=multi requires an explicit CABINET_ID (got the default 'main')."
  log "       Set CABINET_ID=<this-cabinet-slug> in the instance env before loading."
  exit 1
fi

export CABINET_ID CABINET_MODE

# ---------------------------------------------------------------
# peers.yml validation (Phase 2 CP3)
# ---------------------------------------------------------------
# If instance/config/peers.yml exists, validate its schema at boot so
# bad config fails loud instead of surfacing as cryptic MCP errors.
# Schema: per peer (indented at 2 spaces), required keys are role,
# endpoint, capacity, trust_level, consented_by_captain, allowed_tools.
# In single-Cabinet mode this file is informational — it's a placeholder
# for the Personal Cabinet. In multi mode every peer must be validated.
PEERS_FILE="$CABINET_ROOT/instance/config/peers.yml"
if [ -f "$PEERS_FILE" ]; then
  python3 - "$PEERS_FILE" "$CABINET_MODE" <<'PY' 2>&1
import re, sys
path, mode = sys.argv[1], sys.argv[2]
text = open(path).read()

# Extract peer entries: top-level 'peers:' block, then 2-space-indented peer ids.
peers = {}
current = None
last_list_key = None  # tracks the most-recently-declared list-valued key
                      # for yaml-list-continuation; not hardcoded to allowed_tools
for raw in text.splitlines():
    line = raw.rstrip()
    if not line or line.lstrip().startswith('#'):
        continue
    if re.match(r'^peers:\s*$', line):
        continue
    m = re.match(r'^  ([A-Za-z][A-Za-z0-9_-]*):\s*$', line)
    if m:
        current = m.group(1)
        peers[current] = {}
        last_list_key = None
        continue
    if current is None:
        continue
    mk = re.match(r'^\s{4,}([a-z_]+):\s*(.*)$', line)
    if mk:
        k, v = mk.group(1), mk.group(2).strip().strip('"\'')
        if v.startswith('[') and v.endswith(']'):
            peers[current][k] = [x.strip() for x in v[1:-1].split(',') if x.strip()]
            last_list_key = k
        elif v.lower() in ('true', 'false'):
            peers[current][k] = v.lower() == 'true'
            last_list_key = None
        elif v == '' or v == '>':
            # Empty value means either a list-will-follow or a folded-scalar.
            # For a folded scalar like notes: >, subsequent indented content
            # lines are absorbed as the value (not parsed as keys).
            if k in ('allowed_tools',):  # add other list-typed keys here if added to schema
                peers[current][k] = peers[current].get(k, [])
                last_list_key = k
            else:
                # Treat as folded-scalar start; following deeper-indented lines
                # belong to this key. last_list_key=None so continuation-line
                # regex below won't try to parse them as list items.
                peers[current][k] = ''
                last_list_key = None
        elif v:
            peers[current][k] = v
            last_list_key = None
    elif last_list_key is not None and re.match(r'^\s{4,}- (.+)$', line):
        # List-continuation for the most-recently-seen list key (not
        # hardcoded to allowed_tools — so new list fields can be added
        # to schema without reintroducing the yaml-drift bug).
        item = re.match(r'^\s{4,}- (.+)$', line).group(1).strip().strip('"\'')
        peers[current].setdefault(last_list_key, []).append(item)

# Validate each peer
REQUIRED = ['role', 'endpoint', 'capacity', 'trust_level', 'consented_by_captain', 'allowed_tools']
CAPACITIES = {'work', 'personal'}
TRUST = {'low', 'medium', 'high'}
# VALID_TOOLS must stay in sync with cabinet/mcp-server/server.py TOOLS registry.
# Update both files when a Cabinet MCP tool is added/removed.
VALID_TOOLS = {'identify', 'presence', 'availability', 'send_message', 'request_handoff'}

problems = []
for pid, p in peers.items():
    for r in REQUIRED:
        if r not in p:
            problems.append(f"peer '{pid}' missing required field: {r}")
    if 'capacity' in p and p['capacity'] not in CAPACITIES:
        problems.append(f"peer '{pid}' invalid capacity: {p['capacity']}")
    if 'trust_level' in p and p['trust_level'] not in TRUST:
        problems.append(f"peer '{pid}' invalid trust_level: {p['trust_level']}")
    if 'consented_by_captain' in p and not isinstance(p['consented_by_captain'], bool):
        problems.append(f"peer '{pid}' consented_by_captain must be boolean")
    if 'allowed_tools' in p:
        unknown = [t for t in p['allowed_tools'] if t not in VALID_TOOLS]
        if unknown:
            problems.append(f"peer '{pid}' unknown allowed_tools: {unknown}")

if problems:
    print(f"[peers.yml] {len(problems)} problem(s):", file=sys.stderr)
    for pr in problems:
        print(f"  - {pr}", file=sys.stderr)
    # In multi-mode, fail boot. In single-mode, warn and continue.
    if mode == 'multi':
        sys.exit(1)
    sys.exit(0)

active = [pid for pid, p in peers.items() if p.get('consented_by_captain')]
print(f"[peers.yml] {len(peers)} peer(s) parsed, {len(active)} with consented_by_captain=true", file=sys.stderr)
PY
  validator_exit=$?
  if [ "$validator_exit" -ne 0 ] && [ "$CABINET_MODE" = "multi" ]; then
    log "ERROR: peers.yml validation failed (multi-Cabinet mode). Fix config and retry."
    exit 1
  fi
fi

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
    "$CABINET_ROOT/cabinet/sql/contexts-neon-phase1.sql" \
    "$CABINET_ROOT/cabinet/sql/cabinet-id-neon-phase1.sql" \
    "$CABINET_ROOT/cabinet/sql/cabinet-id-neon-phase1b.sql"; do
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
    "$CABINET_ROOT/cabinet/sql/contexts-cabinet-phase1.sql" \
    "$CABINET_ROOT/cabinet/sql/cabinet-id-phase1.sql" \
    "$CABINET_ROOT/cabinet/sql/cabinet-id-phase1b.sql"; do
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

# 1. Copy preset agents (baseline). Single source of truth for the
# hired-vs-scaffold distinction is `cabinet/mcp-scope.yml`: agents
# listed under `agents:` are hired (copied to .claude/agents/), agents
# under `scaffolds:` are staged but not activated. The SCAFFOLD banner
# inside role-def .md files is now advisory-only for human readers;
# the loader does not inspect it. This keeps a single authoritative
# list instead of three drift-prone ones (per Apr 17 review).
MCP_SCOPE_FILE="$CABINET_ROOT/cabinet/mcp-scope.yml"

# Extract hired agent slugs from `agents:` section. Awk walks sections
# and emits only the direct children of `agents:` (two-space indent,
# trailing colon). Tolerates comments and the universal:/cabinet: keys.
list_hired_agents() {
  [ -f "$MCP_SCOPE_FILE" ] || return
  awk '
    /^agents:[[:space:]]*$/     { section = "agents"; next }
    /^scaffolds:[[:space:]]*$/  { section = "scaffolds"; next }
    /^[A-Za-z]/                 { section = "" }
    section == "agents" && /^  [A-Za-z][A-Za-z0-9_-]*:[[:space:]]*$/ {
      name = $0
      sub(/^  /, "", name)
      sub(/:.*$/, "", name)
      print name
    }
  ' "$MCP_SCOPE_FILE"
}

if [ -d "$PRESET_DIR/agents" ]; then
  if [ ! -f "$MCP_SCOPE_FILE" ]; then
    log "ERROR: $MCP_SCOPE_FILE missing — cannot determine hired agents. Skipping agent population."
  else
    HIRED=$(list_hired_agents)
    if [ -z "$HIRED" ]; then
      log "WARN: no agents listed in $MCP_SCOPE_FILE under 'agents:' — skipping."
    else
      copied=0
      skipped=0
      for src in "$PRESET_DIR/agents"/*.md; do
        [ -f "$src" ] || continue
        basename=$(basename "$src")
        [ "$basename" = "TEMPLATE.md" ] && continue
        slug="${basename%.md}"
        # Copy iff the slug is in the hired list from mcp-scope.yml.
        if echo "$HIRED" | grep -qx "$slug"; then
          cp "$src" "$AGENTS_DIR/$basename"
          copied=$((copied + 1))
        else
          skipped=$((skipped + 1))
        fi
      done
      log "Populated agents from preset: $copied hired (per mcp-scope.yml), $skipped staged"
    fi
  fi
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
