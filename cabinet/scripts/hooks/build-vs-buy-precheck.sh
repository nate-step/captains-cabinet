#!/bin/bash
# cabinet/scripts/hooks/build-vs-buy-precheck.sh — Spec 043 H4
#
# Soft-warn reminder when a Bash command installs a new dependency.
# Captain msg 1963: "Always prefer building our own stuff rather than
# adding dependencies! Unless it is real complex stuff." The pre-check
# fires the moment an install command runs so the officer has a chance
# to pause and reconsider before silently adopting a dep.
#
# Wired as PreToolUse(Bash). Per Spec 043 AC #4 + amendment for scoped-
# package cases. Anti-FW-042: warn-only, never exits non-zero, never
# blocks. The install proceeds; the warn surfaces in the next turn.
#
#   - Env-var disable: BUILD_VS_BUY_HOOK_ENABLED=0
#   - FP-rate logging to cabinet/logs/hook-fires/build-vs-buy-precheck.jsonl
#
# Reversibility: rm this file + drop settings.json registration.

set -u

if [ "${BUILD_VS_BUY_HOOK_ENABLED:-1}" = "0" ]; then
  exit 0
fi

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
LOG_DIR="$REPO_ROOT/cabinet/logs/hook-fires"
LOG_FILE="$LOG_DIR/build-vs-buy-precheck.jsonl"

OFFICER="${OFFICER_NAME:-${CABINET_OFFICER:-unknown}}"
NOW_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

INPUT="$(cat)"
[ -z "$INPUT" ] && exit 0

# Extract command from PreToolUse JSON.
COMMAND="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$COMMAND" ] && exit 0

# Install-command patterns. Per Spec 043 AC #4 amendment, must catch
# scoped packages too (e.g. "npm install --save-dev @scope/pkg").
# Word-boundary anchored so we don't fire on e.g. "ls -la" containing "install" elsewhere.
INSTALL_PATTERNS=(
  '\bnpm[[:space:]]+install\b'
  '\bnpm[[:space:]]+i[[:space:]]'
  '\byarn[[:space:]]+add\b'
  '\bpnpm[[:space:]]+(add|install)\b'
  '\bpip[[:space:]]+install\b'
  '\bpip3[[:space:]]+install\b'
  '\bcargo[[:space:]]+add\b'
  '\bgem[[:space:]]+install\b'
  '\bcomposer[[:space:]]+require\b'
  '\bgo[[:space:]]+get\b'
  '\bbundle[[:space:]]+add\b'
  '\bpoetry[[:space:]]+add\b'
  '\bbrew[[:space:]]+install\b'
)

MATCHED=""
for pat in "${INSTALL_PATTERNS[@]}"; do
  if printf '%s' "$COMMAND" | grep -qE "$pat"; then
    MATCHED="$pat"
    break
  fi
done

[ -z "$MATCHED" ] && exit 0

# Try to extract the package name(s). Heuristic: words after the install
# subcommand that don't start with `-` (flags). Captures @scope/pkg
# correctly because @ is a regular word-character in our pattern.
PKG="$(printf '%s' "$COMMAND" | grep -oE '(install|add|require|get)[[:space:]]+(--?[a-zA-Z-]+[[:space:]]+)*[a-zA-Z0-9@/_.-]+' | head -1 | awk '{print $NF}')"

mkdir -p "$LOG_DIR" 2>/dev/null
LOG_LINE="$(jq -cn \
  --arg ts "$NOW_ISO" \
  --arg officer "$OFFICER" \
  --arg cmd "$COMMAND" \
  --arg pattern "$MATCHED" \
  --arg pkg "$PKG" \
  '{ts:$ts, hook:"build-vs-buy-precheck", officer:$officer, command:$cmd, matched_pattern:$pattern, pkg:$pkg}' 2>/dev/null)"
[ -n "$LOG_LINE" ] && echo "$LOG_LINE" >> "$LOG_FILE"

WARN="BUILD-VS-BUY PRE-CHECK

Detected dependency install: $COMMAND
Package: ${PKG:-<unparsed>}

A3 (Build-our-own > add-dependency, msg 1963): default to native; only
adopt deps when complexity is genuinely prohibitive. Every dep is a
strategic risk that compounds (vendor lock, pricing, deprecation, brand
drift).

The S3 quickdraw at memory/skills/evolved/build-vs-buy-quickdraw.md is the
90-second decision template:
  Q1: is this genuinely complex (multi-month build, regulatory surface,
      brittle edge cases)? → dep is defensible.
  Q2: is this a 1-day native build (cron + script + redis)? → dep is
      overhead, build native.
  Q3: is the dep on the long-term replace list anyway (Linear/Notion class)?
      → consider native now, save the migration cost later.

If you've already run the decision and the dep is defensible: continue.
If you haven't: pause, run the quickdraw, then decide.

Hook: warn-only. Disable via BUILD_VS_BUY_HOOK_ENABLED=0."

jq -n --arg ctx "$WARN" '{additionalContext: $ctx}'
exit 0
