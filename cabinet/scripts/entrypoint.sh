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
  echo "  /home/cabinet/start-officer.sh cos"
  echo "  /home/cabinet/start-officer.sh cto"
  echo "  /home/cabinet/start-officer.sh cro"
  echo "  /home/cabinet/start-officer.sh cpo"
  echo ""

  # Keep container alive
  exec tail -f /dev/null
'
