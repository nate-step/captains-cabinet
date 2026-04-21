#!/bin/bash
# pre-tool-use.sh — Runs before every tool invocation
# Exit 0 = allow, Exit 2 = block (with reason on stderr).
# Stderr (not stdout) is the operator-visible channel on block; Claude Code's
# hook engine treats stdout as tool-stdout and suppresses it on exit 2, which
# manifests as silent "No stderr output" rejection. FW-022 migrated every
# exit-2 echo path here to `>&2` for this reason — keep new paths the same way.
# Claude Code passes JSON on stdin: { tool_name, tool_input }

# Read JSON from stdin
HOOK_INPUT=$(cat)
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
TOOL_INPUT=$(echo "$HOOK_INPUT" | jq -c '.tool_input // {}' 2>/dev/null)

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

# ============================================================
# 1. KILL SWITCH CHECK
# ============================================================
KILLSWITCH=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
if [ "$KILLSWITCH" = "active" ]; then
  # Allow the command that deactivates the kill switch
  if [ "$TOOL_NAME" = "Bash" ]; then
    CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
    case "$CMD" in
      *"DEL cabinet:killswitch"*|*"del cabinet:killswitch"*)
        exit 0
        ;;
    esac
  fi
  echo "KILL SWITCH ACTIVE — all operations halted by Captain. Send /resume to deactivate." >&2
  exit 2
fi

# ============================================================
# 2. DAILY SPENDING LIMIT CHECK (FW-002)
# ============================================================
# Caps read from instance/config/platform.yml → spending_limits (this Cabinet
# overrides); framework defaults at framework/defaults/spending-limits.yml.
# Any cap key set to 0 disables enforcement for that scope.
#
# Four contracts (all must hold; regressions break the framework for forkers):
#   (a) Every non-zero exit prints a one-line reason to stderr naming the
#       officer, current spend, the cap, and the override path.
#   (b) Telegram reply/react/send-to-group always bypass the gate (subject
#       to a separate hourly sub-cap) so a blocked officer can still DM
#       "I'm over budget, need a raise" instead of going silently dark.
#   (c) Coordinating officer (cos) gets a 3× multiplier on the per-officer
#       cap because trigger routing is structural overhead other officers
#       don't pay. Configurable via coordinating_officer_multiplier.
#   (d) When config or Redis is unreachable, fail-open with a stderr warn.
#       Silent-brick is never acceptable; ambiguous configuration should
#       surface, not disappear.
#
# Source of truth for realized spend: cabinet:cost:tokens:daily:$DATE HSET,
# written by stop-hook.sh from API usage × Opus 4.7 pricing. Legacy
# cabinet:cost:daily:$DATE byte-count estimate is no longer consulted;
# CTO's 14:18 2026-04-17 fix corrected the formula.
#
# Background: shared/cabinet-framework-backlog.md FW-002; incident
# 2026-04-17 — CoS bricked for ~15 min when a cap bit silently.

TODAY=$(date -u +%Y-%m-%d)
OFFICER="${OFFICER:-${OFFICER_NAME:-unknown}}"

# -- Telegram whitelist short-circuit (contract b) --------------------
# A narrow set of user-facing tools must reach the Captain even when the
# officer is otherwise capped. Rate-limited so the whitelist cannot be
# looped-abused.
IS_TELEGRAM_COMMS=0
case "$TOOL_NAME" in
  mcp__plugin_telegram_telegram__reply|mcp__plugin_telegram_telegram__react)
    IS_TELEGRAM_COMMS=1
    ;;
  Bash)
    _CMD_CHECK=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
    # Tight word-boundary match so `my-send-to-group.shrug` can't false-positive
    echo "$_CMD_CHECK" | grep -qE '(^|[[:space:]/])send-to-group\.sh([[:space:]]|$)' && IS_TELEGRAM_COMMS=1
    ;;
esac

# -- Parse caps (fail-open + warn on config trouble, contract d) -------
SPENDING_CONFIG_CACHE="/tmp/cabinet-spending-limits.tsv"
PLATFORM_YML="/opt/founders-cabinet/instance/config/platform.yml"
FRAMEWORK_DEFAULTS_YML="/opt/founders-cabinet/framework/defaults/spending-limits.yml"

# Rebuild cache when either yaml has been touched since last build, the
# cache is missing, OR a yaml that was present at last rebuild has been
# removed (marker file tracks instance presence — without it a deleted
# platform.yml would keep stale instance values in cache indefinitely).
# Instance wins; framework defaults fill the gaps.
_REBUILD=0
_INSTANCE_MARKER="${SPENDING_CONFIG_CACHE}.instance-exists"
if [ ! -f "$SPENDING_CONFIG_CACHE" ]; then
  _REBUILD=1
else
  [ -f "$PLATFORM_YML" ] && [ "$PLATFORM_YML" -nt "$SPENDING_CONFIG_CACHE" ] && _REBUILD=1
  [ -f "$FRAMEWORK_DEFAULTS_YML" ] && [ "$FRAMEWORK_DEFAULTS_YML" -nt "$SPENDING_CONFIG_CACHE" ] && _REBUILD=1
  # yaml disappearance: marker says it existed last time, now it doesn't
  [ -f "$_INSTANCE_MARKER" ] && [ ! -f "$PLATFORM_YML" ] && _REBUILD=1
fi

if [ "$_REBUILD" = "1" ]; then
  if ! python3 - "$PLATFORM_YML" "$FRAMEWORK_DEFAULTS_YML" "$SPENDING_CONFIG_CACHE" <<'PY' 2>/dev/null
import re, sys
instance, default, dst = sys.argv[1], sys.argv[2], sys.argv[3]

def parse(path):
    out = {}
    if not path:
        return out
    try:
        text = open(path).read()
    except FileNotFoundError:
        return out
    in_block = False
    for raw in text.splitlines():
        # Normalize trailing whitespace including CR from CRLF files — without
        # this, "true\r" survives into shell and breaks the `true` check.
        line = raw.rstrip('\r\t ')
        if re.match(r'^spending_limits:\s*$', line):
            in_block = True
            continue
        if in_block:
            # End of block: any top-level key (no leading whitespace) that isn't blank/comment
            if line and not line.startswith((' ', '\t')) and not line.lstrip().startswith('#'):
                break
            m = re.match(r'^\s+([a-z_]+):\s*([^\s#][^#]*?)?\s*(#.*)?$', line)
            if m:
                k = m.group(1)
                v = (m.group(2) or '').strip().rstrip('\r')
                # Strip surrounding quotes
                if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
                    v = v[1:-1]
                out[k] = v
    return out

cfg = parse(default)           # framework defaults first
cfg.update(parse(instance))    # instance overrides wins

with open(dst, 'w') as f:
    for k, v in cfg.items():
        f.write(f"{k}\t{v}\n")
PY
  then
    # Parser crashed (missing python3, broken yaml, permissions on /tmp,
    # whatever). Fail-open with warn — silent-brick is never acceptable
    # (FW-002 contract d).
    echo "pre-tool-use: WARN spending-limits parser failed, using hardcoded framework defaults (\$75/officer, \$300/cabinet)" >&2
  fi
  # Track whether platform.yml existed at the time of this rebuild so a
  # subsequent deletion triggers rebuild instead of leaving stale values.
  if [ -f "$PLATFORM_YML" ]; then
    touch "$_INSTANCE_MARKER" 2>/dev/null
  else
    rm -f "$_INSTANCE_MARKER" 2>/dev/null
  fi
fi

# Read each key with a sane hardcoded fallback (for the case where parsing
# failed entirely and the cache is empty). Fallback values match framework
# defaults so a broken cache still gets forker-safe behavior.
_cfg_get() {
  local key="$1" fallback="$2"
  local v
  v=$(awk -F'\t' -v k="$key" '$1==k{print $2; exit}' "$SPENDING_CONFIG_CACHE" 2>/dev/null)
  [ -z "$v" ] && v="$fallback"
  echo "$v"
}

PER_OFF_CAP_USD=$(_cfg_get daily_per_officer_usd 75)
CABINET_CAP_USD=$(_cfg_get daily_cabinet_wide_usd 300)
COS_MULT=$(_cfg_get coordinating_officer_multiplier 3.0)
TG_WHITELIST_ON=$(_cfg_get telegram_whitelist_enabled true)
TG_HOURLY_CAP=$(_cfg_get telegram_whitelist_hourly_cap 10)

# Coerce non-numeric values to 0 (unlimited) rather than crash. If caps are
# garbage, fail-open + warn.
case "$PER_OFF_CAP_USD" in *[!0-9.]*|'') PER_OFF_CAP_USD=0 ;; esac
case "$CABINET_CAP_USD" in *[!0-9.]*|'') CABINET_CAP_USD=0 ;; esac
case "$COS_MULT" in *[!0-9.]*|'') COS_MULT=1 ;; esac
case "$TG_HOURLY_CAP" in *[!0-9]*|'') TG_HOURLY_CAP=10 ;; esac

# Convert cap USD → cap micro-dollars for integer arithmetic with Redis data.
# awk handles decimals. Result is integer micro-dollars.
PER_OFF_CAP_MICRO=$(awk -v v="$PER_OFF_CAP_USD" 'BEGIN{printf "%.0f", v*1000000}')
CABINET_CAP_MICRO=$(awk -v v="$CABINET_CAP_USD" 'BEGIN{printf "%.0f", v*1000000}')

# CoS carve-out (contract c)
EFFECTIVE_PER_OFF_CAP_MICRO=$PER_OFF_CAP_MICRO
if [ "$OFFICER" = "cos" ] && [ "$PER_OFF_CAP_MICRO" -gt 0 ] 2>/dev/null; then
  EFFECTIVE_PER_OFF_CAP_MICRO=$(awk -v c="$PER_OFF_CAP_MICRO" -v m="$COS_MULT" 'BEGIN{printf "%.0f", c*m}')
fi

# -- If this call is a Telegram comms whitelist tool, apply hourly sub-cap
# only (contract b) and exit 0 without checking the main cap.
if [ "$IS_TELEGRAM_COMMS" = "1" ] && [ "$TG_WHITELIST_ON" = "true" ]; then
  # When OFFICER is empty or unknown, don't enforce the hourly sub-cap —
  # an unknown-officer session sharing one global bucket would false-block
  # Telegram across every misconfigured session at once, recreating the
  # exact "silent-dark" failure FW-002 is meant to prevent. Fail-open + warn.
  if [ -z "$OFFICER" ] || [ "$OFFICER" = "unknown" ]; then
    echo "pre-tool-use: WARN telegram whitelist skipping hourly sub-cap (OFFICER env unset/unknown)" >&2
    _SKIP_MAIN_CAP=1
  else
    _HOUR_BUCKET=$(date -u +%Y%m%d%H)
    _TG_KEY="cabinet:tg-whitelist:${OFFICER}:${_HOUR_BUCKET}"
    _TG_COUNT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" INCR "$_TG_KEY" 2>/dev/null)
    # Set TTL on first hit; subsequent INCRs keep the existing TTL.
    [ "$_TG_COUNT" = "1" ] && redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" EXPIRE "$_TG_KEY" 3900 > /dev/null 2>&1
    if [ -n "$_TG_COUNT" ] && [ "$_TG_COUNT" -gt "$TG_HOURLY_CAP" ] 2>/dev/null; then
      echo "pre-tool-use: BLOCKED — officer=$OFFICER telegram whitelist hourly sub-cap exceeded ($_TG_COUNT > $TG_HOURLY_CAP). Override: instance/config/platform.yml → spending_limits.telegram_whitelist_hourly_cap" >&2
      exit 2
    fi
    # Whitelisted and under sub-cap: skip main-cap enforcement and proceed.
    # Fall through to other sections (kill switch already passed, prohibited
    # actions still checked below, etc.).
    _SKIP_MAIN_CAP=1
  fi
fi

# -- Main cap enforcement (contract a: explicit stderr on every block) --
if [ "${_SKIP_MAIN_CAP:-0}" != "1" ]; then

  # Per-officer cap
  if [ "$EFFECTIVE_PER_OFF_CAP_MICRO" -gt 0 ] 2>/dev/null; then
    OFFICER_COST_MICRO=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "cabinet:cost:tokens:daily:$TODAY" "${OFFICER}_cost_micro" 2>/dev/null)
    OFFICER_COST_MICRO=${OFFICER_COST_MICRO:-0}
    case "$OFFICER_COST_MICRO" in *[!0-9]*|'') OFFICER_COST_MICRO=0 ;; esac
    if [ "$OFFICER_COST_MICRO" -ge "$EFFECTIVE_PER_OFF_CAP_MICRO" ] 2>/dev/null; then
      OFFICER_COST_USD=$(awk -v v="$OFFICER_COST_MICRO" 'BEGIN{printf "%.2f", v/1000000}')
      EFFECTIVE_CAP_USD=$(awk -v v="$EFFECTIVE_PER_OFF_CAP_MICRO" 'BEGIN{printf "%.2f", v/1000000}')
      _NOTE=""
      [ "$OFFICER" = "cos" ] && [ "$(awk -v m="$COS_MULT" 'BEGIN{print (m>1)}')" = "1" ] && _NOTE=" (includes CoS ${COS_MULT}× coordinator multiplier)"
      echo "pre-tool-use: BLOCKED — officer=$OFFICER today=\$$OFFICER_COST_USD cap=\$${EFFECTIVE_CAP_USD}${_NOTE}. Override: instance/config/platform.yml → spending_limits.daily_per_officer_usd (0 = unlimited). Telegram tools still allowed to reach Captain." >&2
      exit 2
    fi
  fi

  # Cabinet-wide cap
  if [ "$CABINET_CAP_MICRO" -gt 0 ] 2>/dev/null; then
    CABINET_COST_MICRO=0
    while IFS= read -r fld; do
      [ -z "$fld" ] && continue
      case "$fld" in *_cost_micro)
        v=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "cabinet:cost:tokens:daily:$TODAY" "$fld" 2>/dev/null)
        v=${v:-0}
        case "$v" in *[!0-9]*|'') v=0 ;; esac
        CABINET_COST_MICRO=$((CABINET_COST_MICRO + v))
        ;;
      esac
    done < <(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HKEYS "cabinet:cost:tokens:daily:$TODAY" 2>/dev/null)
    if [ "$CABINET_COST_MICRO" -ge "$CABINET_CAP_MICRO" ] 2>/dev/null; then
      CABINET_COST_USD=$(awk -v v="$CABINET_COST_MICRO" 'BEGIN{printf "%.2f", v/1000000}')
      CABINET_CAP_USD_PRINT=$(awk -v v="$CABINET_CAP_MICRO" 'BEGIN{printf "%.2f", v/1000000}')
      echo "pre-tool-use: BLOCKED — cabinet-wide today=\$$CABINET_COST_USD cap=\$$CABINET_CAP_USD_PRINT. Override: instance/config/platform.yml → spending_limits.daily_cabinet_wide_usd (0 = unlimited). Telegram tools still allowed to reach Captain." >&2
      exit 2
    fi
  fi
fi
unset _SKIP_MAIN_CAP

# ============================================================
# 3. PROHIBITED ACTIONS
# ============================================================
if [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
  case "$CMD" in
    *"rm -rf /"*|*"rm -rf /*"*)
      echo "BLOCKED: Destructive filesystem operation" >&2
      exit 2
      ;;
    *"docker"*|*"systemctl"*|*"sudo"*)
      echo "BLOCKED: System-level command not permitted" >&2
      exit 2
      ;;
    *"shutdown"*|*"reboot"*|*"halt"*)
      echo "BLOCKED: System control command not permitted" >&2
      exit 2
      ;;
    *"vercel deploy"*|*"vercel --prod"*)
      echo "BLOCKED: Production deployment requires Captain approval" >&2
      exit 2
      ;;
    *"DROP TABLE"*|*"DROP DATABASE"*|*"TRUNCATE"*|*"DELETE FROM"*)
      echo "BLOCKED: Destructive database operation requires Captain approval" >&2
      exit 2
      ;;
  esac
fi

# ============================================================
# 4. CODEBASE OWNERSHIP — Only CTO may modify product code
# ============================================================
if [ "$OFFICER" != "cto" ] && [ "$OFFICER" != "unknown" ]; then
  if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
    FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // empty' 2>/dev/null)
    case "$FILE_PATH" in
      /workspace/product/*)
        echo "BLOCKED: Only CTO can modify the product codebase. Write a spec to shared/interfaces/product-specs/ and notify CTO." >&2
        exit 2
        ;;
    esac
  fi
  if [ "$TOOL_NAME" = "Bash" ]; then
    CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
    case "$CMD" in
      *"git commit"*|*"git push"*|*"git add"*)
        case "$CMD" in
          *"/workspace/product"*|*"cd /workspace/product"*)
            echo "BLOCKED: Only CTO can commit/push to the product codebase. Write a spec and notify CTO." >&2
            exit 2
            ;;
        esac
        ;;
    esac
    # Block common Bash write patterns to product codebase (defense in depth)
    # Two-condition check: command mentions product path AND contains a write operation
    if echo "$CMD" | grep -q '/workspace/product/' && echo "$CMD" | grep -qE '(>\s|sed -i |tee |cp .+ |mv .+ )'; then
      echo "BLOCKED: Only CTO can modify the product codebase via Bash. Write a spec and notify CTO." >&2
      exit 2
    fi
  fi
fi

# ============================================================
# 5. CONSTITUTION PROTECTION
# ============================================================
if [ "$TOOL_NAME" = "Edit" ] || [ "$TOOL_NAME" = "Write" ]; then
  FILE_PATH=$(echo "$TOOL_INPUT" | jq -r '.file_path // .path // empty' 2>/dev/null)
  case "$FILE_PATH" in
    *"constitution/"*)
      echo "BLOCKED: Constitution files are read-only. Propose amendments through the self-improvement loop." >&2
      exit 2
      ;;
    *".env"*)
      echo "BLOCKED: Environment files cannot be modified by Officers" >&2
      exit 2
      ;;
    *"cabinet/docker-compose"*|*"Dockerfile"*)
      echo "BLOCKED: Infrastructure files cannot be modified by Officers" >&2
      exit 2
      ;;
    *"instance/memory/tier2/"*)
      # Officers can only write to their OWN tier2 directory
      if ! echo "$FILE_PATH" | grep -q "instance/memory/tier2/${OFFICER}/"; then
        echo "BLOCKED: Officers can only write to their own tier2 directory (instance/memory/tier2/${OFFICER}/)" >&2
        exit 2
      fi
      ;;
  esac
fi


# ============================================================
# 6. LAYER 1 GATE — CTO must run Crew review before push/merge
# ============================================================
# FW-029: two-phase guard to prevent substring-amplification.
# The old single-regex check matched ANY CMD containing `git push main`
# as a substring — including `git commit -m "...git push main..."`
# heredoc bodies, `echo "git push main"` debug prints, and
# `cat /tmp/log | grep 'git push main'` — each of which CONSUMED the
# cabinet:layer1:cto:reviewed key via the DEL on match, forcing a re-SET
# before the actual push. Same amplification class as FW-028, but with
# state-consumption semantics.
#
# Phase 1 (anchor): CMD must START with a deploy SUBCOMMAND —
#   git push / gh pr / gh api / curl — optionally prefixed by
#   priv-esc / env VAR=X / timeout. Subcommand-level narrowing rejects
#   `git commit`, `git log`, `gh pr view` etc. at Phase 1 so substring
#   action matches on their -m/--grep bodies cannot trip the gate.
# Phase 2 (action regex): actual push-to-main-or-master / pr-merge pattern.
# AND-composed so both must pass to trip the gate.
# Action regex covers BOTH `main` (Sensed product repo) and `master`
# (framework repo default) — CTO pushes to both.
if [ "$OFFICER" = "cto" ] && [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
  if echo "$CMD" | head -n1 | grep -qE '^[[:space:]]*(sudo[[:space:]]+|env([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)+[[:space:]]+|timeout[[:space:]]+[0-9]+[smhd]?[[:space:]]+)*(git[[:space:]]+push|gh[[:space:]]+pr|gh[[:space:]]+api|curl[[:space:]])' && \
     echo "$CMD" | grep -qE 'git push.*(main|master)([[:space:];]|$)|gh pr merge'; then
    REVIEWED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:layer1:cto:reviewed" 2>/dev/null)
    if [ -z "$REVIEWED" ] || [ "$REVIEWED" = "(nil)" ]; then
      echo "LAYER 1 GATE: Spawn a Crew agent to review your diff before pushing/merging. After review, run: redis-cli -h redis -p 6379 SET cabinet:layer1:cto:reviewed 1 EX 300" >&2
      exit 2
    fi
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "cabinet:layer1:cto:reviewed" > /dev/null 2>&1
  fi
fi

# ============================================================
# 7. CI GREEN GATE — CTO must verify CI before merge
# ============================================================
# FW-029: same two-phase guard as Layer 1. Prevents echoes of
# `pulls/N/merge` URLs (in docs, logs, debug prints) from consuming
# the cabinet:layer1:cto:ci-green key. Anchor narrowed to deploy
# subcommand (git push / gh pr / gh api / curl) so `git commit -m
# "...pulls/42/merge..."` bodies cannot pass Phase 1.
if [ "$OFFICER" = "cto" ] && [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
  if echo "$CMD" | head -n1 | grep -qE '^[[:space:]]*(sudo[[:space:]]+|env([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)+[[:space:]]+|timeout[[:space:]]+[0-9]+[smhd]?[[:space:]]+)*(git[[:space:]]+push|gh[[:space:]]+pr|gh[[:space:]]+api|curl[[:space:]])' && \
     echo "$CMD" | grep -qE 'pulls/[0-9]+/merge'; then
    CI_VERIFIED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:layer1:cto:ci-green" 2>/dev/null)
    if [ -z "$CI_VERIFIED" ] || [ "$CI_VERIFIED" = "(nil)" ]; then
      echo "CI GREEN GATE: Run 'bash /opt/founders-cabinet/cabinet/scripts/verify-deploy.sh ci <commit-sha>' and confirm CI is green before merging. After CI passes, run: redis-cli -h redis -p 6379 SET cabinet:layer1:cto:ci-green 1 EX 300" >&2
      exit 2
    fi
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "cabinet:layer1:cto:ci-green" > /dev/null 2>&1
  fi
fi

# ============================================================
# 8. CONTEXT_SLUG VALIDATION + CAPACITY COUPLING (Phase 1 CP2)
# ============================================================
# YAML files at instance/config/contexts/*.yml are source of truth for
# known slugs and their capacity (work|personal). Every tool call that
# writes a context_slug must reference a known slug AND must not cross
# the capacity boundary of the acting officer.
#
# Cache layer: /tmp/cabinet-context-slugs.tsv (slug<TAB>capacity), rebuilt
# when any yaml in the contexts dir is newer than the cache. Keeps the
# hook fast (~1ms) on every call.

CONTEXTS_DIR="/opt/founders-cabinet/instance/config/contexts"
SLUG_CACHE="/tmp/cabinet-context-slugs.tsv"

if [ -d "$CONTEXTS_DIR" ]; then
  # Rebuild cache if stale or missing. Dir mtime covers both file modifications
  # AND deletions (Linux bumps dir mtime on unlink); file-newer covers individual
  # edits. Combined: cache reflects current yaml set even after a deletion.
  if [ ! -f "$SLUG_CACHE" ] \
     || [ -n "$(find "$CONTEXTS_DIR" -maxdepth 0 -newer "$SLUG_CACHE" 2>/dev/null)" ] \
     || [ -n "$(find "$CONTEXTS_DIR" -maxdepth 1 -name '*.yml' -newer "$SLUG_CACHE" 2>/dev/null)" ]; then
    : > "$SLUG_CACHE"
    for f in "$CONTEXTS_DIR"/*.yml "$CONTEXTS_DIR"/*.yaml; do
      [ -f "$f" ] || continue
      # Strip inline # comments, quotes, and surrounding whitespace before capture.
      slug=$(awk -F: '/^slug:/{sub(/[ \t]*#.*$/,"",$2); gsub(/^[ \t]+|[ \t\r\n]+$/,"",$2); gsub(/^["'"'"']|["'"'"']$/,"",$2); print $2; exit}' "$f")
      cap=$(awk -F: '/^capacity:/{sub(/[ \t]*#.*$/,"",$2); gsub(/^[ \t]+|[ \t\r\n]+$/,"",$2); gsub(/^["'"'"']|["'"'"']$/,"",$2); print $2; exit}' "$f")
      [ -n "$slug" ] && [ -n "$cap" ] && printf "%s\t%s\n" "$slug" "$cap" >> "$SLUG_CACHE"
    done
  fi

  # Extract context_slug from tool_input if present (any depth)
  SLUG_IN_CALL=$(echo "$TOOL_INPUT" | jq -r '.context_slug // (..|.context_slug? // empty)' 2>/dev/null | grep -v '^$' | head -1)

  # Also pull from Bash command args (e.g. record-experience.sh --context-slug foo)
  if [ -z "$SLUG_IN_CALL" ] && [ "$TOOL_NAME" = "Bash" ]; then
    BCMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
    SLUG_IN_CALL=$(echo "$BCMD" | grep -oE -- '--context[_-]slug[= ]+[a-z0-9_-]+' | head -1 | awk -F'[= ]' '{print $NF}')
  fi

  if [ -n "$SLUG_IN_CALL" ]; then
    # Validate slug exists in cache
    CTX_CAPACITY=$(awk -F'\t' -v s="$SLUG_IN_CALL" '$1==s{print $2; exit}' "$SLUG_CACHE")
    if [ -z "$CTX_CAPACITY" ]; then
      echo "BLOCKED: unknown context_slug '$SLUG_IN_CALL' — add to instance/config/contexts/<slug>.yml first." >&2
      echo "Known slugs: $(cut -f1 "$SLUG_CACHE" | tr '\n' ' ')" >&2
      exit 2
    fi

    # Cross-capacity enforcement: officer's capacity (from env) must match the context's.
    # OFFICER_CAPACITY defaults to 'work' for the Sensed work preset. Phase 2 will read
    # from preset.yml or per-officer config, not hardcoded default.
    OFFICER_CAPACITY="${OFFICER_CAPACITY:-work}"
    if [ "$OFFICER_CAPACITY" != "$CTX_CAPACITY" ]; then
      echo "BLOCKED: capacity_check failed — officer '$OFFICER' has capacity '$OFFICER_CAPACITY' but context_slug '$SLUG_IN_CALL' has capacity '$CTX_CAPACITY'. Cross-capacity writes are forbidden." >&2
      exit 2
    fi
  fi
fi

# ============================================================
# 9. MCP SCOPE ENFORCEMENT (Phase 1 CP5)
# ============================================================
# cabinet/mcp-scope.yml declares which MCP servers each hired agent may
# reach. On every MCP tool call (tool_name starts with 'mcp__'), the
# hook derives the server name and rejects the call if it is not in the
# acting officer's scope.
#
# Cache: /tmp/cabinet-mcp-scope.tsv (officer\tcsv-of-mcps), rebuilt when
# the yaml is newer than the cache. Same pattern as context cache.

MCP_SCOPE_FILE="/opt/founders-cabinet/cabinet/mcp-scope.yml"
MCP_SCOPE_CACHE="/tmp/cabinet-mcp-scope.tsv"

if [ -f "$MCP_SCOPE_FILE" ] && echo "$TOOL_NAME" | grep -q '^mcp__'; then
  # Rebuild cache if stale. Cache format per line:
  #   agent\tmcp1,mcp2,...
  # Universals from yaml's top-level 'universal:' list are merged into every
  # agent's set at build time, so the hook's membership check stays a single
  # string lookup per tool call.
  if [ ! -f "$MCP_SCOPE_CACHE" ] || [ "$MCP_SCOPE_FILE" -nt "$MCP_SCOPE_CACHE" ]; then
    python3 - "$MCP_SCOPE_FILE" "$MCP_SCOPE_CACHE" <<'PY' 2>/dev/null || true
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
out = []
section = None
cur_agent = None
universals = []
# First pass: collect universals
for line in text.splitlines():
    m = re.match(r'^universal:\s*\[([^\]]*)\]', line)
    if m:
        universals = [x.strip() for x in m.group(1).split(',') if x.strip()]
        break
# Second pass: parse agents/scaffolds
for line in text.splitlines():
    if re.match(r'^(agents|scaffolds):\s*$', line):
        section = line.split(':',1)[0]
        continue
    # Reset section when any other top-level key is hit
    if re.match(r'^[A-Za-z]', line):
        if not re.match(r'^(agents|scaffolds):\s*$', line):
            section = None
        continue
    if section and re.match(r'^  [A-Za-z][A-Za-z0-9_-]*:\s*$', line):
        cur_agent = line.strip().rstrip(':')
        continue
    if cur_agent and re.match(r'^\s+mcps:\s*\[', line):
        mcps_raw = line.split('[',1)[1].split(']',1)[0]
        mcps = [m.strip() for m in mcps_raw.split(',') if m.strip()]
        # Merge universals (deduped, order preserved with agent's own first)
        seen = set(mcps)
        for u in universals:
            if u not in seen:
                mcps.append(u)
                seen.add(u)
        out.append(f"{cur_agent}\t{','.join(mcps)}")
        cur_agent = None
with open(dst, 'w') as f:
    f.write('\n'.join(out) + '\n')
PY
  fi

  # Resolve acting officer
  AGENT_KEY="${OFFICER:-unknown}"
  ALLOWED=$(awk -F'\t' -v a="$AGENT_KEY" '$1==a{print $2; exit}' "$MCP_SCOPE_CACHE" 2>/dev/null)

  # Derive MCP server from tool_name. Formats observed:
  #   mcp__<server>__<tool>                      (e.g. mcp__notion__API-post-page)
  #   mcp__plugin_<server>_<server>__<tool>      (e.g. mcp__plugin_telegram_telegram__reply)
  #   mcp__claude_ai_<Service>__<tool>           (e.g. mcp__claude_ai_Google_Drive__authenticate)
  # Note: assumes single-token server names. Multi-word plugin names
  # (e.g. a hypothetical mcp__plugin_google_drive_google_drive__...) would
  # truncate to 'google' under current parser. None in use today.
  MCP_SERVER=$(echo "$TOOL_NAME" | awk -F'__' '{print $2}')
  case "$MCP_SERVER" in
    plugin_*) MCP_SERVER=$(echo "$MCP_SERVER" | sed 's/^plugin_//' | awk -F'_' '{print $1}') ;;
    claude_ai_*) MCP_SERVER=$(echo "$MCP_SERVER" | sed 's/^claude_ai_//' | tr '[:upper:]' '[:lower:]') ;;
  esac

  if [ -z "$ALLOWED" ]; then
    # Unknown officer — fail-warn (not fail-open, not fail-closed). Hard block
    # would brick hiring flows when a new officer starts before mcp-scope.yml
    # is updated; silent allow hides configuration drift. Warn + allow lets
    # the call through while surfacing the gap for the retro.
    echo "WARN: mcp-scope — officer '$AGENT_KEY' has no entry in cabinet/mcp-scope.yml. Allowing '$MCP_SERVER' call. Add an entry to enforce scope." >&2
  else
    # Check membership
    if ! echo ",$ALLOWED," | grep -qi ",${MCP_SERVER}," ; then
      echo "BLOCKED: MCP scope check — officer '$OFFICER' is not scoped for MCP server '$MCP_SERVER'. Allowed: $ALLOWED. Edit cabinet/mcp-scope.yml to grant access." >&2
      exit 2
    fi
  fi
fi

# ============================================================
# 10. CABINET MCP INTER-CABINET TRUST POLICY (Phase 2 CP4)
# ============================================================
# When a tool call targets the Cabinet MCP (mcp__cabinet__*) AND crosses
# Cabinets (send_message / request_handoff), enforce trust policy from
# instance/config/peers.yml:
#   - target peer must exist in peers.yml
#   - consented_by_captain must be true
#   - the tool must be in that peer's allowed_tools list
#
# Cache: /tmp/cabinet-peers.tsv (peer_id<TAB>consented<TAB>allowed_tools_csv)
# rebuilt when peers.yml is newer than cache (same pattern as CP2 contexts).
#
# Tools that DON'T cross Cabinets (local self-query): identify, presence,
# availability. No peer check for those.

PEERS_FILE="/opt/founders-cabinet/instance/config/peers.yml"
PEERS_CACHE="/tmp/cabinet-peers.tsv"

if [ -f "$PEERS_FILE" ] && echo "$TOOL_NAME" | grep -q '^mcp__cabinet__'; then
  # Rebuild cache if stale
  if [ ! -f "$PEERS_CACHE" ] || [ "$PEERS_FILE" -nt "$PEERS_CACHE" ]; then
    python3 - "$PEERS_FILE" "$PEERS_CACHE" <<'PY' 2>/dev/null || true
import re, sys
src, dst = sys.argv[1], sys.argv[2]
peers = {}
current = None
last_list = None
for line in open(src):
    line = line.rstrip()
    if not line or line.lstrip().startswith('#'):
        continue
    if re.match(r'^peers:\s*$', line):
        continue
    m = re.match(r'^  ([A-Za-z][A-Za-z0-9_-]*):\s*$', line)
    if m:
        current = m.group(1); peers[current] = {}; last_list = None; continue
    if current is None:
        continue
    mk = re.match(r'^\s{4,}([a-z_]+):\s*(.*)$', line)
    if mk:
        k, v = mk.group(1), mk.group(2).strip().strip('"\'')
        if v.startswith('[') and v.endswith(']'):
            peers[current][k] = [x.strip() for x in v[1:-1].split(',') if x.strip()]
            last_list = k
        elif v.lower() in ('true', 'false'):
            peers[current][k] = v.lower() == 'true'; last_list = None
        elif v == '':
            if k == 'allowed_tools':
                peers[current][k] = peers[current].get(k, []); last_list = k
            else:
                peers[current][k] = ''; last_list = None
        elif v:
            peers[current][k] = v; last_list = None
    elif last_list is not None:
        lm = re.match(r'^\s{4,}- (.+)$', line)
        if lm:
            peers[current].setdefault(last_list, []).append(lm.group(1).strip().strip('"\''))
with open(dst, 'w') as f:
    for pid, p in peers.items():
        consented = 'true' if p.get('consented_by_captain') else 'false'
        tools = ','.join(p.get('allowed_tools', []))
        f.write(f"{pid}\t{consented}\t{tools}\n")
PY
  fi

  CABINET_TOOL=$(echo "$TOOL_NAME" | sed 's/^mcp__cabinet__//')

  case "$CABINET_TOOL" in
    send_message|request_handoff)
      TARGET_PEER=$(echo "$TOOL_INPUT" | jq -r '.to_cabinet // empty' 2>/dev/null)
      if [ -z "$TARGET_PEER" ]; then
        echo "BLOCKED: Cabinet MCP $CABINET_TOOL call missing to_cabinet parameter." >&2
        exit 2
      fi
      PEER_LINE=$(awk -F'\t' -v p="$TARGET_PEER" '$1==p{print; exit}' "$PEERS_CACHE" 2>/dev/null)
      if [ -z "$PEER_LINE" ]; then
        echo "BLOCKED: peer '$TARGET_PEER' not declared in instance/config/peers.yml." >&2
        exit 2
      fi
      CONSENTED=$(echo "$PEER_LINE" | cut -f2)
      ALLOWED=$(echo "$PEER_LINE" | cut -f3)
      if [ "$CONSENTED" != "true" ]; then
        echo "BLOCKED: peer '$TARGET_PEER' has consented_by_captain=false. Flip to true in peers.yml after Captain provisions the peer." >&2
        exit 2
      fi
      if ! echo ",$ALLOWED," | grep -q ",$CABINET_TOOL," ; then
        echo "BLOCKED: peer '$TARGET_PEER' allowed_tools does not include '$CABINET_TOOL'. Allowed: $ALLOWED." >&2
        exit 2
      fi
      ;;
  esac
fi

exit 0
