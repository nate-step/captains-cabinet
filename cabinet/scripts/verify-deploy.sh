#!/bin/bash
# verify-deploy.sh — Poll CI + deploy status
# Usage:
#   bash verify-deploy.sh ci <commit-sha>     — check PR CI status (pre-merge)
#   bash verify-deploy.sh deploy <commit-sha>  — check Vercel deploy (post-merge)
#   bash verify-deploy.sh <commit-sha>         — check both sequentially

set -euo pipefail

MODE="${1:-both}"
COMMIT_SHA=""

if [ "$MODE" = "ci" ] || [ "$MODE" = "deploy" ] || [ "$MODE" = "both" ]; then
  COMMIT_SHA="${2:-$(cd /workspace/product && git rev-parse HEAD)}"
else
  # Legacy: first arg is commit sha, mode is "both"
  COMMIT_SHA="$MODE"
  MODE="both"
fi

GITHUB_TOKEN=$(cd /workspace/product && git remote get-url origin | sed 's|https://\(.*\)@github.com.*|\1|')
REPO="STEP-Network/Sensed"
MAX_ATTEMPTS=20
POLL_INTERVAL=15

check_ci() {
  local sha="$1"
  echo "[verify-ci] Checking CI for commit: ${sha:0:7}"
  
  for i in $(seq 1 $MAX_ATTEMPTS); do
    STATUS=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
      "https://api.github.com/repos/$REPO/commits/$sha/status" \
      | jq -r '.state // "unknown"')

    case "$STATUS" in
      success)
        echo "[verify-ci] ✅ CI GREEN (attempt $i)"
        redis-cli -h redis -p 6379 SET "cabinet:layer1:cto:ci-green" 1 EX 300 > /dev/null 2>&1
        return 0
        ;;
      failure|error)
        echo "[verify-ci] ❌ CI FAILED (attempt $i)"
        curl -s -H "Authorization: token $GITHUB_TOKEN" \
          "https://api.github.com/repos/$REPO/commits/$sha/status" \
          | jq '.statuses[] | select(.state != "success") | {context, state, description}'
        return 1
        ;;
      pending|unknown)
        echo "[verify-ci] ⏳ Pending... (attempt $i/$MAX_ATTEMPTS)"
        sleep $POLL_INTERVAL
        ;;
    esac
  done

  echo "[verify-ci] ⚠️ Timed out after $((MAX_ATTEMPTS * POLL_INTERVAL))s"
  return 2
}

check_deploy() {
  local sha="$1"
  echo "[verify-deploy] Checking deploy for commit: ${sha:0:7}"
  
  for i in $(seq 1 $MAX_ATTEMPTS); do
    STATUS=$(curl -s -H "Authorization: token $GITHUB_TOKEN" \
      "https://api.github.com/repos/$REPO/commits/$sha/status" \
      | jq -r '.state // "unknown"')

    case "$STATUS" in
      success)
        echo "[verify-deploy] ✅ Deploy successful (attempt $i)"
        return 0
        ;;
      failure|error)
        echo "[verify-deploy] ❌ Deploy FAILED (attempt $i)"
        curl -s -H "Authorization: token $GITHUB_TOKEN" \
          "https://api.github.com/repos/$REPO/commits/$sha/status" \
          | jq '.statuses[] | select(.state != "success") | {context, state, description, target_url}'
        return 1
        ;;
      pending|unknown)
        echo "[verify-deploy] ⏳ Pending... (attempt $i/$MAX_ATTEMPTS)"
        sleep $POLL_INTERVAL
        ;;
    esac
  done

  echo "[verify-deploy] ⚠️ Timed out after $((MAX_ATTEMPTS * POLL_INTERVAL))s"
  return 2
}

case "$MODE" in
  ci)
    check_ci "$COMMIT_SHA"
    ;;
  deploy)
    check_deploy "$COMMIT_SHA"
    ;;
  both|*)
    check_ci "$COMMIT_SHA" && check_deploy "$COMMIT_SHA"
    ;;
esac
