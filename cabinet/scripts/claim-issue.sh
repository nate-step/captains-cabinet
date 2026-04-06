#!/bin/bash
# claim-issue.sh — Claim a Linear issue to prevent duplicate work
# Usage: bash claim-issue.sh <issue-id> [agent-name]
# Returns 0 if claimed, 1 if already claimed by another agent

set -euo pipefail

ISSUE_ID="${1:-}"
AGENT_NAME="${2:-${OFFICER_NAME:-cto}}"

if [ -z "$ISSUE_ID" ]; then
  echo "Usage: bash claim-issue.sh <issue-id> [agent-name]"
  exit 1
fi

REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
KEY="cabinet:claimed:${ISSUE_ID}"

# Check if already claimed
CURRENT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "$KEY" 2>/dev/null)

if [ -n "$CURRENT" ] && [ "$CURRENT" != "(nil)" ] && [ "$CURRENT" != "$AGENT_NAME" ]; then
  echo "ALREADY CLAIMED: $ISSUE_ID is claimed by $CURRENT"
  exit 1
fi

# Claim it (expires after 4 hours)
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "$KEY" "$AGENT_NAME" EX 14400 > /dev/null 2>&1
echo "CLAIMED: $ISSUE_ID by $AGENT_NAME"
exit 0
