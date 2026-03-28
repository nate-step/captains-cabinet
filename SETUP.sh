#!/bin/bash
# =============================================================
# Founder's Cabinet — Server Setup Script
# Run this on a fresh Ubuntu 24.04 Hetzner CPX31
# =============================================================
set -e

echo "============================================"
echo " Founder's Cabinet — Server Setup"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================"

# ============================================================
# 1. System packages
# ============================================================
echo ""
echo "[1/6] Installing system packages..."
apt-get update -qq
apt-get install -y -qq curl git tmux jq ca-certificates gnupg > /dev/null 2>&1

# ============================================================
# 2. Docker
# ============================================================
echo "[2/6] Installing Docker..."
if ! command -v docker &> /dev/null; then
  curl -fsSL https://get.docker.com | sh > /dev/null 2>&1
  systemctl enable docker > /dev/null 2>&1
fi
docker compose version

# ============================================================
# 3. Node.js 22
# ============================================================
echo "[3/6] Installing Node.js 22..."
if ! command -v node &> /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1
  apt-get install -y -qq nodejs > /dev/null 2>&1
fi
node --version

# ============================================================
# 4. Bun (required by Channels plugin)
# ============================================================
echo "[4/6] Installing Bun..."
if ! command -v bun &> /dev/null; then
  curl -fsSL https://bun.sh/install | bash > /dev/null 2>&1
  export PATH="$HOME/.bun/bin:$PATH"
  echo 'export PATH="$HOME/.bun/bin:$PATH"' >> ~/.bashrc
fi
bun --version

# ============================================================
# 5. Claude Code
# ============================================================
echo "[5/6] Installing Claude Code..."
if ! command -v claude &> /dev/null; then
  npm install -g @anthropic-ai/claude-code > /dev/null 2>&1
fi
claude --version

# ============================================================
# 6. Clone repos
# ============================================================
echo "[6/6] Setting up repos..."

# Cabinet framework
if [ ! -d /opt/founders-cabinet ]; then
  git clone https://github.com/nate-step/founders-cabinet.git /opt/founders-cabinet
  echo "  Cloned founders-cabinet"
else
  echo "  /opt/founders-cabinet already exists, pulling..."
  cd /opt/founders-cabinet && git pull
fi

# Product repo
if [ ! -d /opt/Sensed ]; then
  git clone https://github.com/nate-step/Sensed.git /opt/Sensed
  echo "  Cloned Sensed"
else
  echo "  /opt/Sensed already exists, pulling..."
  cd /opt/Sensed && git pull
fi

# Make scripts executable
chmod +x /opt/founders-cabinet/cabinet/scripts/*.sh
chmod +x /opt/founders-cabinet/cabinet/scripts/hooks/*.sh
chmod +x /opt/founders-cabinet/cabinet/cron/*.sh

echo ""
echo "============================================"
echo " Setup complete!"
echo ""
echo " Next steps:"
echo "   1. cd /opt/founders-cabinet/cabinet"
echo "   2. cp .env.example .env"
echo "   3. nano .env  (fill in your credentials)"
echo "   4. docker compose build"
echo "   5. docker compose up -d postgres redis"
echo "   6. Verify: docker compose exec postgres pg_isready"
echo "============================================"
