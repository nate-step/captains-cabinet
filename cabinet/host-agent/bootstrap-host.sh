#!/usr/bin/env bash
# bootstrap-host.sh — Spec 035 Phase A one-time host installer
#
# Installs the Cabinet host-agent daemon and admin-bot systemd services.
# Run once per host as root:
#
#   curl -sSL https://raw.githubusercontent.com/nate-step/captains-cabinet/master/cabinet/host-agent/bootstrap-host.sh | sudo bash
#
# Or download + verify sha256 (recommended):
#   curl -sSL .../bootstrap-host.sh -o /tmp/b.sh
#   echo "<sha256>  /tmp/b.sh" | sha256sum -c -
#   sudo bash /tmp/b.sh
#
# Idempotent — safe to re-run. Only restarts services when /etc/cabinet/admin-bot.env
# is updated (new token entered by Captain).
#
# shellcheck-clean.

set -euo pipefail

# ----------------------------------------------------------------
# Constants — deterministic UIDs per CTO v2-review N2
# ----------------------------------------------------------------
CABINET_GID=60000
CABINET_UID=60001
CABINET_GROUP="cabinet"
CABINET_USER="cabinet-cos"
CABINET_REPO="/opt/founders-cabinet"

SOCKET_DIR="/run/cabinet"
LOG_DIR="/var/log/cabinet"
AUDIT_LOG="${LOG_DIR}/cos-actions.jsonl"
ETC_DIR="/etc/cabinet"
ENV_FILE="${ETC_DIR}/admin-bot.env"

HOST_AGENT_SRC="${CABINET_REPO}/cabinet/host-agent/server.py"
ADMIN_BOT_SRC="${CABINET_REPO}/cabinet/admin-bot/bot.py"
HOST_AGENT_UNIT="cabinet-host-agent.service"
ADMIN_BOT_UNIT="cabinet-admin-bot.service"

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------
info()  { echo "[bootstrap] INFO:  $*" >&2; }
warn()  { echo "[bootstrap] WARN:  $*" >&2; }
die()   { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Must be run as root (sudo)."
}

require_commands() {
  local missing=()
  for cmd in systemctl logrotate python3 chattr; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required commands: ${missing[*]}. Install them and retry."
  fi
  # python-telegram-bot — required for admin-bot. Auto-install if missing.
  # Ubuntu 24.04+ ships python3 without pip; install both if needed.
  # Task #49 / HOST-SETUP.md — captured from first-install friction 2026-04-21.
  if ! command -v pip3 >/dev/null 2>&1; then
    info "pip3 not found — installing python3-pip (apt)."
    apt-get update -qq >/dev/null 2>&1 \
      && apt-get install -y -qq python3-pip >/dev/null 2>&1 \
      || die "Failed to install python3-pip. Install manually: apt install -y python3-pip"
  fi
  if ! python3 -c "import telegram" 2>/dev/null; then
    info "Installing python-telegram-bot==22.7 (pip3 --break-system-packages)."
    # --break-system-packages required on PEP 668 systems (Python 3.12+).
    # Version pinned to match CRO library pressure-test (KillMode=mixed compat).
    pip3 install --break-system-packages --quiet python-telegram-bot==22.7 \
      || die "Failed to install python-telegram-bot. Try: pip3 install --break-system-packages python-telegram-bot==22.7"
    python3 -c "import telegram" 2>/dev/null \
      || die "python-telegram-bot install reported success but import still fails."
  fi
}

# ----------------------------------------------------------------
# Step 1 — Create group + user with deterministic IDs
# ----------------------------------------------------------------
create_user_and_group() {
  # Group
  if getent group "${CABINET_GID}" >/dev/null 2>&1; then
    local existing_group
    existing_group=$(getent group "${CABINET_GID}" | cut -d: -f1)
    if [[ "${existing_group}" != "${CABINET_GROUP}" ]]; then
      die "GID ${CABINET_GID} already used by group '${existing_group}'. Manual cleanup needed."
    fi
    info "Group '${CABINET_GROUP}' (GID ${CABINET_GID}) already exists — skipping."
  else
    groupadd --gid "${CABINET_GID}" "${CABINET_GROUP}"
    info "Created group '${CABINET_GROUP}' (GID ${CABINET_GID})."
  fi

  # User
  if getent passwd "${CABINET_UID}" >/dev/null 2>&1; then
    local existing_user
    existing_user=$(getent passwd "${CABINET_UID}" | cut -d: -f1)
    if [[ "${existing_user}" != "${CABINET_USER}" ]]; then
      die "UID ${CABINET_UID} already used by user '${existing_user}'. Manual cleanup needed."
    fi
    info "User '${CABINET_USER}' (UID ${CABINET_UID}) already exists — skipping."
  else
    useradd \
      --uid "${CABINET_UID}" \
      --gid "${CABINET_GID}" \
      --no-create-home \
      --shell /usr/sbin/nologin \
      --comment "Cabinet CoS container service account" \
      --system \
      "${CABINET_USER}"
    info "Created user '${CABINET_USER}' (UID ${CABINET_UID}) in group '${CABINET_GROUP}'."
  fi
}

# ----------------------------------------------------------------
# Step 2 — Create directories and audit log
# ----------------------------------------------------------------
create_dirs_and_log() {
  # Socket dir (tmpfs is fine; re-created on boot from the host-agent unit)
  if [[ ! -d "${SOCKET_DIR}" ]]; then
    mkdir -p "${SOCKET_DIR}"
    info "Created ${SOCKET_DIR}."
  fi
  chmod 0750 "${SOCKET_DIR}"
  chown "root:${CABINET_GROUP}" "${SOCKET_DIR}"

  # Log dir
  if [[ ! -d "${LOG_DIR}" ]]; then
    mkdir -p "${LOG_DIR}"
    info "Created ${LOG_DIR}."
  fi
  chmod 0750 "${LOG_DIR}"
  chown "root:${CABINET_GROUP}" "${LOG_DIR}"

  # Audit log — create if missing, then set append-only attribute
  if [[ ! -f "${AUDIT_LOG}" ]]; then
    touch "${AUDIT_LOG}"
    chmod 0640 "${AUDIT_LOG}"
    chown "root:${CABINET_GROUP}" "${AUDIT_LOG}"
    # chattr +a: kernel-level append-only (blocks truncate/overwrite)
    if chattr +a "${AUDIT_LOG}" 2>/dev/null; then
      info "Created ${AUDIT_LOG} with chattr +a (append-only)."
    else
      warn "chattr +a failed — filesystem may not support it (e.g. tmpfs, overlayfs)."
      warn "Audit log immutability is advisory only on this host."
    fi
  else
    info "${AUDIT_LOG} already exists — ensuring chattr +a."
    chattr +a "${AUDIT_LOG}" 2>/dev/null || warn "chattr +a failed (may already be set or unsupported)."
  fi
}

# ----------------------------------------------------------------
# Step 3 — Install logrotate config
# ----------------------------------------------------------------
install_logrotate() {
  local cfg="/etc/logrotate.d/cabinet-cos"
  cat > "${cfg}" <<'LOGROTATE'
/var/log/cabinet/cos-actions.jsonl {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root cabinet
    # Re-apply append-only after rotation creates a new file
    postrotate
        /usr/bin/chattr +a /var/log/cabinet/cos-actions.jsonl 2>/dev/null || true
    endscript
}
LOGROTATE
  chmod 0644 "${cfg}"
  info "Installed logrotate config at ${cfg} (daily, 30-day retention)."
}

# ----------------------------------------------------------------
# Step 4 — /etc/cabinet env dir + interactive token prompt
# ----------------------------------------------------------------
configure_env() {
  # Create /etc/cabinet (0700 root-only parent dir per spec)
  if [[ ! -d "${ETC_DIR}" ]]; then
    mkdir -p "${ETC_DIR}"
    chmod 0700 "${ETC_DIR}"
    info "Created ${ETC_DIR} (mode 0700)."
  fi

  local token_changed=false

  # Prompt for admin bot token
  local existing_token=""
  if [[ -f "${ENV_FILE}" ]]; then
    existing_token=$(grep -m1 '^ADMIN_BOT_TOKEN=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)
  fi

  if [[ -n "${existing_token}" ]]; then
    info "${ENV_FILE} already contains a token."
    echo
    echo "  Current token is set. Enter a new token to replace it, or press Enter to keep existing."
    read -r -p "  New Telegram bot token (Enter to skip): " new_token
    if [[ -n "${new_token}" ]]; then
      write_env_file "${new_token}"
      token_changed=true
    fi
  else
    echo
    echo "  ============================================================"
    echo "  Admin bot Telegram token required."
    echo "  Create a bot via @BotFather on Telegram and paste the token."
    echo "  ============================================================"
    local token=""
    while [[ -z "${token}" ]]; do
      read -r -p "  Telegram bot token: " token
      if [[ -z "${token}" ]]; then
        echo "  Token cannot be empty."
      fi
    done
    write_env_file "${token}"
    token_changed=true
  fi

  echo "${token_changed}"  # Return value via stdout
}

write_env_file() {
  local token="$1"
  cat > "${ENV_FILE}" <<EOF
ADMIN_BOT_TOKEN=${token}
EOF
  chmod 0600 "${ENV_FILE}"
  chown root:root "${ENV_FILE}"
  info "Wrote ${ENV_FILE} (mode 0600)."
}

# ----------------------------------------------------------------
# Step 5 — Install systemd unit files
# ----------------------------------------------------------------
install_systemd_units() {
  local unit_src_dir="${CABINET_REPO}/cabinet/host-agent"

  # Install host-agent unit
  cp "${unit_src_dir}/${HOST_AGENT_UNIT}" "/etc/systemd/system/${HOST_AGENT_UNIT}"
  chmod 0644 "/etc/systemd/system/${HOST_AGENT_UNIT}"

  # Install admin-bot unit
  cp "${unit_src_dir}/${ADMIN_BOT_UNIT}" "/etc/systemd/system/${ADMIN_BOT_UNIT}"
  chmod 0644 "/etc/systemd/system/${ADMIN_BOT_UNIT}"

  systemctl daemon-reload
  info "Installed systemd units and reloaded daemon."
}

# ----------------------------------------------------------------
# Step 6 — Enable + start/restart services
# ----------------------------------------------------------------
enable_and_start() {
  local token_changed="$1"

  systemctl enable "${HOST_AGENT_UNIT}" "${ADMIN_BOT_UNIT}"
  info "Enabled ${HOST_AGENT_UNIT} and ${ADMIN_BOT_UNIT}."

  # Always (re)start host-agent — it owns no secrets so restart is always safe
  systemctl restart "${HOST_AGENT_UNIT}"
  info "Started ${HOST_AGENT_UNIT}."

  # Only restart admin-bot if token changed (minimise disruption)
  if [[ "${token_changed}" == "true" ]]; then
    systemctl restart "${ADMIN_BOT_UNIT}"
    info "Restarted ${ADMIN_BOT_UNIT} (new token written)."
  else
    # Ensure it's running; start if stopped, no-op if already active
    if ! systemctl is-active --quiet "${ADMIN_BOT_UNIT}"; then
      systemctl start "${ADMIN_BOT_UNIT}"
      info "Started ${ADMIN_BOT_UNIT}."
    else
      info "${ADMIN_BOT_UNIT} is already running — no restart needed."
    fi
  fi
}

# ----------------------------------------------------------------
# Step 7 — Print post-install summary
# ----------------------------------------------------------------
print_summary() {
  echo
  echo "================================================================"
  echo "  Cabinet host-agent bootstrap complete."
  echo "================================================================"
  echo
  echo "  Group:      ${CABINET_GROUP} (GID ${CABINET_GID})"
  echo "  User:       ${CABINET_USER} (UID ${CABINET_UID})"
  echo "  Socket:     ${SOCKET_DIR}/host-agent.sock"
  echo "  Audit log:  ${AUDIT_LOG} (append-only)"
  echo "  Admin bot:  ${ENV_FILE} (mode 0600)"
  echo
  echo "  Next steps:"
  echo "  1. Update docker-compose.yml CoS service with:"
  echo "       user: \"${CABINET_UID}:${CABINET_GID}\""
  echo "       volumes:"
  echo "         - /run/cabinet:/run/cabinet:ro"
  echo "  2. docker compose down && docker compose up -d"
  echo "     (so CoS picks up the new UID)"
  echo "  3. Send /cos ping to your admin bot to verify."
  echo
  echo "  Service status:"
  systemctl status --no-pager --lines=3 "${HOST_AGENT_UNIT}" 2>&1 || true
  echo
  systemctl status --no-pager --lines=3 "${ADMIN_BOT_UNIT}" 2>&1 || true
  echo
}

# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------
main() {
  info "Starting Cabinet host-agent bootstrap (Spec 035 Phase A)."
  echo

  require_root
  require_commands

  # Verify the repo exists at the expected location
  if [[ ! -f "${HOST_AGENT_SRC}" ]]; then
    die "Host-agent source not found at ${HOST_AGENT_SRC}. Ensure the repo is cloned to ${CABINET_REPO}."
  fi
  if [[ ! -f "${ADMIN_BOT_SRC}" ]]; then
    die "Admin-bot source not found at ${ADMIN_BOT_SRC}. Ensure the repo is cloned to ${CABINET_REPO}."
  fi

  create_user_and_group
  create_dirs_and_log
  install_logrotate
  local token_changed
  token_changed=$(configure_env)
  install_systemd_units
  enable_and_start "${token_changed}"
  print_summary

  info "Bootstrap complete."
}

main "$@"
