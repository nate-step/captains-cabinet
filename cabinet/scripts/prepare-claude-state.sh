#!/bin/bash
# prepare-claude-state.sh — Pre-bake Claude Code trust state for all officers
#
# Why: Claude Code stores onboarding/trust state in /home/cabinet/.claude.json
# (the FILE in home root, NOT inside .claude/). The current Docker volume mount
# claude-auth:/home/cabinet/.claude/ does NOT persist this file. After every
# image rebuild, all trust dialogs return: "trust this folder?", "completed
# onboarding?", "Channels plugin trust", etc.
#
# This script regenerates .claude.json on every container start with all trust
# fields set, for every officer working directory (officers/<abbrev>) plus the
# Cabinet root. Idempotent — preserves existing fields, only sets/overrides the
# trust ones. Runs as the cabinet user.
#
# Reference: https://docs.claude.com/en/docs/claude-code (article: "Claude Code
# in Docker — Hard-Won Learnings", section 3 "Skipping prompts via pre-baked
# .claude.json").

set -e

CLAUDE_JSON="${HOME:-/home/cabinet}/.claude.json"
CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
OFFICERS_DIR="$CABINET_ROOT/officers"

# Build the list of trusted project paths.
# 1. Cabinet root (some flows cd here directly)
# 2. Each /opt/founders-cabinet/officers/<abbrev>/ — discovered dynamically
PATHS=("$CABINET_ROOT")
if [ -d "$OFFICERS_DIR" ]; then
  for d in "$OFFICERS_DIR"/*/; do
    [ -d "$d" ] && PATHS+=("${d%/}")
  done
fi

# Also include common officer abbreviations even if their dirs don't exist yet —
# the dirs are created lazily by start-officer.sh, but trust must already be
# acknowledged by the time Claude Code launches.
for abbr in cos cto cpo cro coo; do
  candidate="$OFFICERS_DIR/$abbr"
  # Only add if not already in PATHS
  in_list=false
  for p in "${PATHS[@]}"; do
    [ "$p" = "$candidate" ] && in_list=true && break
  done
  $in_list || PATHS+=("$candidate")
done

# Use python3 to merge the trust fields into existing .claude.json (or create
# a new one). Atomic via temp file + rename.
python3 - "$CLAUDE_JSON" "${PATHS[@]}" <<'PYEOF'
import json
import os
import sys
import tempfile

path = sys.argv[1]
project_paths = sys.argv[2:]

# Load existing or start empty
data = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except json.JSONDecodeError:
        # Corrupted file — back it up and start fresh
        os.rename(path, path + ".corrupted")
        data = {}

# Top-level fields that suppress global onboarding/permission prompts
data.setdefault("installMethod", "npm")
data["hasCompletedOnboarding"] = True
data["bypassPermissionsModeAccepted"] = True

# Per-project trust fields
projects = data.setdefault("projects", {})
for p in project_paths:
    proj = projects.setdefault(p, {})
    proj["hasTrustDialogAccepted"] = True
    proj["hasTrustDialogHooksAccepted"] = True
    proj["hasCompletedProjectOnboarding"] = True
    # Don't show "external CLAUDE.md includes" warning
    proj.setdefault("hasClaudeMdExternalIncludesApproved", True)
    proj.setdefault("hasClaudeMdExternalIncludesWarningShown", True)

# Atomic write
tmp = tempfile.NamedTemporaryFile("w", delete=False, dir=os.path.dirname(path) or ".")
try:
    json.dump(data, tmp, indent=2)
    tmp.close()
    os.chmod(tmp.name, 0o600)
    os.replace(tmp.name, path)
except Exception:
    os.unlink(tmp.name)
    raise

print(f"[prepare-claude-state] Trust state set for {len(project_paths)} project paths in {path}")
PYEOF
