#!/bin/bash
set -e

echo "============================================"
echo " Founder's Cabinet — Officer Container Starting"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# Fix ownership on mounted volumes (runs as root)
echo "Fixing volume permissions..."
chown -R cabinet:cabinet /opt/founders-cabinet/memory/ 2>/dev/null || true
chown -R cabinet:cabinet /opt/founders-cabinet/shared/ 2>/dev/null || true
chown -R cabinet:cabinet /home/cabinet/.claude/ 2>/dev/null || true
chown -R cabinet:cabinet /home/cabinet/.claude-channels/ 2>/dev/null || true
echo "Permissions fixed."

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

  # Keep container alive
  exec tail -f /dev/null
'
