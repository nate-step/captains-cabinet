#!/bin/bash
# advisor-crew.sh — Advisor-tool beta wrapper for Cabinet Crew tasks
#
# Invokes Anthropic's advisor-tool beta: claude-sonnet-4-6 executor + claude-opus-4-7 advisor.
# Prints synthesized result to stdout. Prints usage summary to stderr. Exits 0 on success.
#
# Usage:
#   bash cabinet/scripts/advisor-crew.sh \
#     --task "Review this migration for Sybil-resistance gaps" \
#     --context shared/interfaces/product-specs/030-earth-map-strava-model.md \
#     --executor claude-sonnet-4-6 \
#     --expected-calls 3 \
#     --officer cto
#
# Flags:
#   --task           REQUIRED — task description string
#   --context        OPTIONAL — path to a context file (injected into user message)
#   --executor       OPTIONAL — executor model (default: claude-sonnet-4-6)
#   --expected-calls OPTIONAL — expected advisor call count; if >=3, enables 5m cache (default: 1)
#   --officer        OPTIONAL — officer name for cost attribution (default: OFFICER_NAME env or "unknown")
#   --max-tokens     OPTIONAL — max tokens for executor response (default: 8192)
#   --dry-run        OPTIONAL — dump request JSON and exit without calling API
#
# Environment:
#   ANTHROPIC_API_KEY    — required (loaded from cabinet/.env if not set)
#   ADVISOR_BETA_VERSION — override beta header (default: advisor-tool-2026-03-01)
#   ADVISOR_MODEL        — override advisor model (default: claude-opus-4-7)
#   OFFICER_NAME         — set automatically in officer sessions; --officer flag overrides
#
# Cost tracking:
#   cabinet:cost:advisor:$OFFICER  — per-officer last-values HSET (24h TTL)
#   cabinet:cost:advisor:daily:$DATE — per-officer daily HSET (48h TTL)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CABINET_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TS_BODY="$SCRIPT_DIR/lib/advisor-crew.ts"

# ────────────────────────────────────────────────────────────
# Load cabinet .env if ANTHROPIC_API_KEY not already set
# ────────────────────────────────────────────────────────────
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -f "$CABINET_DIR/cabinet/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$CABINET_DIR/cabinet/.env"
  set +a
fi

# ────────────────────────────────────────────────────────────
# Validate required environment
# ────────────────────────────────────────────────────────────
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  echo "ERROR: ANTHROPIC_API_KEY is not set. Add it to cabinet/.env or export it in the environment." >&2
  exit 1
fi

# ────────────────────────────────────────────────────────────
# Ensure Node is available
# ────────────────────────────────────────────────────────────
if ! command -v node &>/dev/null; then
  echo "ERROR: node is required but not found in PATH." >&2
  exit 1
fi

# ────────────────────────────────────────────────────────────
# Validate TS body exists
# ────────────────────────────────────────────────────────────
if [ ! -f "$TS_BODY" ]; then
  echo "ERROR: advisor-crew.ts not found at $TS_BODY" >&2
  exit 1
fi

# ────────────────────────────────────────────────────────────
# Run via Bun (preferred — faster TS execution)
# Cabinet containers always have bun; node v22 cannot run .ts natively.
# ────────────────────────────────────────────────────────────
BUN_BIN="${HOME}/.bun/bin/bun"

if [ -x "$BUN_BIN" ]; then
  exec "$BUN_BIN" run "$TS_BODY" "$@"
elif command -v bun &>/dev/null; then
  exec bun run "$TS_BODY" "$@"
else
  echo "ERROR: bun is required to run advisor-crew. Install: curl -fsSL https://bun.sh/install | bash" >&2
  exit 1
fi
