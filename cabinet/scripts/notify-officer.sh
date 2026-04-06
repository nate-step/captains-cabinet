#!/bin/bash
# notify-officer.sh — Push a trigger to another Officer via Redis
# The receiving Officer's post-tool-use hook will surface it.
#
# Usage: notify-officer.sh <officer> "Your message here"
# Example: notify-officer.sh cto "New spec ready: feature-x.md"

TARGET="${1:?Usage: notify-officer.sh <cos|cto|cro|cpo|coo> \"message\"}"
MESSAGE="${2:?Usage: notify-officer.sh <officer> \"message\"}"

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
SENDER="${OFFICER_NAME:-unknown}"

# Push to Redis trigger queue
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" RPUSH "cabinet:triggers:$TARGET" \
  "[$TIMESTAMP] From $SENDER: $MESSAGE" > /dev/null 2>&1

# Set 6h expiry (auto-cleanup if Officer is down)
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "cabinet:triggers:$TARGET" 21600 > /dev/null 2>&1

echo "Trigger sent to $TARGET"
