#!/bin/bash
# sync-framework.sh — Propagate framework-level edits from Work Cabinet to Personal Cabinet.
#
# Captain msg 1848 (2026-04-26): skills shouldn't fragment between Cabinets when they're framework-level.
# Captain ledgers (captain-decisions.md, captain-patterns.md, captain-intents.md) intentionally stay
# separate per Captain msg 1829 — those are per-Cabinet narrative, not framework.
#
# What's framework (synced from Work → Personal):
#   - memory/skills/                    — universal foundation skills + evolved overrides
#   - framework/                        — framework base (constitution, safety boundaries, schemas)
#   - presets/                          — preset definitions (work, personal, _template)
#   - cabinet/scripts/                  — operational scripts
#   - cabinet/scripts/hooks/            — hook scripts
#   - cabinet/mcp-server/               — Cabinet MCP server
#   - cabinet/host-agent/               — host agent
#   - cabinet/admin-bot/                — admin bot
#   - cabinet/channels/                 — channels (redis-trigger-channel, library-mcp)
#
# What's NOT synced (per-Cabinet instance + decision):
#   - shared/interfaces/captain-*.md    — captain ledgers (Captain msg 1829: separate)
#   - shared/interfaces/                — instance artifacts (briefs, specs)
#   - instance/                         — instance config + tier 2 + archive
#   - cabinet/.env                      — secrets per Cabinet
#   - secrets/                          — per-Cabinet credentials
#   - cabinet/docker-compose.yml        — per-Cabinet port mappings, container names
#   - .mcp.json                         — per-Cabinet MCP scope
#
# Run after any framework-level edit in Work. Idempotent (rsync semantics).

set -uo pipefail

WORK="/opt/founders-cabinet"
PERSONAL="/opt/personal-cabinet"

if [ ! -d "$PERSONAL" ]; then
  echo "Personal Cabinet not present at $PERSONAL — nothing to sync."
  exit 0
fi

SYNC_PATHS=(
  "memory/skills/"
  "framework/"
  "presets/"
  "cabinet/scripts/"
  "cabinet/mcp-server/"
  "cabinet/host-agent/"
  "cabinet/admin-bot/"
  "cabinet/channels/"
)

ts() { date -u +"%H:%M:%S"; }

for path in "${SYNC_PATHS[@]}"; do
  src="$WORK/$path"
  dst="$PERSONAL/$path"
  if [ ! -d "$src" ]; then
    echo "[$(ts)] skip (no source): $path"
    continue
  fi
  mkdir -p "$dst"
  rsync -a --delete --omit-dir-times "$src" "$dst" 2>&1 | head -5
done

# Permissions: keep group ownership writable for cabinet group (UID 60001 / GID 60000).
chown -R cabinet-cos:cabinet "$PERSONAL" 2>/dev/null || true
find "$PERSONAL" -type f -exec chmod g+r {} \; 2>/dev/null
find "$PERSONAL" -type d -exec chmod g+rx {} \; 2>/dev/null

echo "[$(ts)] sync-framework.sh: Work → Personal complete."
