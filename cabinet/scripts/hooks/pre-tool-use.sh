#!/bin/bash
# pre-tool-use.sh — Runs before every tool invocation
# Exit 0 = allow, Exit 2 = block (with reason on stdout)
#
# Arguments:
#   $1 = TOOL_NAME (e.g., "Bash", "Edit", "Write")
#   $2 = TOOL_INPUT (JSON string of tool parameters)

TOOL_NAME="$1"
TOOL_INPUT="$2"
REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

# ============================================================
# 1. KILL SWITCH CHECK
# ============================================================
KILLSWITCH=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
if [ "$KILLSWITCH" = "active" ]; then
  echo "KILL SWITCH ACTIVE — all operations halted by Captain. Send /resume to deactivate."
  exit 2
fi

# ============================================================
# 2. DAILY SPENDING LIMIT CHECK
# ============================================================
TODAY=$(date -u +%Y-%m-%d)
DAILY_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:daily:$TODAY" 2>/dev/null)
DAILY_COST=${DAILY_COST:-0}

# $300/day limit (stored in cents to avoid float issues)
DAILY_LIMIT=30000
if [ "$DAILY_COST" -ge "$DAILY_LIMIT" ] 2>/dev/null; then
  echo "DAILY SPENDING LIMIT REACHED (\$${DAILY_COST%??}.${DAILY_COST: -2} / \$300.00). Alert the Captain."
  exit 2
fi

# Per-officer $75/day limit
OFFICER="${OFFICER_NAME:-unknown}"
OFFICER_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:officer:$OFFICER:$TODAY" 2>/dev/null)
OFFICER_COST=${OFFICER_COST:-0}
OFFICER_LIMIT=7500
if [ "$OFFICER_COST" -ge "$OFFICER_LIMIT" ] 2>/dev/null; then
  echo "OFFICER DAILY LIMIT REACHED ($OFFICER: \$${OFFICER_COST%??}.${OFFICER_COST: -2} / \$75.00). Pause non-critical work and alert the Captain."
  exit 2
fi

# ============================================================
# 3. PROHIBITED ACTIONS
# ============================================================
if [ "$TOOL_NAME" = "Bash" ]; then
  # Extract command from tool input
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
  
  # Block dangerous commands
  case "$CMD" in
    *"rm -rf /"*|*"rm -rf /*"*)
      echo "BLOCKED: Destructive filesystem operation"
      exit 2
      ;;
    *"docker"*|*"systemctl"*|*"sudo"*)
      echo "BLOCKED: System-level command not permitted"
      exit 2
      ;;
    *"shutdown"*|*"reboot"*|*"halt"*)
      echo "BLOCKED: System control command not permitted"
      exit 2
      ;;
    *"vercel deploy"*|*"vercel --prod"*)
      echo "BLOCKED: Production deployment requires Captain approval"
      exit 2
      ;;
    *"DROP TABLE"*|*"DROP DATABASE"*|*"TRUNCATE"*|*"DELETE FROM"*)
      echo "BLOCKED: Destructive database operation requires Captain approval"
      exit 2
      ;;
  esac
fi

# ============================================================
# 4. CONSTITUTION PROTECTION
# ============================================================
if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
  FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // empty' 2>/dev/null)
  case "$FILE_PATH" in
    *"constitution/"*)
      echo "BLOCKED: Constitution files are read-only. Propose amendments through the self-improvement loop."
      exit 2
      ;;
    *".env"*)
      echo "BLOCKED: Environment files cannot be modified by Officers"
      exit 2
      ;;
    *"cabinet/docker-compose"*|*"Dockerfile"*)
      echo "BLOCKED: Infrastructure files cannot be modified by Officers"
      exit 2
      ;;
  esac
fi

# All checks passed — allow the tool
exit 0
