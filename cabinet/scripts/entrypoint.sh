#!/bin/bash
set -e

echo "============================================"
echo " Founder's Cabinet — Officer Container Starting"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# Invariant: cabinet user must be UID 60001 + GID 60000 for host-agent SO_PEERCRED auth
# AND for /run/cabinet/ directory traversal (mode 0750 root:cabinet GID 60000).
# Catches future regressions where the Dockerfile UID alignment is silently dropped.
CABINET_UID=$(id -u cabinet 2>/dev/null || echo "")
CABINET_GID=$(id -g cabinet 2>/dev/null || echo "")
if [ "$CABINET_UID" != "60001" ] || [ "$CABINET_GID" != "60000" ]; then
  echo "FATAL: cabinet user UID/GID is '$CABINET_UID:$CABINET_GID', expected 60001:60000 (host-agent SO_PEERCRED + /run/cabinet group access)"
  exit 1
fi

# Fix ownership on mounted volumes (runs as root).
#
# FW-059 (2026-04-28): coverage extended past the original FW-018 Phase B
# Stream A surface (memory/, shared/, ~/.claude/, ~/.claude-channels/) to
# include paths officers write to during normal operation but which were
# missed on first-rebuild — required CoS to host-side chgrp manually.
# Adding them here means a fresh `docker compose up -d --build` leaves
# the container fully self-sufficient on UID 60001.
#
# .git/ is mounted read/write because officers commit + push from inside
# the container; chown'ing during a live git op is theoretically racy
# but entrypoint runs before any officer process so timing is safe.
echo "Fixing volume permissions..."
chown -R cabinet:cabinet /opt/founders-cabinet/memory/ 2>/dev/null || true
chown -R cabinet:cabinet /opt/founders-cabinet/shared/ 2>/dev/null || true
chown -R cabinet:cabinet /opt/founders-cabinet/instance/memory/ 2>/dev/null || true
chown -R cabinet:cabinet /opt/founders-cabinet/cabinet/scripts/ 2>/dev/null || true
chown -R cabinet:cabinet /opt/founders-cabinet/.git/ 2>/dev/null || true
chown cabinet:cabinet /opt/founders-cabinet/cabinet/.env 2>/dev/null || true
chown -R cabinet:cabinet /home/cabinet/.claude/ 2>/dev/null || true
chown -R cabinet:cabinet /home/cabinet/.claude-channels/ 2>/dev/null || true
echo "Permissions fixed."

# Pre-bake Claude Code trust state so onboarding/trust prompts are skipped
# on every officer launch. Survives image rebuilds (which wipe ~/.claude.json
# since the volume mount only covers ~/.claude/, not the file in home root).
echo "Preparing Claude state (trust + onboarding)..."
su cabinet -s /bin/bash -c 'bash /opt/founders-cabinet/cabinet/scripts/prepare-claude-state.sh' || \
  echo "WARNING: prepare-claude-state failed — trust prompts may appear on first officer start"

# Everything below runs as cabinet user
exec su cabinet -s /bin/bash -c '
  # Start tmux server
  tmux new-session -d -s cabinet -n main

  echo "Cabinet tmux session created."

  # Assemble config from platform + active project on boot
  echo "Assembling config for active project..."
  bash /opt/founders-cabinet/cabinet/scripts/assemble-config.sh || echo "WARNING: Config assembly failed — using existing product.yml"

  # Seed Redis with active project if not set
  ACTIVE_SLUG=$(cat /opt/founders-cabinet/instance/config/active-project.txt 2>/dev/null | tr -d "[:space:]")
  if [ -n "$ACTIVE_SLUG" ]; then
    redis-cli -h redis -p 6379 SETNX cabinet:active-project "$ACTIVE_SLUG" > /dev/null 2>&1 || true
  fi

  echo ""
  echo "Commands:"
  echo "  start-officer.sh <abbreviation>        — Start an officer"
  echo "  switch-project.sh <slug>               — Switch active project"
  echo "  list-projects.sh                       — List available projects"
  echo "  create-officer.sh <args>               — Create a new officer"
  echo ""

  # Start the officer supervisor (auto-restart on crash)
  nohup bash /opt/founders-cabinet/cabinet/scripts/officer-supervisor.sh \
    >> /opt/founders-cabinet/memory/logs/supervisor.log 2>&1 &
  echo "Officer supervisor started (PID $!)."

  # FW-082 hotfix-5: AUTO_START_OFFICERS env (set per cabinet by
  # cabinet-bootstrap.sh in spawned compose) auto-launches each officer in
  # its own tmux window. Format: comma-separated "officer[:project]".
  # Examples: "cos" / "cos:stephie" / "cos,cto,cpo,cro,coo".
  # Unset/empty = legacy behavior (officers started manually via start-officer.sh).
  if [ -n "${AUTO_START_OFFICERS:-}" ]; then
    echo ""
    echo "AUTO_START_OFFICERS detected: $AUTO_START_OFFICERS"
    _START_SCRIPT_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}/cabinet/scripts/start-officer.sh"
    [ -x "$_START_SCRIPT_ROOT" ] || _START_SCRIPT_ROOT="/opt/founders-cabinet/cabinet/scripts/start-officer.sh"
    echo "$AUTO_START_OFFICERS" | tr "," "\n" | while IFS= read -r entry; do
      entry=$(echo "$entry" | tr -d "[:space:]")
      [ -z "$entry" ] && continue
      officer="${entry%%:*}"
      project="${entry#*:}"
      [ "$officer" = "$project" ] && project=""
      # Slug allowlists (FW-073 + FW-074 + FW-082 conventions)
      if ! echo "$officer" | grep -qE "^[a-z][a-z0-9-]*$" || [ "${#officer}" -gt 32 ]; then
        echo "  Skipping invalid officer slug: $officer"
        continue
      fi
      if [ -n "$project" ]; then
        if ! echo "$project" | grep -qE "^[a-z0-9][a-z0-9-]*$" || [ "${#project}" -gt 32 ]; then
          echo "  Skipping invalid project slug: $project"
          continue
        fi
      fi
      echo "  Starting officer $officer${project:+ (project: $project)}"
      if [ -n "$project" ]; then
        tmux new-window -t cabinet -n "officer-${officer}" -d \
          "bash \"$_START_SCRIPT_ROOT\" $officer --project $project; exec bash" 2>/dev/null || \
          echo "  WARN: tmux window create failed for officer-$officer"
      else
        tmux new-window -t cabinet -n "officer-${officer}" -d \
          "bash \"$_START_SCRIPT_ROOT\" $officer; exec bash" 2>/dev/null || \
          echo "  WARN: tmux window create failed for officer-$officer"
      fi
    done
    echo ""
  fi

  # Keep container alive
  exec tail -f /dev/null
'
