#!/bin/bash
# install-git-hooks.sh — One-time setup for forkers
#
# Activates in-tree git hooks (currently: checkpoint-review pre-commit).
# Run once after cloning:
#   bash cabinet/scripts/install-git-hooks.sh
#
# Idempotent: re-running is safe.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "Not in a git repo — run this from inside the captains-cabinet clone."
  exit 1
}

cd "$REPO_ROOT"
git config core.hooksPath cabinet/scripts/git-hooks

echo "Git hooks installed: core.hooksPath = cabinet/scripts/git-hooks"
echo "Active hooks:"
ls -1 cabinet/scripts/git-hooks/ | sed 's/^/  - /'
echo ""
echo "These hooks fire on every commit and cannot be bypassed except with"
echo "documented override env vars (e.g., COMMIT_NO_REVIEW=1)."
