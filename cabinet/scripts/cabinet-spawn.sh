#!/bin/bash
# cabinet-spawn.sh — Idempotent single-command bring-up of a new Cabinet (FW-080)
# Pool Phase 2: starts all officers in pool mode for a given project slug.
#
# Usage:
#   cabinet-spawn.sh <slug> <repo_url> [--skip-create] [--officers <comma-list>]
#
# Options:
#   --skip-create          Skip create-project.sh (project already provisioned)
#   --officers <list>      Comma-separated officer slugs (default: from platform.yml
#                          fulltime section, or cos,cto,cpo,coo,cro if absent)
#
# State: /tmp/cabinet-spawn.<slug>.state — tracks completed steps for idempotency.
#        Re-running resumes from the first incomplete step. State file is
#        flock'd so concurrent invocations for the same slug are serialised.
#
# Slug contract (mirrors FW-073/074/075 guards):
#   regex: ^[a-z0-9][a-z0-9-]*$
#   length cap: 32 chars
#
# Secrets discipline:
#   - GITHUB_PAT is never echoed to stdout or embedded in any log line
#   - Redis keys never receive raw env var values that could be secrets
#
# DRY_RUN=1: print planned actions, no side effects (tmux, Redis, filesystem).

set -uo pipefail

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
SLUG="${1:-}"
REPO_URL="${2:-}"
SKIP_CREATE=false
OFFICER_OVERRIDE=""
DRY_RUN="${DRY_RUN:-0}"

usage() {
  echo "Usage: cabinet-spawn.sh <slug> <repo_url> [--skip-create] [--officers <comma-list>]" >&2
  echo "  DRY_RUN=1 prints planned actions without side effects." >&2
  exit 1
}

if [ -z "$SLUG" ] && [ -z "$REPO_URL" ]; then
  usage
fi

# Accept 0, 1, or 2 positional args before flags
shift 2 2>/dev/null || { shift 1 2>/dev/null || true; }

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-create) SKIP_CREATE=true; shift ;;
    --officers)
      OFFICER_OVERRIDE="${2:?--officers requires a comma-separated list}"
      shift 2
      ;;
    *) echo "cabinet-spawn.sh: unknown flag '$1'" >&2; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log()  { echo "[cabinet-spawn] $1"; }
info() { log "$1"; }
dry()  { echo "[DRY-RUN] $1"; }
err()  { echo "[cabinet-spawn] ERROR: $1" >&2; }

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
STATE_FILE="/tmp/cabinet-spawn.${SLUG}.state"
LOCK_FD=9
DEFAULT_OFFICERS="cos,cto,cpo,coo,cro"

# ---------------------------------------------------------------------------
# Slug validation (step 1)
# ---------------------------------------------------------------------------
step_validate_slug() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "Would validate slug '$SLUG' against ^[a-z0-9][a-z0-9-]*\$ + 32-char cap"
    return 0
  fi
  if [ -z "$SLUG" ]; then
    err "slug is required"
    usage
  fi
  if ! [[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    err "slug must match [a-z0-9][a-z0-9-]* (got '$SLUG')"
    exit 1
  fi
  if [ "${#SLUG}" -gt 32 ]; then
    err "slug must be <=32 chars (got ${#SLUG} chars: '$SLUG')"
    exit 1
  fi
  info "Slug '$SLUG' valid"
}

# ---------------------------------------------------------------------------
# Repo URL validation (step 2)
# ---------------------------------------------------------------------------
step_validate_repo_url() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "Would validate repo URL '$REPO_URL' as a git URL"
    return 0
  fi
  if [ -z "$REPO_URL" ]; then
    err "repo_url is required"
    usage
  fi
  if ! echo "$REPO_URL" | grep -qE '^(https?://|git://|git@|ssh://)'; then
    err "repo_url does not look like a git URL (got '$REPO_URL')"
    err "  Expected: https://github.com/org/repo or git@github.com:org/repo"
    exit 1
  fi
  info "Repo URL looks valid"
}

# ---------------------------------------------------------------------------
# Preflight checks (step 3)
# ---------------------------------------------------------------------------
step_preflight() {
  # FW-080 hotfix: when --skip-create is set, the env-file existence check
  # is independent of infra (tmux/Redis/GITHUB_PAT) — fail fast here so
  # missing-config diagnostics don't get masked by infra-not-present errors
  # in CI runners (which lack tmux + GITHUB_PAT). Same check repeats inside
  # step_provision_project for callers that hit it without --skip-create.
  if [ "$SKIP_CREATE" = true ] && [ "$DRY_RUN" != "1" ]; then
    if [ ! -f "$CABINET_ROOT/cabinet/env/${SLUG}.env" ]; then
      err "--skip-create specified but cabinet/env/${SLUG}.env does not exist"
      err "  Run without --skip-create to provision first"
      exit 1
    fi
  fi

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would check: cabinet/.env exists, REDIS_HOST reachable, tmux present, GITHUB_PAT set"
    return 0
  fi

  if [ ! -f "$CABINET_ROOT/cabinet/.env" ]; then
    err "cabinet/.env not found at $CABINET_ROOT/cabinet/.env"
    exit 1
  fi

  # Load base env (so REDIS_HOST etc. are available for subsequent checks)
  # shellcheck disable=SC1090
  set -a; source "$CABINET_ROOT/cabinet/.env" 2>/dev/null; set +a

  local rhost="${REDIS_HOST:-redis}"
  local rport="${REDIS_PORT:-6379}"
  if ! redis-cli -h "$rhost" -p "$rport" PING > /dev/null 2>&1; then
    err "Redis not reachable at ${rhost}:${rport}"
    exit 1
  fi

  if ! command -v tmux &>/dev/null; then
    err "tmux not found in PATH"
    exit 1
  fi

  # Verify tmux server is running (not just the binary)
  if ! tmux list-sessions &>/dev/null; then
    err "tmux server not running — start with: tmux new-session -d -s cabinet"
    exit 1
  fi

  if [ -z "${GITHUB_PAT:-}" ]; then
    err "GITHUB_PAT not set in environment"
    exit 1
  fi

  info "Preflight checks passed"
}

# ---------------------------------------------------------------------------
# Provision project via create-project.sh (step 4)
# ---------------------------------------------------------------------------
step_provision_project() {
  if [ "$SKIP_CREATE" = true ]; then
    if [ "$DRY_RUN" = "1" ]; then
      dry "--skip-create: verifying cabinet/env/${SLUG}.env already exists"
      return 0
    fi
    # Validate that the project is actually provisioned
    if [ ! -f "$CABINET_ROOT/cabinet/env/${SLUG}.env" ]; then
      err "--skip-create specified but cabinet/env/${SLUG}.env does not exist"
      err "  Run without --skip-create to provision first"
      exit 1
    fi
    info "--skip-create: project already provisioned (cabinet/env/${SLUG}.env found)"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would invoke: bash cabinet/scripts/create-project.sh $SLUG $REPO_URL"
    return 0
  fi

  local create_script="$CABINET_ROOT/cabinet/scripts/create-project.sh"
  if [ ! -f "$create_script" ]; then
    err "create-project.sh not found at $create_script (FW-078 not shipped?)"
    exit 1
  fi

  info "Provisioning project '$SLUG' via create-project.sh..."
  if ! bash "$create_script" "$SLUG" "$REPO_URL"; then
    err "create-project.sh failed — state preserved for re-run"
    err "  Re-run cabinet-spawn.sh with same args to resume from last completed step"
    exit 1
  fi
  info "Project '$SLUG' provisioned"
}

# ---------------------------------------------------------------------------
# Enumerate officers (step 5 — logic, not a stateful step)
# ---------------------------------------------------------------------------
enumerate_officers() {
  if [ -n "$OFFICER_OVERRIDE" ]; then
    # Replace commas with spaces for iteration
    echo "$OFFICER_OVERRIDE" | tr ',' ' '
    return
  fi

  # Parse fulltime officers from platform.yml officers: section
  # Format:  officers:
  #            cos: { type: fulltime }
  #            cto: { type: fulltime }
  #            cro: { type: consultant, schedule: "0 */4 * * *" }
  local yml="$CABINET_ROOT/instance/config/platform.yml"
  local officers_from_yml=""

  if [ -f "$yml" ]; then
    # Extract lines under officers: block that have type: fulltime
    # Inline YAML format (enforced by platform.yml comment): "  cos: { type: fulltime }"
    # We extract the officer key from lines matching the fulltime type.
    local in_officers=false
    while IFS= read -r line; do
      if echo "$line" | grep -qE '^officers:'; then
        in_officers=true
        continue
      fi
      # End of officers block when we hit a non-indented non-empty line
      if [ "$in_officers" = true ]; then
        if echo "$line" | grep -qE '^[^[:space:]#]'; then
          break
        fi
        # Skip comment lines and blank lines
        echo "$line" | grep -qE '^[[:space:]]*#' && continue
        echo "$line" | grep -qE '^[[:space:]]*$' && continue
        # Extract officer key if line has type: fulltime
        if echo "$line" | grep -qE 'type:[[:space:]]*fulltime'; then
          local officer
          officer=$(echo "$line" | grep -oE '^[[:space:]]+[a-z0-9_-]+' | tr -d '[:space:]')
          [ -n "$officer" ] && officers_from_yml="$officers_from_yml $officer"
        fi
      fi
    done < "$yml"
  fi

  if [ -n "$officers_from_yml" ]; then
    # Return trimmed space-separated list
    echo "$officers_from_yml" | tr -s ' ' | sed 's/^ //'
  else
    # Fallback default set
    echo "cos cto cpo coo cro" | tr ',' ' '
  fi
}

# ---------------------------------------------------------------------------
# Spin up officers in parallel (step 6)
# ---------------------------------------------------------------------------
step_spin_up_officers() {
  local officers_list
  officers_list=$(enumerate_officers)

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would start officers in parallel: $officers_list"
    dry "  Per officer: bash cabinet/scripts/start-officer.sh <officer> --project $SLUG"
    dry "  Then wait for tmux window: cabinet:officer-<officer>-$SLUG"
    return 0
  fi

  info "Starting officers: $officers_list"

  local pids=()
  local officers_arr=()

  for officer in $officers_list; do
    officers_arr+=("$officer")
    (
      local window="officer-${officer}-${SLUG}"
      local start_script="$CABINET_ROOT/cabinet/scripts/start-officer.sh"
      if [ ! -f "$start_script" ]; then
        echo "[cabinet-spawn] start-officer.sh not found for $officer" >&2
        exit 1
      fi
      bash "$start_script" "$officer" --project "$SLUG"
    ) &
    pids+=($!)
  done

  # Wait for all background starts to complete
  local failed=()
  for i in "${!pids[@]}"; do
    local pid="${pids[$i]}"
    local officer="${officers_arr[$i]}"
    if ! wait "$pid"; then
      failed+=("$officer")
      err "start-officer.sh failed for officer '$officer'"
    fi
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    err "Failed officers: ${failed[*]}"
    err "Partial spawn — re-run cabinet-spawn.sh to retry"
    exit 1
  fi

  # Verify each tmux window is alive (up to 15s per officer)
  info "Verifying tmux windows..."
  for officer in $officers_list; do
    local window="officer-${officer}-${SLUG}"
    local deadline=$(($(date +%s) + 15))
    local alive=false
    while [ "$(date +%s)" -lt "$deadline" ]; do
      if tmux has-session -t "cabinet:${window}" 2>/dev/null; then
        alive=true
        break
      fi
      sleep 1
    done
    if [ "$alive" = true ]; then
      info "  [OK] cabinet:${window} alive"
    else
      err "  tmux window cabinet:${window} not found after 15s"
      err "  Check 'tmux list-windows -t cabinet' for status"
      exit 1
    fi
  done

  info "All officers started"
  SPAWNED_OFFICERS="$officers_list"
}

# SPAWNED_OFFICERS is set by step_spin_up_officers; declare here for scope
SPAWNED_OFFICERS=""

# ---------------------------------------------------------------------------
# Bootstrap per-(officer, project) Tier 2 note dirs (step 7)
# ---------------------------------------------------------------------------
step_bootstrap_tier2() {
  local officers_list
  officers_list=$(enumerate_officers)

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would mkdir -p instance/memory/tier2/<officer>/$SLUG/ + .gitkeep for: $officers_list"
    return 0
  fi

  for officer in $officers_list; do
    local dir="$CABINET_ROOT/instance/memory/tier2/${officer}/${SLUG}"
    mkdir -p "$dir"
    # .gitkeep so the dir is visible to officers on first session
    touch "$dir/.gitkeep"
  done
  info "Tier 2 per-project dirs created for: $officers_list"
}

# ---------------------------------------------------------------------------
# Write first heartbeat to Redis (step 8)
# ---------------------------------------------------------------------------
step_first_heartbeat() {
  local officers_list
  officers_list=$(enumerate_officers)

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would write cabinet:heartbeat:<officer>:$SLUG to Redis (TTL 900s) for: $officers_list"
    return 0
  fi

  local rhost="${REDIS_HOST:-redis}"
  local rport="${REDIS_PORT:-6379}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  for officer in $officers_list; do
    redis-cli -h "$rhost" -p "$rport" \
      SET "cabinet:heartbeat:${officer}:${SLUG}" "$ts" EX 900 > /dev/null 2>&1 || true
  done
  info "Heartbeats written for: $officers_list (TTL 900s)"
}

# ---------------------------------------------------------------------------
# Verify trigger surface (step 9)
# ---------------------------------------------------------------------------
step_verify_triggers() {
  if [ "$DRY_RUN" = "1" ]; then
    dry "Would send + read-back + ACK a test trigger for each officer on stream cabinet:triggers:<officer>:$SLUG"
    return 0
  fi

  local triggers_lib="$CABINET_ROOT/cabinet/scripts/lib/triggers.sh"
  if [ ! -f "$triggers_lib" ]; then
    info "triggers.sh not found — skipping trigger surface verification"
    return 0
  fi

  # shellcheck disable=SC1090
  source "$triggers_lib"

  local officers_list
  officers_list=$(enumerate_officers)
  local failed=()

  for officer in $officers_list; do
    local test_msg="Pool spawn verification — your ${SLUG} project session is live"
    # Send on per-project stream
    CABINET_ACTIVE_PROJECT="$SLUG" OFFICER_NAME="cabinet-spawn" \
      trigger_send "$officer" "$test_msg" 2>/dev/null || true

    # Read back — should surface our message
    local recv
    recv=$(CABINET_ACTIVE_PROJECT="$SLUG" trigger_read "$officer" 2>/dev/null || true)
    if echo "$recv" | grep -qF "Pool spawn verification"; then
      # ACK to clean up
      local ids_file="/tmp/.trigger_ids_${officer}_${SLUG}"
      if [ -f "$ids_file" ]; then
        local ids
        ids=$(cat "$ids_file")
        CABINET_ACTIVE_PROJECT="$SLUG" trigger_ack "$officer" "$ids" 2>/dev/null || true
        rm -f "$ids_file"
      fi
      info "  [OK] trigger surface verified for officer=$officer project=$SLUG"
    else
      failed+=("$officer")
      err "  [WARN] trigger read-back failed for officer=$officer project=$SLUG (non-fatal)"
    fi
  done

  if [ "${#failed[@]}" -gt 0 ]; then
    info "Trigger verification partial failures (non-fatal): ${failed[*]}"
    info "  Officers will still receive triggers normally once sessions are warmed up"
  fi
}

# ---------------------------------------------------------------------------
# Notify CoS (step 10)
# ---------------------------------------------------------------------------
step_notify_cos() {
  local officers_list
  officers_list=$(enumerate_officers)

  # Build per-officer window summary (window name for each)
  local officer_summary=""
  for officer in $officers_list; do
    local window="officer-${officer}-${SLUG}"
    officer_summary="${officer_summary}  ${officer}: cabinet:${window}\n"
  done
  local officer_count
  officer_count=$(echo "$officers_list" | wc -w | tr -d ' ')

  local message
  message="CABINET SPAWNED: ${SLUG} live with ${officer_count} officers in pool mode.

Officers started:
$(printf '%b' "$officer_summary")
CAPTAIN ACTION REQUIRED (founder-action items):
  1. Telegram bot tokens — create a group chat for ${SLUG}, add officer bots,
     fill TELEGRAM_HQ_CHAT_ID in cabinet/env/${SLUG}.env.
  2. Notion IDs — provision Cabinet HQ DB pages for ${SLUG},
     fill in instance/config/projects/${SLUG}.yml (notion section).
  3. Neon DB — provision a Neon project for ${SLUG}'s product database,
     fill NEON_CONNECTION_STRING in cabinet/env/${SLUG}.env.

These three items are blocking for full officer functionality.
Repo: ${REPO_URL}"

  if [ "$DRY_RUN" = "1" ]; then
    dry "Would notify CoS with:"
    echo "$message" | sed 's/^/  /'
    return 0
  fi

  local triggers_lib="$CABINET_ROOT/cabinet/scripts/lib/triggers.sh"
  if [ -f "$triggers_lib" ]; then
    # shellcheck disable=SC1090
    source "$triggers_lib" 2>/dev/null || true
    OFFICER_NAME="cabinet-spawn" trigger_send "cos" "$message" 2>/dev/null || true
    info "CoS notified via trigger stream"
  fi

  local notify_script="$CABINET_ROOT/cabinet/scripts/notify-officer.sh"
  if [ -f "$notify_script" ]; then
    OFFICER_NAME="cabinet-spawn" bash "$notify_script" cos "$message" 2>/dev/null || true
    info "CoS notified via notify-officer.sh"
  fi
}

# ---------------------------------------------------------------------------
# State file tracking (idempotency + locking)
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

  # Use flock on the state file for concurrent invocation safety.
  # Open FD 9 on the state file (creates it if needed), then flock -n.
  # shellcheck disable=SC2188
  exec 9>>"$STATE_FILE"
  if ! flock -n $LOCK_FD 2>/dev/null; then
    err "Another cabinet-spawn for slug '$SLUG' is already running (state file locked)"
    err "  State file: $STATE_FILE"
    err "  If the previous run crashed, remove $STATE_FILE and re-run"
    exit 1
  fi

  # Record our PID so operator can identify the owning process
  echo "PID=$$" >> "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" = "1" ]; then
  info "=== DRY RUN MODE — no filesystem, tmux, or Redis changes will be made ==="
  info "Slug:         ${SLUG:-<missing>}"
  info "Repo:         ${REPO_URL:-<missing>}"
  info "skip-create:  $SKIP_CREATE"
  info "officers:     ${OFFICER_OVERRIDE:-<from platform.yml>}"
  echo ""
fi

# Step 1 + 2: validation runs unconditionally (fast, no state tracking needed)
step_validate_slug
step_validate_repo_url

if [ "$DRY_RUN" = "1" ]; then
  step_preflight
  step_provision_project
  step_bootstrap_tier2
  step_spin_up_officers
  step_first_heartbeat
  step_verify_triggers
  step_notify_cos
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

run_step "preflight"          step_preflight
run_step "provision"          step_provision_project
run_step "tier2-dirs"         step_bootstrap_tier2
run_step "spin-up-officers"   step_spin_up_officers
run_step "heartbeats"         step_first_heartbeat
run_step "trigger-verify"     step_verify_triggers
run_step "notify-cos"         step_notify_cos

# All steps complete — clean up state file (holds the flock; release on exit)
exec 9>&-
rm -f "$STATE_FILE"

info ""
info "=================================================="
info " Cabinet '${SLUG}' spawned successfully"
info "=================================================="
info ""
info "Officers live in pool mode: $(enumerate_officers | tr ' ' ',')"
info ""
info "CAPTAIN ACTION REQUIRED:"
info "  1. Telegram group chat ID -> cabinet/env/${SLUG}.env (TELEGRAM_HQ_CHAT_ID)"
info "  2. Notion page IDs        -> instance/config/projects/${SLUG}.yml"
info "  3. Neon connection string -> cabinet/env/${SLUG}.env (NEON_CONNECTION_STRING)"
info ""
info "Monitor officers:"
info "  tmux attach -t cabinet"
info "  bash cabinet/scripts/list-officers.sh"
info ""
