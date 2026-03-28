#!/bin/bash
set -e

echo "============================================"
echo " Sensed Cabinet — Officer Container Starting"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# Install Telegram Channels plugin if not already installed
echo "Checking Channels plugin..."
claude /plugin install telegram@claude-plugins-official 2>/dev/null || true

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
echo "Or attach to tmux:"
echo "  tmux attach -t cabinet"
echo ""

# Keep container alive
exec tail -f /dev/null
