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
  echo ""
  echo "To start Officers, exec into this container and run:"
  echo "  /home/cabinet/start-officer.sh <officer-abbreviation>"
  echo "To create a new Officer:"
  echo "  bash /opt/founders-cabinet/cabinet/scripts/create-officer.sh <abbrev> <title> <domain> <bot-username> <bot-token>"
  echo ""

  # Start the officer supervisor (auto-restart on crash)
  nohup bash /opt/founders-cabinet/cabinet/scripts/officer-supervisor.sh \
    >> /opt/founders-cabinet/memory/logs/supervisor.log 2>&1 &
  echo "Officer supervisor started (PID $!)."

  # Keep container alive
  exec tail -f /dev/null
'
