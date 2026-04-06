#!/bin/bash
# release-issue.sh — Release a claimed Linear issue
# Usage: bash release-issue.sh <issue-id>

ISSUE_ID="${1:-}"
if [ -z "$ISSUE_ID" ]; then
  echo "Usage: bash release-issue.sh <issue-id>"
  exit 1
fi

REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "cabinet:claimed:${ISSUE_ID}" > /dev/null 2>&1
echo "RELEASED: $ISSUE_ID"
