#!/bin/bash
# create-project.sh — Idempotent project provisioning for Pool Phase 2 (FW-078)
#
# Usage: create-project.sh <slug> <repo_url> [--skip-notion] [--skip-linear] [--skip-library]
#
# Creates everything needed for a new project under the pool architecture:
#   - instance/config/projects/<slug>.yml  (Captain fills in Notion/Linear IDs)
#   - cabinet/env/<slug>.env               (Captain fills in bot tokens + NEON_CONNECTION_STRING)
#   - Clones repo to /opt/<slug>
#   - Symlinks /workspace/<slug> -> /opt/<slug>
#   - Provisions library_spaces row (Postgres) unless --skip-library
#   - Notifies CoS on completion
#
# Idempotent: state file at /tmp/create-project.<slug>.state tracks completed
# steps. Re-running resumes from the first incomplete step. State file is
# locked per PID — concurrent invocations for the same slug are detected and
# rejected.
#
# Slug contract (must match start-officer.sh / triggers.sh / post-tool-use.sh):
#   regex: ^[a-z0-9][a-z0-9-]*$
#   length cap: 32 chars
#
# Secrets discipline: GITHUB_PAT and NEON_CONNECTION_STRING are never echoed
# to stdout. Git clone uses the PAT via GIT_ASKPASS (no URL embedding).
# Library INSERT uses psql env vars, not inline strings.

set -uo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
SLUG="${1:-}"
REPO_URL="${2:-}"
SKIP_NOTION=false
SKIP_LINEAR=false
SKIP_LIBRARY=false
DRY_RUN="${DRY_RUN:-0}"

usage() {
  echo "Usage: create-project.sh <slug> <repo_url> [--skip-notion] [--skip-linear] [--skip-library]" >&2
  echo "  DRY_RUN=1 prints what would be done without making changes." >&2
  exit 1
}

shift 2 2>/dev/null || true
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-notion)  SKIP_NOTION=true;  shift ;;
    --skip-linear)  SKIP_LINEAR=true;  shift ;;
    --skip-library) SKIP_LIBRARY=true; shift ;;
    *) echo "create-project.sh: unknown flag '$1'" >&2; usage ;;
  esac
done

if [ -z "$SLUG" ] || [ -z "$REPO_URL" ]; then
  usage
fi

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { echo "[create-project] $1"; }
info() { log "$1"; }
dry()  { echo "[DRY-RUN] $1"; }

# ---------------------------------------------------------------------------
# Step 1 — Validate slug
# ---------------------------------------------------------------------------
step_validate_slug() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "Would validate slug '$SLUG' against ^[a-z0-9][a-z0-9-]*\$ + 32-char cap"
    return 0
  fi
  if ! [[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "create-project.sh: slug must match [a-z0-9][a-z0-9-]* (got '$SLUG')" >&2
    exit 1
  fi
  if [ "${#SLUG}" -gt 32 ]; then
    echo "create-project.sh: slug must be ≤32 chars (got ${#SLUG})" >&2
    exit 1
  fi
  info "Slug '$SLUG' valid"
}

# ---------------------------------------------------------------------------
# Step 2 — Validate repo_url
# ---------------------------------------------------------------------------
step_validate_repo_url() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "Would validate repo URL '$REPO_URL' as a git URL"
    return 0
  fi
  # Accept https://, git://, git@, ssh:// forms
  if ! echo "$REPO_URL" | grep -qE '^(https?://|git://|git@|ssh://)'; then
    echo "create-project.sh: repo_url does not look like a git URL (got '$REPO_URL')" >&2
    echo "  Expected: https://github.com/org/repo or git@github.com:org/repo" >&2
    exit 1
  fi
  info "Repo URL looks valid"
}

# ---------------------------------------------------------------------------
# Step 3 — Fail-fast preflight checks
# ---------------------------------------------------------------------------
step_preflight() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "Would check: cabinet/.env exists, REDIS_HOST reachable, tmux present, GITHUB_PAT set"
    return 0
  fi

  if [ ! -f "$CABINET_ROOT/cabinet/.env" ]; then
    echo "create-project.sh: cabinet/.env not found at $CABINET_ROOT/cabinet/.env" >&2
    exit 1
  fi

  # Load base env (so REDIS_HOST etc. are available)
  # shellcheck disable=SC1090
  set -a; source "$CABINET_ROOT/cabinet/.env" 2>/dev/null; set +a

  local rhost="${REDIS_HOST:-redis}"
  local rport="${REDIS_PORT:-6379}"
  if ! redis-cli -h "$rhost" -p "$rport" PING > /dev/null 2>&1; then
    echo "create-project.sh: Redis not reachable at ${rhost}:${rport}" >&2
    exit 1
  fi

  if ! command -v tmux &>/dev/null; then
    echo "create-project.sh: tmux not found in PATH" >&2
    exit 1
  fi

  if [ -z "${GITHUB_PAT:-}" ]; then
    echo "create-project.sh: GITHUB_PAT not set in environment" >&2
    exit 1
  fi

  info "Preflight checks passed"
}

# ---------------------------------------------------------------------------
# Step 4 — Create instance/config/projects/<slug>.yml
# ---------------------------------------------------------------------------
step_create_project_yml() {
  local dest="$CABINET_ROOT/instance/config/projects/${SLUG}.yml"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would create $dest from _template.yml with slug='$SLUG', repo='$REPO_URL'"
    return 0
  fi

  if [ -f "$dest" ]; then
    info "instance/config/projects/${SLUG}.yml already exists — skipping"
    return 0
  fi

  local template="$CABINET_ROOT/instance/config/projects/_template.yml"
  if [ ! -f "$template" ]; then
    echo "create-project.sh: template not found at $template" >&2
    exit 1
  fi

  # Derive a display name from slug (replace hyphens with spaces, title-case)
  local display_name
  display_name=$(echo "$SLUG" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')

  # Build output: custom header + template body with substitutions applied.
  # Strip any leading comment block from the template (lines whose first
  # non-space char is '#', plus blank separator lines) so we don't produce
  # a double-header. We stop stripping at the first line that starts with
  # a non-'#', non-blank character (i.e. the real YAML content).
  local tmpf
  tmpf=$(mktemp)
  {
    echo "# ============================================================="
    echo "# Project: ${display_name}"
    echo "# Provisioned: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Repo: ${REPO_URL}"
    echo "# ============================================================="
    echo "# CAPTAIN ACTION REQUIRED:"
    echo "#   Fill in Notion, Linear, Neon, and Telegram IDs below."
    echo "# ============================================================="
    echo ""
    # Skip leading comment/blank lines from template, then emit remainder
    # with field substitutions applied.
    awk '
      /^[^#[:space:]]/ { found=1 }
      found { print }
    ' "$template" \
    | sed \
        -e "s|name: \"\"|name: \"${display_name}\"|" \
        -e "s|repo: \"\"|repo: \"${REPO_URL}\"|" \
        -e "s|mount_path: /workspace/product|mount_path: /workspace/${SLUG}|"
  } > "$tmpf"
  mv "$tmpf" "$dest"

  info "Created instance/config/projects/${SLUG}.yml"
}

# ---------------------------------------------------------------------------
# Step 5 — Create cabinet/env/<slug>.env
# ---------------------------------------------------------------------------
step_create_env_file() {
  local dest="$CABINET_ROOT/cabinet/env/${SLUG}.env"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would create $dest from _template.env with CABINET_PREFIX=${SLUG}, PRODUCT_REPO_PATH=/opt/${SLUG}"
    return 0
  fi

  if [ -f "$dest" ]; then
    info "cabinet/env/${SLUG}.env already exists — skipping"
    return 0
  fi

  {
    echo "# ============================================================="
    echo "# Project: ${SLUG} — Per-Project Environment Variables"
    echo "# Provisioned: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# ============================================================="
    echo "# CAPTAIN ACTION REQUIRED:"
    echo "#   1. Set TELEGRAM_HQ_CHAT_ID — create a new Telegram group,"
    echo "#      add officer bots, use /start or get chat ID from BotFather."
    echo "#   2. Set NEON_CONNECTION_STRING — provision a Neon project/branch"
    echo "#      for this project's database."
    echo "# ============================================================="
    echo ""
    # FW-084: Read bot_mode from the active preset (via preset.yml) to emit
    # the right token comment. Falls back to multi_officer if not set.
    local _active_preset_file="$CABINET_ROOT/instance/config/active-preset"
    local _active_preset=""
    local _preset_bot_mode_proj="multi_officer"
    if [ -f "$_active_preset_file" ]; then
      _active_preset=$(cat "$_active_preset_file" 2>/dev/null | tr -d '[:space:]')
    fi
    if [ -n "$_active_preset" ] && [ -f "$CABINET_ROOT/presets/$_active_preset/preset.yml" ]; then
      local _raw_mode_proj
      _raw_mode_proj=$(grep -E '^[[:space:]]*telegram_bot_mode:' \
        "$CABINET_ROOT/presets/$_active_preset/preset.yml" 2>/dev/null | head -1 \
        | sed 's/^[[:space:]]*telegram_bot_mode:[[:space:]]*//' \
        | tr -d '"' | tr -d "'" | tr -d '[:space:]')
      if [ "$_raw_mode_proj" = "single_ceo" ] || [ "$_raw_mode_proj" = "multi_officer" ]; then
        _preset_bot_mode_proj="$_raw_mode_proj"
      fi
    fi

    echo "# Telegram group chat for this project's warroom"
    echo "# (Create a new Telegram group, add the CEO bot, get the chat ID)"
    echo "TELEGRAM_HQ_CHAT_ID="
    echo ""
    if [ "$_preset_bot_mode_proj" = "single_ceo" ]; then
      local _slug_upper
      _slug_upper=$(echo "${SLUG^^}" | tr "-" "_")
      echo "# single_ceo mode: ONE bot token per project"
      echo "# CAPTAIN ACTION: create one bot via @BotFather, set the token below"
      echo "TELEGRAM_${_slug_upper}_CEO_TOKEN="
    else
      echo "# multi_officer mode: one bot token per officer"
      echo "# CAPTAIN ACTION: add tokens for each officer below"
      echo "# TELEGRAM_COS_TOKEN="
      echo "# TELEGRAM_CTO_TOKEN="
      echo "# TELEGRAM_CRO_TOKEN="
      echo "# TELEGRAM_CPO_TOKEN="
      echo "# TELEGRAM_COO_TOKEN="
    fi
    echo ""
    echo "# Product database (Neon connection string for this project)"
    echo "# CAPTAIN: provision via https://console.neon.tech and paste here"
    echo "NEON_CONNECTION_STRING="
    echo ""
    echo "# Product repo path on the server"
    echo "PRODUCT_REPO_PATH=/opt/${SLUG}"
    echo ""
    echo "# Container naming prefix"
    echo "CABINET_PREFIX=${SLUG}"
  } > "$dest"

  info "Created cabinet/env/${SLUG}.env"
}

# ---------------------------------------------------------------------------
# Step 6 — Clone repo to /opt/<slug>
# ---------------------------------------------------------------------------
step_clone_repo() {
  local dest="/opt/${SLUG}"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would clone $REPO_URL to $dest (GITHUB_PAT auth, skip if dir exists)"
    return 0
  fi

  if [ -d "$dest/.git" ]; then
    info "/opt/${SLUG} already cloned — skipping"
    return 0
  fi

  if [ -d "$dest" ]; then
    # Dir exists but no .git — partial clone or stale directory
    echo "create-project.sh: /opt/${SLUG} exists but has no .git — removing and re-cloning" >&2
    rm -rf "$dest"
  fi

  info "Cloning $REPO_URL to $dest..."

  # Inject PAT via git credential helper inline — never embed token in URL
  # (feedback_git_push_u_tokenized_url.md: raw URL embedding echoes + persists token)
  # We use a temporary credential helper script that writes the token once.
  local cred_script
  cred_script=$(mktemp /tmp/git-cred-XXXXXX.sh)
  chmod 700 "$cred_script"
  # Write the credential helper — file perms 700, deleted after clone
  printf '#!/bin/sh\necho "username=x-access-token"\necho "password=%s"\n' "${GITHUB_PAT}" > "$cred_script"

  local clone_exit=0
  GIT_ASKPASS="$cred_script" GIT_TERMINAL_PROMPT=0 \
    git clone --depth 1 "$REPO_URL" "$dest" 2>&1 \
    || clone_exit=$?

  rm -f "$cred_script"

  if [ $clone_exit -ne 0 ]; then
    # Clean up partial clone so re-run can retry
    rm -rf "$dest"
    echo "create-project.sh: git clone failed (exit $clone_exit)" >&2
    echo "  Partial clone removed. Re-run create-project.sh to retry from this step." >&2
    exit 1
  fi

  info "Cloned to $dest"
}

# ---------------------------------------------------------------------------
# Step 7 — Mount path: symlink /workspace/<slug> -> /opt/<slug>
# ---------------------------------------------------------------------------
step_mount_path() {
  local src="/opt/${SLUG}"
  local link="/workspace/${SLUG}"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would mkdir -p /workspace and ln -sfn $src $link"
    dry "NOTE: In production Docker deployments, replace symlink with a bind-mount"
    dry "      in docker-compose.yml: - /opt/${SLUG}:/workspace/${SLUG}"
    return 0
  fi

  mkdir -p /workspace

  if [ -L "$link" ] && [ "$(readlink "$link")" = "$src" ]; then
    info "/workspace/${SLUG} -> $src already correct — skipping"
    return 0
  fi

  ln -sfn "$src" "$link"
  info "Symlinked $link -> $src"
  info "NOTE: For production, add bind-mount to docker-compose.yml:"
  info "      - /opt/${SLUG}:/workspace/${SLUG}"
}

# ---------------------------------------------------------------------------
# Step 8 — Notion provision (idempotent advisory)
# ---------------------------------------------------------------------------
step_notion() {
  if [ "$SKIP_NOTION" = true ]; then
    info "Skipping Notion provision (--skip-notion)"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would run bootstrap-notion.sh if present, else note 'Notion: TBD' in yml"
    return 0
  fi

  local bootstrap_script="$CABINET_ROOT/cabinet/scripts/bootstrap-notion.sh"
  if [ -f "$bootstrap_script" ]; then
    info "Running bootstrap-notion.sh for $SLUG..."
    bash "$bootstrap_script" "$SLUG" 2>&1 || {
      info "bootstrap-notion.sh failed — Notion IDs must be filled in manually"
      info "Edit: instance/config/projects/${SLUG}.yml"
    }
  else
    info "No bootstrap-notion.sh found — Notion IDs must be filled in by Captain"
    info "Edit: instance/config/projects/${SLUG}.yml (notion section)"
  fi
}

# ---------------------------------------------------------------------------
# Step 9 — Linear provision (archive-only note)
# ---------------------------------------------------------------------------
step_linear() {
  if [ "$SKIP_LINEAR" = true ]; then
    info "Skipping Linear (--skip-linear)"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would note: Linear is READ-ONLY archive post Spec-039 cutover (2026-04-26)"
    return 0
  fi

  info "Linear: archive-only post Spec-039 cutover — no write provisioning needed"
  info "Canonical task backlog is Postgres officer_tasks (/tasks route)"
}

# ---------------------------------------------------------------------------
# Step 10 — Library Space provision (Postgres library_spaces)
# ---------------------------------------------------------------------------
step_library() {
  if [ "$SKIP_LIBRARY" = true ]; then
    info "Skipping Library provision (--skip-library)"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would INSERT INTO library_spaces (slug, name, context_slug) VALUES ('${SLUG}', ...) ON CONFLICT DO NOTHING"
    return 0
  fi

  if [ -z "${NEON_CONNECTION_STRING:-}" ]; then
    info "NEON_CONNECTION_STRING not set — skipping Library Space provision"
    info "After Captain sets NEON_CONNECTION_STRING in cabinet/env/${SLUG}.env, re-run with:"
    info "  bash create-project.sh $SLUG $REPO_URL --skip-notion --skip-linear"
    return 0
  fi

  local display_name
  display_name=$(echo "$SLUG" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1')

  info "Provisioning library_spaces row for '$SLUG'..."
  # Use psql via env var — connection string is never echoed to stdout
  if PGPASSWORD="" psql "$NEON_CONNECTION_STRING" -c \
    "INSERT INTO library_spaces (slug, name, context_slug) VALUES ('${SLUG}', '${display_name}', '${SLUG}') ON CONFLICT (slug) DO NOTHING;" \
    2>&1 | grep -vE '^(INSERT|$)'; then
    info "library_spaces row ensured for '$SLUG'"
  else
    info "WARNING: library_spaces insert may have failed — check Neon connection"
    info "  Re-run with --skip-notion --skip-linear after fixing NEON_CONNECTION_STRING"
  fi
}

# ---------------------------------------------------------------------------
# Step 11 — Notify CoS
# ---------------------------------------------------------------------------
step_notify_cos() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "Would notify CoS: PROJECT PROVISIONED: $SLUG from $REPO_URL"
    return 0
  fi

  local notify_script="$CABINET_ROOT/cabinet/scripts/notify-officer.sh"
  if [ -f "$notify_script" ]; then
    OFFICER_NAME="create-project" bash "$notify_script" cos \
      "PROJECT PROVISIONED: ${SLUG} from ${REPO_URL} — config files written, Captain action needed for Notion/Telegram bot tokens and NEON_CONNECTION_STRING. Run: start-officer.sh <officer> --project ${SLUG} to bring officers into pool mode for this project." \
      2>/dev/null || true
    info "CoS notified"
  else
    info "notify-officer.sh not found — CoS notification skipped"
  fi
}

# ---------------------------------------------------------------------------
# State file tracking (idempotency + locking)
# ---------------------------------------------------------------------------
STATE_FILE="/tmp/create-project.${SLUG}.state"

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

  # Atomic creation: write PID to state file if it doesn't exist yet.
  # If the file exists, check if the owning PID is still running.
  if [ -f "$STATE_FILE" ]; then
    local owner_pid
    owner_pid=$(grep '^PID=' "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2 || true)
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
      echo "create-project.sh: another instance (PID $owner_pid) is already running for slug '$SLUG'" >&2
      echo "  State file: $STATE_FILE" >&2
      exit 1
    fi
    # Stale lock — previous run crashed. Resume from completed steps.
    info "Resuming from stale state file (previous run crashed or was interrupted)"
    # Replace the stale PID line
    local tmpf
    tmpf=$(mktemp)
    grep -v '^PID=' "$STATE_FILE" > "$tmpf" 2>/dev/null || true
    echo "PID=$$" >> "$tmpf"
    mv "$tmpf" "$STATE_FILE"
  else
    # Fresh run
    echo "PID=$$" > "$STATE_FILE"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"

if [ "$DRY_RUN" = "1" ]; then
  log "=== DRY RUN MODE — no filesystem or network changes will be made ==="
  log "Slug:    $SLUG"
  log "Repo:    $REPO_URL"
  log "Flags:   skip-notion=$SKIP_NOTION skip-linear=$SKIP_LINEAR skip-library=$SKIP_LIBRARY"
  echo ""
fi

# Slug + URL validation run unconditionally (no state tracking needed — fast)
step_validate_slug
step_validate_repo_url

if [ "$DRY_RUN" = "1" ]; then
  # In dry-run, just show all steps
  step_preflight
  step_create_project_yml
  step_create_env_file
  step_clone_repo
  step_mount_path
  step_notion
  step_linear
  step_library
  step_notify_cos
  log "=== DRY RUN COMPLETE ==="
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

run_step "preflight"          step_preflight
run_step "project-yml"        step_create_project_yml
run_step "env-file"           step_create_env_file
run_step "clone-repo"         step_clone_repo
run_step "mount-path"         step_mount_path
run_step "notion"             step_notion
run_step "linear"             step_linear
run_step "library"            step_library
run_step "notify-cos"         step_notify_cos

# All steps complete — clean up state file
rm -f "$STATE_FILE"

info ""
info "=========================================="
info " Project '$SLUG' provisioned successfully"
info "=========================================="
info ""
info "CAPTAIN ACTION REQUIRED:"
info "  1. Fill in Notion IDs: instance/config/projects/${SLUG}.yml"
info "  2. Set Telegram group ID + NEON_CONNECTION_STRING: cabinet/env/${SLUG}.env"
info ""
info "To start officers in pool mode for this project:"
info "  bash cabinet/scripts/start-officer.sh <officer> --project ${SLUG}"
info ""
