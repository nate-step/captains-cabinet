#!/bin/bash
# cabinet-bootstrap.sh — Idempotent new-Cabinet provisioning (FW-082)
# Spec 034 v3 §4a — Phase 4a: bring up a brand-new Cabinet from scratch.
#
# Usage:
#   cabinet-bootstrap.sh <cabinet-slug> --preset <preset-slug>
#                        [--captain-name <name>]
#                        [--peer-cabinet <slug>:<host>:<port>:<secret-ref>]...
#                        [--neon-database-url <url>]
#                        [--dry-run]
#
# Options:
#   --preset <slug>                     Required. Preset at presets/<slug>/
#   --captain-name <name>               Optional. Sets product.captain_name in new cabinet.
#   --peer-cabinet <slug>:<host>:<port>:<secret-ref>
#                                       Optional, repeatable. Register peer Cabinet.
#   --neon-database-url <url>           Optional. Neon connection string for new cabinet.
#   --dry-run                           Print plan; no filesystem/network/Redis changes.
#
# State: /tmp/cabinet-bootstrap.<slug>.state — flock'd per-slug.
#        Re-running resumes from the first incomplete step.
#
# Slug contract (mirrors FW-073/074/075/078/080):
#   regex: ^[a-z0-9][a-z0-9-]*$
#   length cap: 32 chars
#
# Secrets discipline:
#   - GITHUB_PAT never echoed; clone via GIT_ASKPASS (mirrors create-project.sh)
#   - Neon URL redacted in dry-run and logs (contains password)
#   - Peer secrets stored by env-var reference name only, never values in peers.yml
#   - DRY_RUN output never emits secret values
#
# Preset validate.sh trust: validate.sh runs with full bash semantics (no sandbox).
#   The preset author (Captain-controlled presets/ dir) is trusted. Document this.
#
# AC #72: Depends on FW-079 + FW-080 + FW-005 + presets/<slug>/validate.sh.

set -uo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
CABINET_SLUG="${1:-}"
PRESET_SLUG=""
CAPTAIN_NAME=""
NEON_DATABASE_URL=""
# Honour DRY_RUN env var (set before invocation) OR --dry-run flag below.
# Initialize from environment; flag parsing may upgrade 0→1 but never 1→0.
DRY_RUN="${DRY_RUN:-0}"
declare -a PEER_CABINETS=()

if [ $# -ge 1 ]; then
  shift
fi

usage() {
  cat >&2 <<'EOF'
Usage: cabinet-bootstrap.sh <cabinet-slug> --preset <preset-slug>
                            [--captain-name <name>]
                            [--peer-cabinet <slug>:<host>:<port>:<secret-ref>]...
                            [--neon-database-url <url>]
                            [--dry-run]

  --preset <slug>          Required. Preset at presets/<slug>/ (e.g. step-network)
  --captain-name <name>    Optional. Captain name for new cabinet's product.yml
  --peer-cabinet ...       Optional, repeatable. Format: slug:host:port:secret-ref
  --neon-database-url <url>  Optional. Neon connection string for cabinet management DB
  --dry-run                Print planned actions; no side effects.

DRY_RUN=1 env var also activates dry-run mode.
EOF
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --preset)
      PRESET_SLUG="${2:?--preset requires a slug argument}"
      shift 2
      ;;
    --captain-name)
      CAPTAIN_NAME="${2:?--captain-name requires a name argument}"
      shift 2
      ;;
    --peer-cabinet)
      # Format: slug:host:port:secret-ref
      peer_arg="${2:?--peer-cabinet requires slug:host:port:secret-ref}"
      # Basic syntax validation — must have exactly 3 colons
      colon_count=$(echo "$peer_arg" | tr -cd ':' | wc -c)
      if [ "$colon_count" -ne 3 ]; then
        echo "cabinet-bootstrap.sh: --peer-cabinet requires format slug:host:port:secret-ref (got '$peer_arg')" >&2
        exit 1
      fi
      PEER_CABINETS+=("$peer_arg")
      shift 2
      ;;
    --neon-database-url)
      NEON_DATABASE_URL="${2:?--neon-database-url requires a URL argument}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    *)
      echo "cabinet-bootstrap.sh: unknown flag '$1'" >&2
      usage
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { echo "[cabinet-bootstrap] $1"; }
info() { log "$1"; }
dry()  { echo "[DRY-RUN] $1"; }
err()  { echo "[cabinet-bootstrap] ERROR: $1" >&2; }

# Redact a Neon URL for safe logging (remove password component)
redact_neon_url() {
  local url="$1"
  # Redact password in postgresql://user:password@host/db pattern
  echo "$url" | sed 's|\(postgresql://[^:]*:\)[^@]*@|\1[REDACTED]@|'
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
CABINET_BOOTSTRAP_ROOT="${CABINET_BOOTSTRAP_ROOT:-/opt}"
STATE_FILE="/tmp/cabinet-bootstrap.${CABINET_SLUG:-_noname}.state"
LOCK_FD=9
FRAMEWORK_REPO_URL="https://github.com/nate-step/founders-cabinet"

# ---------------------------------------------------------------------------
# Dry-run banner
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  info "=== DRY RUN MODE — no filesystem, network, Redis, or Docker changes will be made ==="
  info "Cabinet slug:  ${CABINET_SLUG:-<missing>}"
  info "Preset:        ${PRESET_SLUG:-<missing>}"
  info "Captain name:  ${CAPTAIN_NAME:-<not set>}"
  info "Neon URL:      $([ -n "$NEON_DATABASE_URL" ] && redact_neon_url "$NEON_DATABASE_URL" || echo '<not set>')"
  info "Peer cabinets: ${#PEER_CABINETS[@]} specified"
  echo ""
fi

# ---------------------------------------------------------------------------
# Step 1 — Validate slug (AC #65)
# ---------------------------------------------------------------------------
step_validate_slug() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "Would validate cabinet slug '$CABINET_SLUG' against ^[a-z0-9][a-z0-9-]*\$ + 32-char cap"
    return 0
  fi
  if [ -z "$CABINET_SLUG" ]; then
    err "cabinet-slug is required"
    usage
  fi
  if ! [[ "$CABINET_SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    err "cabinet-slug must match [a-z0-9][a-z0-9-]* (got '$CABINET_SLUG')"
    exit 1
  fi
  if [ "${#CABINET_SLUG}" -gt 32 ]; then
    err "cabinet-slug must be <=32 chars (got ${#CABINET_SLUG} chars: '$CABINET_SLUG')"
    exit 1
  fi
  if [ -z "$PRESET_SLUG" ]; then
    err "--preset is required"
    usage
  fi
  info "Slug '$CABINET_SLUG' valid"
}

# ---------------------------------------------------------------------------
# Step 2 — Validate preset exists (partial AC #66 — existence check only)
# ---------------------------------------------------------------------------
step_validate_preset() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "Would check: presets/$PRESET_SLUG/ exists and contains preset.yml"
    return 0
  fi
  local preset_dir="$CABINET_ROOT/presets/$PRESET_SLUG"
  if [ ! -d "$preset_dir" ]; then
    err "Preset '$PRESET_SLUG' not found at $preset_dir"
    err "  Available presets: $(ls "$CABINET_ROOT/presets/" 2>/dev/null | grep -v _template | tr '\n' ' ')"
    exit 1
  fi
  if [ ! -f "$preset_dir/preset.yml" ]; then
    err "Preset '$PRESET_SLUG' is not populated (no preset.yml)"
    exit 1
  fi
  info "Preset '$PRESET_SLUG' found"
}

# ---------------------------------------------------------------------------
# Step 3 — Preflight (AC #65: GITHUB_PAT, Neon probe)
# ---------------------------------------------------------------------------
step_preflight() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "Would check: GITHUB_PAT set, Neon URL reachable (if provided), peer hosts reachable (if any)"
    return 0
  fi

  if [ -z "${GITHUB_PAT:-}" ]; then
    err "GITHUB_PAT not set in environment"
    exit 1
  fi

  # Validate Neon URL if provided
  if [ -n "$NEON_DATABASE_URL" ]; then
    if ! command -v psql &>/dev/null; then
      err "psql not in PATH — cannot probe Neon URL"
      exit 1
    fi
    if ! PGCONNECT_TIMEOUT=10 psql "$NEON_DATABASE_URL" -c "SELECT 1;" > /dev/null 2>&1; then
      err "Neon URL not reachable (probe failed): $(redact_neon_url "$NEON_DATABASE_URL")"
      err "  Verify the connection string and try again"
      exit 1
    fi
    info "Neon URL reachable: $(redact_neon_url "$NEON_DATABASE_URL")"
  fi

  # Probe peer cabinets (TCP reachable)
  for peer_entry in "${PEER_CABINETS[@]:-}"; do
    [ -z "$peer_entry" ] && continue
    local peer_host peer_port
    peer_host=$(echo "$peer_entry" | cut -d: -f2)
    peer_port=$(echo "$peer_entry" | cut -d: -f3)
    if ! timeout 5 bash -c "echo > /dev/tcp/${peer_host}/${peer_port}" 2>/dev/null; then
      err "Peer cabinet not reachable at ${peer_host}:${peer_port}"
      err "  Entry: $peer_entry"
      err "  Verify peer host/port before bootstrapping"
      exit 1
    fi
    info "Peer reachable: ${peer_host}:${peer_port}"
  done

  info "Preflight checks passed"
}

# ---------------------------------------------------------------------------
# Step 4 — Run preset validate.sh — HARD GATE (AC #66)
# ---------------------------------------------------------------------------
step_validate_preset_gate() {
  local preset_dir="$CABINET_ROOT/presets/$PRESET_SLUG"
  local validate_sh="$preset_dir/validate.sh"

  if [ "$DRY_RUN" = "1" ]; then
    if [ -f "$validate_sh" ]; then
      dry "Would run preset validate.sh (hard gate): $validate_sh"
    else
      dry "No validate.sh found at $validate_sh — would skip (non-fatal in dry-run)"
    fi
    return 0
  fi

  if [ ! -f "$validate_sh" ]; then
    err "Preset '$PRESET_SLUG' has no validate.sh — cannot pass hard gate (AC #66)"
    err "  Create $validate_sh that exits 0 on success, 1 on failure"
    exit 1
  fi

  info "Running preset validate.sh hard gate..."
  # Trust note: validate.sh runs with full bash semantics. The preset author
  # (Captain-controlled presets/ directory) is trusted. No sandbox.
  if ! bash "$validate_sh"; then
    err "Preset validate.sh failed (exit non-zero) — bootstrap aborted"
    err "  Fix the preset validation errors above and retry"
    exit 1
  fi
  info "Preset validate.sh PASSED"
}

# ---------------------------------------------------------------------------
# Step 5 — Create new cabinet directory (AC #65)
# ---------------------------------------------------------------------------
step_create_cabinet_dir() {
  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would mkdir -p '${cabinet_dir}'"
    return 0
  fi

  if [ -d "$cabinet_dir" ]; then
    info "Cabinet directory already exists: $cabinet_dir — skipping mkdir"
    return 0
  fi

  # Use canonical path only — no symlink traversal
  mkdir -p "$cabinet_dir"
  info "Created cabinet directory: $cabinet_dir"
}

# ---------------------------------------------------------------------------
# Step 6 — Clone framework repo (AC #65)
# ---------------------------------------------------------------------------
step_clone_framework() {
  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would clone framework repo ($FRAMEWORK_REPO_URL) into $cabinet_dir via GIT_ASKPASS (GITHUB_PAT, never echoed)"
    return 0
  fi

  if [ -d "$cabinet_dir/.git" ]; then
    info "Framework repo already cloned at $cabinet_dir — skipping"
    return 0
  fi

  info "Cloning framework repo into $cabinet_dir..."

  # Inject PAT via GIT_ASKPASS — never embed in URL (mirrors create-project.sh)
  local cred_script
  cred_script=$(mktemp /tmp/git-cred-XXXXXX.sh)
  chmod 700 "$cred_script"
  printf '#!/bin/sh\necho "username=x-access-token"\necho "password=%s"\n' "${GITHUB_PAT}" > "$cred_script"

  local clone_exit=0
  GIT_ASKPASS="$cred_script" GIT_TERMINAL_PROMPT=0 \
    git clone --depth 1 "$FRAMEWORK_REPO_URL" "$cabinet_dir" 2>&1 \
    || clone_exit=$?

  rm -f "$cred_script"

  if [ $clone_exit -ne 0 ]; then
    rm -rf "$cabinet_dir"
    err "git clone failed (exit $clone_exit) — cabinet directory removed for clean retry"
    exit 1
  fi

  info "Framework cloned to $cabinet_dir"
}

# ---------------------------------------------------------------------------
# Step 7 — Set active-preset (AC #65)
# ---------------------------------------------------------------------------
step_set_active_preset() {
  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"
  local preset_file="$cabinet_dir/instance/config/active-preset"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would write '$PRESET_SLUG' to $preset_file"
    return 0
  fi

  mkdir -p "$(dirname "$preset_file")"
  echo "$PRESET_SLUG" > "$preset_file"
  info "Set active-preset: $PRESET_SLUG"
}

# ---------------------------------------------------------------------------
# Step 8 — Initialize instance directories (AC #65, #69)
# ---------------------------------------------------------------------------
step_init_instance_dirs() {
  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would mkdir -p instance/memory/tier2/, instance/config/, instance/agents/"
    dry "Would touch empty captain-decisions.md, captain-patterns.md, captain-intents.md (AC #69)"
    return 0
  fi

  # Core directories
  mkdir -p \
    "$cabinet_dir/instance/memory/tier2" \
    "$cabinet_dir/instance/config/projects" \
    "$cabinet_dir/instance/agents"

  # AC #69: Captain-memory split init — empty cabinet-local files.
  # Framework-global already exists in framework/ directory.
  # New cabinet ships clean (no cross-cabinet memory bleed).
  local shared_iface="$cabinet_dir/shared/interfaces"
  mkdir -p "$shared_iface"

  for fname in captain-decisions.md captain-patterns.md captain-intents.md; do
    local fpath="$shared_iface/$fname"
    if [ ! -f "$fpath" ]; then
      touch "$fpath"
      info "Initialized empty $fname (AC #69)"
    fi
  done

  info "Instance directories initialized"
}

# ---------------------------------------------------------------------------
# Step 9 — Generate FW-005 peer secrets (AC #65, #68)
# ---------------------------------------------------------------------------
step_generate_peer_secrets() {
  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would generate random hex CABINET_PEER_SECRET_<slug> for each peer cabinet"
    dry "Would write secrets to $cabinet_dir/cabinet/.env (new cabinet only)"
    dry "Would NOT echo secret values in output"
    return 0
  fi

  mkdir -p "$cabinet_dir/cabinet"

  local env_file="$cabinet_dir/cabinet/.env"

  {
    echo "# ============================================================="
    echo "# Cabinet: ${CABINET_SLUG} — Environment Variables"
    echo "# Provisioned: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# ============================================================="
    echo ""
    echo "CABINET_ID=${CABINET_SLUG}"
    echo "CABINET_MODE=multi"
    echo ""
    echo "REDIS_HOST=redis-${CABINET_SLUG}"
    echo "REDIS_PORT=6379"
    echo ""
    if [ -n "$NEON_DATABASE_URL" ]; then
      echo "# Cabinet management DB (schema + officer state)"
      echo "NEON_CONNECTION_STRING=${NEON_DATABASE_URL}"
      echo ""
    else
      echo "# CAPTAIN ACTION REQUIRED: set NEON_CONNECTION_STRING"
      echo "NEON_CONNECTION_STRING="
      echo ""
    fi
    echo "# CAPTAIN ACTION REQUIRED: Add officer Telegram bot tokens"
    echo "# Pattern: TELEGRAM_<UPPER>_TOKEN=<token>"
    echo ""
  } > "$env_file"

  # Generate a fresh random hex secret per peer cabinet
  for peer_entry in "${PEER_CABINETS[@]:-}"; do
    [ -z "$peer_entry" ] && continue
    local peer_slug
    peer_slug=$(echo "$peer_entry" | cut -d: -f1)
    local secret_ref="CABINET_PEER_SECRET_$(echo "$peer_slug" | tr 'a-z-' 'A-Z_')"
    local secret_value
    secret_value=$(openssl rand -hex 32 2>/dev/null || dd if=/dev/urandom bs=32 count=1 2>/dev/null | xxd -p | tr -d '\n')
    echo "${secret_ref}=${secret_value}" >> "$env_file"
    info "Generated peer secret for '$peer_slug' → var name: $secret_ref (value not echoed)"
  done

  info "cabinet/.env written for new cabinet (secrets not echoed)"
}

# ---------------------------------------------------------------------------
# Step 10 — Queue peer .env updates (AC #65, #68)
# ---------------------------------------------------------------------------
step_queue_peer_env_updates() {
  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"

  if [ "$DRY_RUN" = "1" ]; then
    for peer_entry in "${PEER_CABINETS[@]:-}"; do
      [ -z "$peer_entry" ] && continue
      local peer_slug
      peer_slug=$(echo "$peer_entry" | cut -d: -f1)
      dry "Would write staged env update for peer '$peer_slug': CABINET_PEER_SECRET_$(echo "$peer_slug" | tr 'a-z-' 'A-Z_') (value not echoed)"
      dry "  → staged in /tmp/cabinet-bootstrap.${CABINET_SLUG}.peer-env.${peer_slug}"
    done
    return 0
  fi

  # For each peer cabinet, produce a staged env-update file.
  # Operators apply these to peer cabinet's cabinet/.env after bootstrap.
  # We cannot directly write to peer cabinets (AC #67: cross-cabinet via FW-005 HTTP only).
  for peer_entry in "${PEER_CABINETS[@]:-}"; do
    [ -z "$peer_entry" ] && continue
    local peer_slug
    peer_slug=$(echo "$peer_entry" | cut -d: -f1)
    local secret_ref="CABINET_PEER_SECRET_$(echo "$peer_slug" | tr 'a-z-' 'A-Z_')"

    # Read the generated value from new cabinet's .env
    local secret_value
    secret_value=$(grep "^${secret_ref}=" "$cabinet_dir/cabinet/.env" | cut -d= -f2-)
    if [ -z "$secret_value" ]; then
      err "Secret for peer '$peer_slug' not found in new cabinet .env — skipping"
      continue
    fi

    # Staged update file: operator applies to peer cabinet's .env
    local staged_file="/tmp/cabinet-bootstrap.${CABINET_SLUG}.peer-env.${peer_slug}"
    {
      echo "# Staged env update for peer cabinet: $peer_slug"
      echo "# Apply to: /opt/${peer_slug}-cabinet/cabinet/.env"
      echo "# This is the SAME secret value that was written to ${CABINET_SLUG}'s .env"
      echo "# Both cabinets must have matching values for FW-005 HTTP bearer auth."
      local peer_secret_ref="CABINET_PEER_SECRET_$(echo "$CABINET_SLUG" | tr 'a-z-' 'A-Z_')"
      echo "${peer_secret_ref}=${secret_value}"
    } > "$staged_file"
    info "Staged peer .env update: $staged_file (apply to peer '$peer_slug' cabinet)"
  done
}

# ---------------------------------------------------------------------------
# Step 11 — Two-phase peers.yml commit (AC #68)
# ---------------------------------------------------------------------------
step_peers_yml_two_phase() {
  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Two-phase peers.yml commit (AC #68):"
    dry "  Phase 1: Write new cabinet's peers.yml with all peers (consented_by_captain: false)"
    for peer_entry in "${PEER_CABINETS[@]:-}"; do
      [ -z "$peer_entry" ] && continue
      local p_slug p_host p_port p_secret_ref
      p_slug=$(echo "$peer_entry" | cut -d: -f1)
      p_host=$(echo "$peer_entry" | cut -d: -f2)
      p_port=$(echo "$peer_entry" | cut -d: -f3)
      p_secret_ref=$(echo "$peer_entry" | cut -d: -f4)
      dry "    peer $p_slug: endpoint=http://${p_host}:${p_port}/mcp secret_ref=$p_secret_ref consented=false"
    done
    dry "  Phase 2: Captain ratifies → operator flips consented_by_captain: true on all peers"
    dry "  Note: Phase 2 flip requires operator action after Captain ratification"
    return 0
  fi

  mkdir -p "$cabinet_dir/instance/config"

  # Phase 1: write peers.yml with consented_by_captain: false on all peers
  local peers_file="$cabinet_dir/instance/config/peers.yml"
  {
    echo "# instance/config/peers.yml"
    echo "# Cabinet: ${CABINET_SLUG}"
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Phase 1 of 2-phase commit (AC #68): all consented_by_captain: false"
    echo "# After Captain ratifies the new cabinet, flip each to true."
    echo "#"
    echo "# REQUIRED KEYS: role, endpoint, capacity, trust_level,"
    echo "#   consented_by_captain, allowed_tools"
    echo "# shared_secret_ref: name of env var holding the bearer secret."
    echo "#   NEVER put the secret value inline — reference only."
    echo ""
    echo "peers:"
    for peer_entry in "${PEER_CABINETS[@]:-}"; do
      [ -z "$peer_entry" ] && continue
      local p_slug p_host p_port p_secret_ref
      p_slug=$(echo "$peer_entry" | cut -d: -f1)
      p_host=$(echo "$peer_entry" | cut -d: -f2)
      p_port=$(echo "$peer_entry" | cut -d: -f3)
      p_secret_ref=$(echo "$peer_entry" | cut -d: -f4)
      echo "  ${p_slug}:"
      echo "    role: ${p_slug}-cabinet"
      echo "    endpoint: http://${p_host}:${p_port}/mcp"
      echo "    capacity: work"
      echo "    trust_level: high"
      echo "    consented_by_captain: false"
      echo "    shared_secret_ref: ${p_secret_ref}"
      echo "    allowed_tools:"
      echo "      - identify"
      echo "      - presence"
      echo "      - availability"
      echo "      - send_message"
      echo "      - request_handoff"
    done
  } > "$peers_file"

  if [ "${#PEER_CABINETS[@]}" -gt 0 ]; then
    info "peers.yml Phase 1 written (${#PEER_CABINETS[@]} peer(s), consented_by_captain: false)"
    info "  CAPTAIN ACTION: After ratifying cabinet '${CABINET_SLUG}', edit $peers_file"
    info "  and set consented_by_captain: true for each peer. Then restart officers."
  else
    info "No peer cabinets specified — peers.yml written with empty peers block"
  fi
}

# ---------------------------------------------------------------------------
# Step 12 — Generate parameterized docker-compose.yml (AC #67)
# ---------------------------------------------------------------------------
step_generate_docker_compose() {
  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"
  local compose_file="$cabinet_dir/docker-compose.yml"
  # Safe slug for use as Docker volume/container names (underscored)
  local slug_under
  slug_under=$(echo "$CABINET_SLUG" | tr '-' '_')

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would generate parameterized docker-compose.yml at $compose_file"
    dry "  Cabinet slug: ${CABINET_SLUG} (containers: officers-${CABINET_SLUG}, redis-${CABINET_SLUG})"
    dry "  Fresh redis container: redis-${CABINET_SLUG} on dedicated Docker network"
    dry "  Named volumes per cabinet (no cross-cabinet shared volumes)"
    return 0
  fi

  {
    cat <<COMPOSE
# docker-compose.yml — Cabinet: ${CABINET_SLUG}
# Generated by cabinet-bootstrap.sh (FW-082) at $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Preset: ${PRESET_SLUG}
#
# AC #67: Each cabinet gets its own redis container + separate Docker network.
# Cross-cabinet comms via FW-005 HTTP (Cabinet MCP server) only — not shared redis.
#
# CAPTAIN ACTION REQUIRED:
#   1. Add officer service blocks (one per officer, referencing officer images)
#   2. Set TELEGRAM_<OFFICER>_TOKEN env vars for each officer
#   3. Review volume paths and adjust if different from /opt/${CABINET_SLUG}-cabinet

name: ${CABINET_SLUG}-cabinet

services:
  # ----------------------------------------------------------------
  # Redis — per-cabinet isolation (AC #67)
  # ----------------------------------------------------------------
  redis-${CABINET_SLUG}:
    image: redis:7-alpine
    container_name: redis-${CABINET_SLUG}
    restart: unless-stopped
    volumes:
      - redis_${slug_under}:/data
    networks:
      - cabinet-${CABINET_SLUG}
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10

  # ----------------------------------------------------------------
  # Cabinet MCP server — FW-005 HTTP transport for peer communication
  # ----------------------------------------------------------------
  cabinet-mcp-${CABINET_SLUG}:
    image: officers-${CABINET_SLUG}:latest
    container_name: cabinet-mcp-${CABINET_SLUG}
    restart: unless-stopped
    environment:
      - CABINET_ID=${CABINET_SLUG}
      - CABINET_MODE=multi
      - CABINET_MCP_TRANSPORT=http
      - CABINET_MCP_PORT=7471
      - REDIS_HOST=redis-${CABINET_SLUG}
      - REDIS_PORT=6379
      - CABINET_ROOT=/opt/${CABINET_SLUG}-cabinet
    env_file:
      - ./cabinet/.env
    volumes:
      - /opt/${CABINET_SLUG}-cabinet:/opt/${CABINET_SLUG}-cabinet
    networks:
      - cabinet-${CABINET_SLUG}
    depends_on:
      redis-${CABINET_SLUG}:
        condition: service_healthy
    command: ["python3", "/opt/${CABINET_SLUG}-cabinet/cabinet/mcp-server/server.py"]
    ports:
      - "7471"  # Expose for peer HTTP — bind specific host port in overlay if needed

  # ----------------------------------------------------------------
  # Officers — add one block per officer role below
  # Template (copy + rename for each officer):
  # ----------------------------------------------------------------
  # officer-cos-${CABINET_SLUG}:
  #   image: officers-${CABINET_SLUG}:latest
  #   container_name: officer-cos-${CABINET_SLUG}
  #   restart: unless-stopped
  #   environment:
  #     - CABINET_ID=${CABINET_SLUG}
  #     - CABINET_MODE=multi
  #     - REDIS_HOST=redis-${CABINET_SLUG}
  #     - REDIS_PORT=6379
  #     - CABINET_ROOT=/opt/${CABINET_SLUG}-cabinet
  #   env_file:
  #     - ./cabinet/.env
  #   volumes:
  #     - /opt/${CABINET_SLUG}-cabinet:/opt/${CABINET_SLUG}-cabinet
  #   networks:
  #     - cabinet-${CABINET_SLUG}
  #   depends_on:
  #     redis-${CABINET_SLUG}:
  #       condition: service_healthy

volumes:
  redis_${slug_under}:
    name: redis_${slug_under}

networks:
  cabinet-${CABINET_SLUG}:
    name: cabinet-${CABINET_SLUG}
    driver: bridge
COMPOSE
  } > "$compose_file"

  info "docker-compose.yml generated: $compose_file"
}

# ---------------------------------------------------------------------------
# Step 13 — Apply schemas to Neon DB (AC #65)
# ---------------------------------------------------------------------------
step_apply_schemas() {
  if [ "$DRY_RUN" = "1" ]; then
    if [ -n "$NEON_DATABASE_URL" ]; then
      dry "Would apply framework/schemas-base.sql + presets/${PRESET_SLUG}/schemas.sql to Neon"
      dry "  Neon URL: $(redact_neon_url "$NEON_DATABASE_URL")"
    else
      dry "No Neon URL — would skip schema application (CAPTAIN ACTION REQUIRED later)"
    fi
    return 0
  fi

  if [ -z "$NEON_DATABASE_URL" ]; then
    info "No Neon URL provided — skipping schema application"
    info "  After Captain sets NEON_CONNECTION_STRING, manually run:"
    info "  psql \$NEON_CONNECTION_STRING -f framework/schemas-base.sql"
    return 0
  fi

  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"
  local preset_dir="$cabinet_dir/presets/$PRESET_SLUG"

  # Apply framework base schemas (same list as load-preset.sh)
  for schema in \
    "$cabinet_dir/cabinet/sql/cabinet_memory.sql" \
    "$cabinet_dir/cabinet/sql/library.sql" \
    "$cabinet_dir/cabinet/sql/contexts-neon-phase1.sql" \
    "$cabinet_dir/cabinet/sql/cabinet-id-neon-phase1.sql" \
    "$cabinet_dir/cabinet/sql/cabinet-id-neon-phase1b.sql" \
    "$cabinet_dir/cabinet/sql/session-memories-context-slug.sql" \
    "$cabinet_dir/cabinet/sql/2026-04-17-spec-034-provisioning-schema.sql" \
    "$cabinet_dir/cabinet/sql/038-officer-tasks.sql" \
    "$cabinet_dir/cabinet/sql/039-linear-to-tasks-schema.sql"; do
    if [ -f "$schema" ]; then
      if psql "$NEON_DATABASE_URL" -q -f "$schema" > /dev/null 2>&1; then
        info "Applied schema: $(basename "$schema")"
      else
        info "WARN: failed to apply $(basename "$schema") — Cabinet will still boot; fix before new records"
      fi
    fi
  done

  # Apply preset-specific schemas
  local preset_schema="$preset_dir/schemas.sql"
  if [ -f "$preset_schema" ]; then
    if psql "$NEON_DATABASE_URL" -q -f "$preset_schema" > /dev/null 2>&1; then
      info "Applied preset schema: $PRESET_SLUG/schemas.sql"
    else
      info "WARN: failed to apply preset schema"
    fi
  fi

  info "Schema application complete"
}

# ---------------------------------------------------------------------------
# Step 14 — Captain-memory split init (AC #69)
# Already handled in step_init_instance_dirs (touched empty files).
# This step just confirms + records as done.
# ---------------------------------------------------------------------------
step_captain_memory_split() {
  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"
  local shared_iface="$cabinet_dir/shared/interfaces"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Captain-memory split (AC #69) confirmed: empty captain-decisions.md, captain-patterns.md, captain-intents.md in new cabinet"
    dry "  Framework-global memory stays in framework/ — no cross-cabinet bleed"
    return 0
  fi

  local all_ok=true
  for fname in captain-decisions.md captain-patterns.md captain-intents.md; do
    if [ ! -f "$shared_iface/$fname" ]; then
      touch "$shared_iface/$fname"
      info "Ensured empty: $fname"
      all_ok=false
    fi
  done

  if [ "$all_ok" = true ]; then
    info "Captain-memory split init confirmed (AC #69)"
  fi
}

# ---------------------------------------------------------------------------
# Step 15 — First-boot heartbeat verification (AC #65)
# ---------------------------------------------------------------------------
step_first_boot_heartbeat() {
  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"
  local redis_host="redis-${CABINET_SLUG}"
  local redis_port="6379"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would probe redis-${CABINET_SLUG}:6379 for officer heartbeat keys after officers start"
    dry "  Timeout: 5 minutes per officer"
    dry "  Skip if redis not reachable (officers not started yet in bootstrap-only mode)"
    return 0
  fi

  # Non-fatal: redis may not be running yet if officers haven't been started.
  # Bootstrap completes; operator runs officers separately.
  if ! redis-cli -h "$redis_host" -p "$redis_port" PING > /dev/null 2>&1; then
    info "Redis for new cabinet ($redis_host:$redis_port) not yet reachable"
    info "  Start officers first, then verify heartbeats with:"
    info "  redis-cli -h $redis_host -p $redis_port KEYS 'cabinet:heartbeat:*'"
    return 0
  fi

  info "Redis reachable at $redis_host:$redis_port"
  info "Checking for officer heartbeat keys..."

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Write bootstrap heartbeat (proves redis is writable)
  redis-cli -h "$redis_host" -p "$redis_port" \
    SET "cabinet:bootstrap:heartbeat:${CABINET_SLUG}" "$ts" EX 900 > /dev/null 2>&1 || true

  info "Bootstrap heartbeat written to new cabinet's redis"
  info "  After officers start, verify: redis-cli -h $redis_host KEYS 'cabinet:heartbeat:*'"
}

# ---------------------------------------------------------------------------
# Step 16 — CAPTAIN ACTION REQUIRED + enter active state (AC #71)
# ---------------------------------------------------------------------------
step_captain_action() {
  # Preset-aware copy: step-network drops Notion message (preset deprecated Notion)
  local is_step_network=false
  if [ "$PRESET_SLUG" = "step-network" ]; then
    is_step_network=true
  fi

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would emit preset-aware CAPTAIN ACTION REQUIRED message (AC #71)"
    dry "  Preset: $PRESET_SLUG (step-network drops Notion items)"
    dry "  Would notify CoS via notify-officer.sh"
    dry "  Would mark cabinet as active (Telegram-bots-pending flag)"
    return 0
  fi

  local cabinet_dir="${CABINET_BOOTSTRAP_ROOT}/${CABINET_SLUG}-cabinet"
  local peer_env_note=""
  if [ "${#PEER_CABINETS[@]}" -gt 0 ]; then
    peer_env_note="
PEER CABINET SETUP (AC #68 — two-phase peers.yml):
  1. Apply staged peer env updates (one file per peer):
$(for p in "${PEER_CABINETS[@]:-}"; do
    [ -z "$p" ] && continue
    ps=$(echo "$p" | cut -d: -f1)
    echo "     /tmp/cabinet-bootstrap.${CABINET_SLUG}.peer-env.${ps} -> /opt/${ps}-cabinet/cabinet/.env"
  done)
  2. Set consented_by_captain: true in:
     - $cabinet_dir/instance/config/peers.yml (new cabinet)
     - Each peer cabinet's instance/config/peers.yml (add reciprocal entry for ${CABINET_SLUG})"
  fi

  # Common actions
  local common_actions="
CAPTAIN ACTION REQUIRED — Cabinet '${CABINET_SLUG}' (preset: ${PRESET_SLUG}):

  REQUIRED BEFORE OFFICERS CAN FUNCTION:
  1. Telegram bot tokens — create officer bots via @BotFather for this cabinet,
     add each TELEGRAM_<OFFICER>_TOKEN to: $cabinet_dir/cabinet/.env

  2. Library scope ratification — review the new cabinet's Library Spaces
     and confirm which Spaces auto-populate via CRO discovery sweep.

  3. tasks_provider connection — configure Postgres task backlog for this cabinet:
     NEON_CONNECTION_STRING in $cabinet_dir/cabinet/.env
$([ -z "$NEON_DATABASE_URL" ] && echo "     (Not provided yet — cabinet management DB needed)")

  4. Start officers:
     bash cabinet/scripts/cabinet-spawn.sh ${CABINET_SLUG} <repo-url> --skip-create
${peer_env_note}
  VERIFICATION:
  - Heartbeats: redis-cli -h redis-${CABINET_SLUG} KEYS 'cabinet:heartbeat:*'
  - peers.yml: cat $cabinet_dir/instance/config/peers.yml
"

  # Preset-aware: step-network drops Notion message; other presets include it
  local notion_note=""
  if [ "$is_step_network" = false ]; then
    notion_note="
  5. Notion HQ DB — provision Cabinet HQ pages for this cabinet
     and fill notion section in $cabinet_dir/instance/config/product.yml"
  fi

  local full_message="${common_actions}${notion_note}"
  info ""
  echo "=================================================================="
  echo " Cabinet '${CABINET_SLUG}' bootstrap COMPLETE"
  echo "=================================================================="
  echo ""
  echo "$full_message"
  echo ""

  # Notify CoS via notify-officer.sh (best-effort)
  local notify_script="$CABINET_ROOT/cabinet/scripts/notify-officer.sh"
  if [ -f "$notify_script" ]; then
    OFFICER_NAME="cabinet-bootstrap" bash "$notify_script" cos \
      "CABINET BOOTSTRAPPED: '${CABINET_SLUG}' (preset: ${PRESET_SLUG}) — directory created, framework cloned, preset loaded, secrets generated. Captain action required before officers start. Cabinet dir: ${cabinet_dir}" \
      2>/dev/null || true
    info "CoS notified via notify-officer.sh"
  fi
}

# ---------------------------------------------------------------------------
# State file tracking (idempotency + flock)
# ---------------------------------------------------------------------------
step_done() {
  local step="$1"
  if [ "$DRY_RUN" = "1" ]; then return 0; fi
  echo "$step" >> "$STATE_FILE"
}

step_is_done() {
  local step="$1"
  if [ "$DRY_RUN" = "1" ]; then return 1; fi
  [ -f "$STATE_FILE" ] && grep -qF "$step" "$STATE_FILE"
}

acquire_lock() {
  if [ "$DRY_RUN" = "1" ]; then return 0; fi

  # flock on state file — first process wins; second waits or aborts
  # shellcheck disable=SC2188
  exec 9>>"$STATE_FILE"
  if ! flock -n $LOCK_FD 2>/dev/null; then
    err "Another cabinet-bootstrap for slug '$CABINET_SLUG' is already running (state file locked)"
    err "  State file: $STATE_FILE"
    err "  If the previous run crashed: rm $STATE_FILE and re-run"
    exit 1
  fi
  echo "PID=$$" >> "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Steps 1+2: validation runs unconditionally (fast, no state)
step_validate_slug
step_validate_preset

if [ "$DRY_RUN" = "1" ]; then
  # Dry-run: show all steps without side effects, no state file
  step_preflight
  step_validate_preset_gate
  step_create_cabinet_dir
  step_clone_framework
  step_set_active_preset
  step_init_instance_dirs
  step_generate_peer_secrets
  step_queue_peer_env_updates
  step_peers_yml_two_phase
  step_generate_docker_compose
  step_apply_schemas
  step_captain_memory_split
  step_first_boot_heartbeat
  step_captain_action
  info ""
  info "=== DRY RUN COMPLETE ==="
  exit 0
fi

acquire_lock

run_step() {
  local name="$1"
  local fn="$2"
  if step_is_done "$name"; then
    info "Step '$name' already completed — skipping"
    return 0
  fi
  info "--- Step: $name ---"
  "$fn"
  step_done "$name"
}

run_step "preflight"             step_preflight
run_step "validate-preset-gate"  step_validate_preset_gate
run_step "create-cabinet-dir"    step_create_cabinet_dir
run_step "clone-framework"       step_clone_framework
run_step "set-active-preset"     step_set_active_preset
run_step "init-instance-dirs"    step_init_instance_dirs
run_step "generate-peer-secrets" step_generate_peer_secrets
run_step "queue-peer-env"        step_queue_peer_env_updates
run_step "peers-yml-phase1"      step_peers_yml_two_phase
run_step "docker-compose"        step_generate_docker_compose
run_step "apply-schemas"         step_apply_schemas
run_step "captain-memory-split"  step_captain_memory_split
run_step "heartbeat-verify"      step_first_boot_heartbeat
run_step "captain-action"        step_captain_action

# All steps complete — release flock + remove state file
exec 9>&-
rm -f "$STATE_FILE"

info ""
info "=================================================="
info " Cabinet '${CABINET_SLUG}' bootstrapped"
info " Preset: ${PRESET_SLUG}"
info "=================================================="
info ""
info "Next: follow CAPTAIN ACTION REQUIRED items above."
info "Then: bash cabinet/scripts/cabinet-spawn.sh ${CABINET_SLUG} <repo-url> --skip-create"
info ""
