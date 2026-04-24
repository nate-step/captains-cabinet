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
    # FW-032: command-start anchor — CMD must START with a recognized
    # invocation form of send-to-group.sh (bash/sh invocation, or direct
    # path exec), optionally prefixed by priv-esc/env VAR=X/timeout.
    # Prior word-boundary match `(^|[[:space:]/])send-to-group\.sh([[:space:]]|$)`
    # allowed `cat /path/send-to-group.sh | head` / `grep send-to-group.sh log`
    # to spuriously set IS_TELEGRAM_COMMS=1, which cascades to _SKIP_MAIN_CAP=1
    # (line 220) — bypassing the per-officer daily spending cap for that call.
    # head -n1 restricts to first line so heredoc bodies cannot trip either.
    # Adversary Finding #1 (Sonnet 2026-04-21 post-EVAL-015): `"?`
    # before/after filename covers double-quoted invocations
    # (`bash "send-to-group.sh"`). Single-quote support skipped because
    # (a) bash single-quoted args don't permit embedded quote escapes and
    # (b) the EVAL-015 extractor parses the anchor out of a single-quoted
    # grep payload and can't tolerate embedded single quotes. Officers
    # using single-quoted paths should switch to double-quoted — documented
    # as FW-036 scope gap.
    echo "$_CMD_CHECK" | head -n1 | grep -qE '^[[:space:]]*(sudo[[:space:]]+|env([[:space:]]+[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+)+[[:space:]]+|timeout[[:space:]]+[0-9]+[smhd]?[[:space:]]+)*(bash[[:space:]]+(-[A-Za-z]+[[:space:]]+)*|sh[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?([^[:space:]]*/)?"?send-to-group\.sh"?([[:space:]]|$)' && IS_TELEGRAM_COMMS=1
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

  # 3a. Literal multi-word / case-sensitive prohibitions — substring match is
  # safe here: these phrases are unlikely to appear inside filenames or grep
  # patterns and are case-sensitive (uppercase SQL verbs, "vercel deploy").
  case "$CMD" in
    *"vercel deploy"*|*"vercel --prod"*)
      echo "BLOCKED: Production deployment requires Captain approval" >&2
      exit 2
      ;;
    *"DROP TABLE"*|*"DROP DATABASE"*|*"TRUNCATE"*|*"DELETE FROM"*)
      echo "BLOCKED: Destructive database operation requires Captain approval" >&2
      exit 2
      ;;
  esac

  # 3b. Word-boundary prohibitions — target must appear in COMMAND POSITION,
  # not as substring inside filenames, grep patterns, or quoted echo strings.
  # FW-042: prior substring match (*"docker"*|*"sudo"*|...) silently blocked
  # legitimate `grep docker file`, `ls docker-compose.yml`, `cat shutdown.md`.
  #
  # Approach (v3.3):
  #  (a) CMD_STRIPPED: remove all `'...'`, `"..."`, `$'...'` spans from CMD, then
  #      strip heredoc bodies (`<<WORD\n...\nWORD`). Eliminates quote/heredoc
  #      mention FPs (`grep -E 'sudo|docker'`, `cat <<EOF\ndocker\nEOF`). Real
  #      direct invocations (`sudo ls`, `{ sudo; }`) survive and are caught by
  #      CMD_PREAMBLE below.
  #  (b) CMD_PREAMBLE on STRIPPED: boundary-char anchor, optional shell reserved
  #      word (then/do/else/elif), optional inline VAR=VAL, then keyword.
  #  (c) SHELL_C_PREAMBLE / SHELL_HERE_PREAMBLE on RAW: detect `bash -c 'sudo'`,
  #      `sh <<< 'docker'` etc. across 10 POSIX shells. Explicit shell-binary
  #      prefix prevents literal `bash -c` inside echo strings from FPing.
  #  (d) WRAPPER_PREAMBLE on RAW: exec|eval|nohup|time|trap|coproc[[ NAME]].
  #      coproc NAME accepts `[A-Za-z_][A-Za-z0-9_]*` (bash identifier). Optional
  #      flags with flag-arg absorber (`[/A-Z][^[:space:]]*` — uppercase/path
  #      values only, avoids swallowing lowercase keyword as value).
  #  (e) ENV_PREAMBLE on RAW (v3.3): dedicated because env's arg surface is too
  #      permissive for WRAPPER's flag-only absorber — env takes arbitrary
  #      lowercase args (`-u foo`, `--unset=PATH`, SQ/DQ VAR=VAL). Generic-token
  #      absorber `[^[:space:]|><;&()}]+` stops at shell metachars so `env |
  #      grep sudo` and `env > file` don't FP.
  #  (f) COMMAND_PREAMBLE on RAW: only `command -p` is exec'ing (`command -v` is
  #      introspection — print type). Dedicated so `command -v sudo` PASSes.
  #  (g) BRACE_AFTER_COMMA: close `{,kw}` empty-first-element brace bypass.
  #      Paired with `\}` inside keyword match + POST_SUFFIX_BRACE (omits `}`)
  #      so `{,docker}-compose.yml` (filename brace prefix) doesn't FP.
  #      Symmetric `{kw,}` caught via POST_SUFFIX's `,` in terminator set.
  #
  # v3.3 closes (from v3.2): heredoc-body strip (E22 FP); POST_SUFFIX comma
  # `{kw,}`; BRACE_AFTER_COMMA `{,kw}`; env/coproc wrappers; A5 filename-brace
  # FP (`ls {,docker}-compose.yml`); env lowercase flag-args (C1/C9);
  # env long-flags C3 + env SQ/DQ VAR=VAL C5; coproc lowercase identifier D2.
  #
  # v3.4 post-adversary (shell-parse + regex dual-pass, 2026-04-23):
  #   H1 — eval 'env sudo ls' bypassed: quoted-arg wipe before WRAPPER keyword.
  #        Fix: EVAL_WRAPPER_PREAMBLE re-enters quoted eval arg. Extended to
  #        env|nohup|exec|time|trap|coproc (broader probe confirmed leak class).
  #   H2 — env \sudo ls bypassed: absorber ate `\sudo` as one token. Fix:
  #        ENV_PREAMBLE absorber excludes `\`; grep branches add `\\?` before kw.
  #   H3 — command -p -- sudo ls bypassed: no `--` absorber. Fix: COMMAND_PREAMBLE
  #        now absorbs `(--[[:space:]]+)?` after optional `-p`.
  #   H4 — {rm,} -rf / bypassed: rm block only caught `{,rm}` form. Fix: symmetric
  #        `(^|anchor)\{rm,+\}[[:space:]]+-rf` branch added. sudo/shutdown blocks
  #        already catch via POST_SUFFIX comma terminator.
  #   BUG 2 — bash -xc/-vc/-ec/-lc/-ic/-xec/--login -c/--norc -c bypassed:
  #        SHELL_C flag absorber ate `-xc` as single flag, swallowing c-marker.
  #        Fix: absorber excludes ANY short flag containing `c`, adds `--[A-Za-z]`
  #        long-flag absorber. c-marker = single-dash cluster with at least one
  #        `c` anywhere (covers all 9 variants).
  #   PARITY — SHELL_HERE (`bash --login <<<`) same single-dash-only absorber
  #        limitation. Fix: added `--[A-Za-z]` long-flag to SHELL_HERE_PREAMBLE
  #        absorber (no c-marker since `<<<` itself is the trigger).
  #
  # v3.5 post-adversary (shell-parse + regex dual-pass #2, 2026-04-23):
  #   BUG-1 (regex HIGH) — `bash -C -c 'sudo'` bypassed: SHELL_C absorber range
  #        `[ABD-Z]` excluded uppercase-C (range letter-math), so `-C -c` not
  #        recognized as absorber+c-marker. Fix: widen to `[A-Zabd-z0-9]` (A-Z
  #        full, lowercase excludes `c` only).
  #   BUG-2 (regex HIGH) — `eval "env 'sudo' ls"`, `eval "nohup \"sudo\" ls"`:
  #        quoted keyword inside wrapper arg. LEAD_PREFIX `['"]?\\*` couldn't
  #        eat nested escape-quote `\"` or interleaved `'\`. Fix: LEAD_PREFIX
  #        widened to `(\\|['"])*` — any order/count of backslash+quote chars.
  #        Also POST_SUFFIX_Q adds `\` for trailing `\"` after keyword.
  #   BUG-3 (regex MED) — `\eval 'sudo'`, `\nohup sudo`, `\env sudo`: leading
  #        backslash before wrapper name. Shell treats `\eval` as `eval` (no-op
  #        escape on non-special char). Fix: all preambles prefix with `\\*`.
  #   BUG-4 (regex MED) — `eval 'env 2>/dev/null sudo'`, `eval 'nohup 2>&1 reboot'`:
  #        redirect inside eval-quoted arg. EVAL_WRAPPER absorber excluded `><&`,
  #        couldn't eat `2>/dev/null` or `2>&1`. Fix: remove `><&` from absorber
  #        exclusion — allow redirect/background chars. Same applied to ENV.
  #   H1 (shell-parse HIGH) — `bash <<EOF\nsudo\nEOF`: heredoc body untouched by
  #        strip (preserved for CMD_STRIPPED), but body content fed to shell is
  #        direct invocation path. Fix: SHELL_HEREDOC_PREAMBLE detects
  #        `bash/sh/... <<WORD`, then perl multiline scan of body for keyword.
  #   H2 (shell-parse HIGH) — `eval 'eval sudo ls'`: double-eval nesting; outer
  #        EVAL_WRAPPER inner wrapper list omitted `eval` itself. Fix: added
  #        `eval` to inner wrapper alternation.
  #   H3 (shell-parse HIGH) — `eval 'bash -c sudo ls'`: eval of shell command.
  #        Inner wrapper list omitted shell binaries. Fix: added
  #        `bash|sh|dash|zsh|ksh` to inner wrapper alternation.
  #   BUG-5 (regex HIGH, v3.5 round 2) — `eval "exec 'rm' -rf /"`: quoted binary
  #        name splits `rm -rf /` token sequence. Fix: rm EVAL_WRAPPER branch
  #        uses `[[:space:]'"\\]+` interstitial class (accepts quote/backslash
  #        between rm→-rf→/).
  #
  # v3.6 post-adversary (shell-parse + regex dual-pass #3, 2026-04-24):
  #   B4 (HIGH) — `bash <<<sudo` (bare, no quote) bypassed: SHELL_HERE_PREAMBLE
  #        required quote after `<<<`. Fix: `['"]` → `['"]?` (quote optional).
  #   B5 (HIGH) — `/usr/bin/sudo`, `/sbin/reboot`, `/bin/rm -rf /`: full-path
  #        invocation. All 7 keywords affected. Fix: PATH_PREFIX variable
  #        `((/[^[:space:]/]+)+/)?` applied as optional prefix in all 24 grep
  #        branches (3 kw groups × 8 paths). CMD_PREAMBLE anchor excludes bare
  #        space so arg-position `echo /usr/bin/sudo` doesn't FP.
  #   B6 (HIGH) — `bash --rcfile FILE -c 'sudo'`, `--init-file FILE`: long-flag
  #        takes argument. Old SHELL_C/SHELL_HERE/SHELL_HEREDOC absorbers only
  #        matched `--[a-z]+` without arg. Fix: optional value absorber
  #        `([[:space:]]+[^-][^[:space:]]*)?` after each long flag.
  #   B7/B8/B9 (HIGH) — `rm -fr /`, `rm -f -r /`, `rm --recursive --force /`:
  #        flag-order variants bypassed literal `-rf` match. Fix: RM_FLEX pattern
  #        requires rm + at least one recursive-indicator flag (r/R in short
  #        cluster, or --recursive long) + trailing `/`. Catches all 8 flag
  #        permutations while rejecting non-recursive `rm file.txt`.
  #   B10 (HIGH) — `{,sudo,}` trailing comma: BRACE_AFTER_COMMA required `\}`
  #        immediately after kw. Fix: `(kw)\}` → `(kw),*\}` (allow trailing
  #        commas before close brace).
  #   BYPASS 2 (HIGH) — `eval '(sudo)'`, `eval '{ sudo; }'`, `eval '! sudo ls'`:
  #        subshell/brace-group/negation operators inside eval's quoted arg.
  #        EVAL_WRAPPER inner wrapper list missed `(`, `{`, `!`. Fix: added
  #        `[({!]` to wrapper alternation + post-wrapper `[[:space:]]+` →
  #        `[[:space:]]*` (subshell-open doesn't require following space).
  #   BYPASS 4 (MED) — `mksh -c 'sudo'`, `ash`, `fish`, `csh`, `tcsh`, `busybox`:
  #        shell binary enumeration gap. Fix: extended SHELL_C/SHELL_HERE/
  #        SHELL_HEREDOC/EVAL_WRAPPER shell list to 11 shells.
  #
  # Accepted gaps (uncommon, all tracked):
  #   - redirect prefix: `>/dev/null sudo`, `2>&1 sudo`
  #   - xargs wrapper:   `echo x | xargs sudo` (dataflow-decoupled, FW-040 Phase B)
  #   - timeout wrapper: `timeout 10 sudo`
  #   - process subst:   `<(sudo ...)` / `source <(echo sudo ...)`
  #   - bare `$'reboot'` (ANSI-C as command) — stripped, no match
  #   - variable expansion: `X=sudo; $X ls` (FW-040 Phase B)
  #   - stdin-read shells: `bash <<<"cmd"` outer (string-input form caught; body
  #     path is FW-040 Phase B class)
  #   - `{,sudo}}` double-brace-close: bash PARSE-ERROR (not executable);
  #     empirically verified via `bash -c '{,echo}} MAGIC_OK'` → `}: command not
  #     found`. Classified SCOPE_GAP, not BUG; regex-adv confirmed non-exploitable.

  # v3.7.2 BSQ fix: normalize backslash-escaped quotes (`\"` → `"`, `\'` → `'`)
  # in the input string. Defeats backslash-escape quoted-splice class bypass
  # (COO Pass-1 on 716fb96): `echo hi;\"sudo\" ls`, `(\"sudo\" ls)`, etc. all
  # bypassed HAS_SPLICE because the `\` between boundary and quote hides the
  # quote-adjacent-letter structural signal that HAS_SPLICE detects. Bash
  # treats `\"` in unquoted context as literal `"`, so normalizing to `"`
  # preserves bash exec semantics for attack inputs (adjacent-quote concat
  # still fuses the token at runtime) while restoring the detectable splice
  # signal for our regex. Applied once; CMD_STRIPPED, CMD_UNQUOTED, CMD_MASKED
  # all derive from CMD_NORM so no surface is missed.
  CMD_NORM=$(printf '%s' "$CMD" | sed -e 's/\\"/"/g' -e "s/\\\\'/'/g")

  # (a) Strip data-context quotes. sed -e runs each independently to survive
  #     malformed quotes. Order: \$'...' then '...' then "...". Double-quote
  #     strip preserves spans containing `$` or backtick (code-substitution
  #     context) so `"$(sudo)"` and `"$(`sudo`)"` survive for RAW scans.
  # v3.3: perl pipe strips `<<WORD\n...\nWORD` heredoc bodies — their content is
  # always data, never a direct invocation. Fixes E22 FP (`cat <<EOF\ndocker...\nEOF`).
  CMD_STRIPPED=$(printf '%s' "$CMD_NORM" \
    | sed -e "s/\\\$'[^']*'//g" -e "s/'[^']*'//g" -e 's/"[^"$`]*"//g' \
    | perl -0777 -pe 's/<<([A-Za-z_]\w*)\n.*?\n\1(?=\n|\z)//gs')

  # v3.7 post-adversary Finding 2 fix: CMD_UNQUOTED preserves the CONTENT of quoted
  # spans (unwraps them) instead of wiping them. Defeats quoted-token splice like
  # `"sudo" ls`, `s"udo" ls`, `"su""do" ls`, `s'udo' ls` — adjacent-quote concat is
  # a POSIX word-splicing feature; bash emits the fused literal. Scanned against
  # STRICT_KW_START (boundary-only, no VAR= absorber) so we don't FP on
  # `echo "sudo ls"` (kw preceded by space, not by operator boundary).
  CMD_UNQUOTED=$(printf '%s' "$CMD_NORM" \
    | sed -e "s/\\\$'\\([^']*\\)'/\\1/g" -e "s/'\\([^']*\\)'/\\1/g" -e 's/"\([^"$`]*\)"/\1/g' \
    | perl -0777 -pe 's/<<([A-Za-z_]\w*)\n.*?\n\1(?=\n|\z)//gs')

  # Unquoted-context preamble (runs on STRIPPED). Anchor includes backtick so
  # `` `sudo` `` and `$(`sudo`)` are caught post-strip.
  # v3.7 post-adversary Finding 1 fix: absorber now accepts leading/interleaved
  # redirects (`2>&1`, `>/dev/null`, `<&0`) at command-position. Adversary proved
  # `2>&1 sudo ls`, `echo hi; 2>&1 sudo ls`, `echo hi && 2>&1 reboot` bypassed
  # CMD_PREAMBLE because `2>&1` sits between boundary+space and kw but wasn't
  # consumed by the VAR= absorber. New absorber alt: `[0-9]*[<>]+[&0-9-]*[^[:space:]]*`
  # covers `N>FILE`, `N<FILE`, `N>&M`, `>FILE`, `<FILE`, `>&-`, `&>FILE` forms.
  CMD_PREAMBLE='(^|[;&|({)}`!][[:space:]]*|(^|[;&|({)}`!])[[:space:]]*(then|do|else|elif|if|while|until|for|case|select|function)[[:space:]]+)[[:space:]]*(([0-9]*[<>]+[&0-9-]*[^[:space:]]*|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+)*'

  # v3.7 post-adversary: strict command-start anchor for CMD_UNQUOTED scans.
  # Only operator boundaries — no VAR= absorber, no reserved-word prefix, no
  # redirect absorber. Reason: CMD_UNQUOTED already rewrote quote-content in
  # place; kw at strict cmd-start after unwrap means adversary quoted-splice,
  # not legitimate arg. Space NOT in leading class — prevents FP on
  # `echo "sudo ls"` (unwrap → `echo sudo ls`, space-preceded kw).
  STRICT_KW_START='(^|[;&|({)}`!]|&&|\|\|)[[:space:]]*'

  # HAS_SPLICE gate: STRICT_KW_START scans CMD_UNQUOTED, but UNQUOTED also
  # exposes kw inside DATA-position quotes like `grep '|docker|' file` (the
  # `|` inside the regex string matches STRICT_KW_START's `|` boundary).
  # HAS_SPLICE detects the adversary splice signal specifically: a
  # command-position token whose body crosses a quote boundary — `"sudo"`,
  # `s"udo"`, `"s"udo`. Such tokens always appear at boundary-then-quote-or-
  # letter-then-quote positions. Data-position quotes (preceded by space,
  # never by operator) don't match this pattern. STRICT_KW_START runs only
  # if HAS_SPLICE=1 — else we stay on CMD_STRIPPED's existing gates.
  #
  # v3.7.1 post-review fix (BUG-A): HAS_SPLICE runs on CMD_MASKED (quoted
  # interiors replaced with literal `x`) rather than raw CMD. Raw CMD exposes
  # boundary chars (|, &, ;) inside quoted strings, falsely triggering the
  # splice signal on `grep -E "foo|docker" file`. CMD_MASKED keeps the outer
  # quotes so letter-adjacent-quote / quote-adjacent-letter patterns at true
  # command position still match, but interior pipes/ampersands become `x`
  # and stop false-triggering the boundary class.
  CMD_MASKED=$(printf '%s' "$CMD_NORM" \
    | sed -e "s/\\\$'[^']*'/\$'x'/g" -e "s/'[^']*'/'x'/g" -e 's/"[^"$`]*"/"x"/g')
  HAS_SPLICE=0
  if echo "$CMD_MASKED" | grep -qE "(^|[;&|({)}\`!]|&&|\|\|)[[:space:]]*([A-Za-z_]+['\"\`]|['\"\`][A-Za-z_])"; then
    HAS_SPLICE=1
  fi

  # Shell-wrapper quoted-code paths (runs on RAW). Shell-binary anchor prevents
  # literal `-c` substrings in echo args from FPing.
  # v3.4 BUG 2 fix: compound-flag bypass (bash -xc 'sudo', -lc, -xec, --login -c).
  # Old absorber `(-[A-Za-z][A-Za-z0-9-]*)*` ate `-xc` as one flag, swallowing the
  # c-marker. New: short-flag absorber excludes ANY cluster containing `c`, long
  # flag absorber added for `--login`/`--norc`. c-marker = single-dash cluster
  # with at least one `c` anywhere (covers `-c`, `-xc`, `-cx`, `-xec`, `-lc`).
  # v3.4 edge: `\\*` before wrapper name catches `\bash -c '\sudo'` escape forms.
  SHELL_C_PREAMBLE='(^|[;&|({)}`!]|[[:space:]])[[:space:]]*\\*(bash|sh|dash|zsh|ksh|mksh|ash|fish|csh|tcsh|busybox|su|runuser|script)[[:space:]]+((-[A-Zabd-z0-9][A-Zabd-z0-9-]*([[:space:]]+[^-][^[:space:]]*)?|--[A-Za-z][A-Za-z0-9-]*(=[^[:space:]]*)?([[:space:]]+[^-][^[:space:]]*)?)[[:space:]]+)*-[A-Za-z0-9]*c[A-Za-z0-9]*[[:space:]]*\$?['\''"]?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=([^[:space:]'\''"]|'\''[^'\'']*'\''|"[^"]*"|\$'\''[^'\'']*'\'')*[[:space:]]+)*'
  # v3.4 parity fix: `bash --login <<<'sudo ls'` bypassed old single-dash-only
  # absorber. Added long-flag absorber for `<<<` path. No c-marker needed — `<<<`
  # itself triggers execution.
  SHELL_HERE_PREAMBLE='(^|[;&|({)}`!]|[[:space:]])[[:space:]]*\\*(bash|sh|dash|zsh|ksh|mksh|ash|fish|csh|tcsh|busybox|su|runuser|script)[[:space:]]+((-[A-Za-z][A-Za-z0-9-]*([[:space:]]+[^-][^[:space:]]*)?|--[A-Za-z][A-Za-z0-9-]*(=[^[:space:]]*)?([[:space:]]+[^-][^[:space:]]*)?)[[:space:]]+)*<<<[[:space:]]*\$?['\''"]?[[:space:]]*'

  # Wrapper keywords that ALWAYS execute (exec|eval|nohup|time|trap). Optional
  # flags between wrapper and keyword. Optional quote opener for `trap "reboot"`.
  # v3.7 timeout/duration fix: wrappers like `timeout 30s sudo ls`, `timeout -k 5s 30s
  # sudo ls` have positional non-flag args between wrapper and target keyword. Added
  # `[0-9]+[A-Za-z]*` absorber alt for duration-style tokens (30s, 5m, 1h, 100).
  # v3.7 long-flag + positional fix: chroot /, taskset 0x1, numactl --physcpubind=0.
  # Added `--[A-Za-z][A-Za-z0-9-]*(=[^[:space:]]*)?` for long flags and broad
  # `[^-][^[:space:]]*` for bare positional args. Grep backtracking ensures bare-pos
  # doesn't greedy-eat target kw (eval sudo ls → iter 0 match wins).
  WRAPPER_PREAMBLE='(^|[;&|({)}`!]|[[:space:]])[[:space:]]*\\*(exec|eval|nohup|time|trap|coproc([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)?|setsid|stdbuf|nice|ionice|chrt|taskset|unbuffer|cgexec|doas|pkexec|gosu|su-exec|strace|ltrace|gdb|valgrind|watch|chroot|timeout|numactl)[[:space:]]+((-[A-Za-z][A-Za-z0-9-]*([[:space:]]+[^-][^[:space:]]*)?|--[A-Za-z][A-Za-z0-9-]*(=[^[:space:]]*)?([[:space:]]+[^-][^[:space:]]*)?|[0-9]*[<>]+[&0-9-]*[^[:space:]]*|[0-9]+[A-Za-z]*|[^-][^[:space:]]*)[[:space:]]+)*\$?['\''"]?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=([^[:space:]'\''"]|'\''[^'\'']*'\''|"[^"]*"|\$'\''[^'\'']*'\'')*[[:space:]]+)*'

  # v3.3 env-dedicated preamble. env takes flag-args (-u VAR, -C DIR, -S STR),
  # long flags (--unset=PATH), quoted VAR=VAL, and the cmd-to-run. Generic-token
  # absorber stops at shell metachars (|, >, <, ;, &, (, ), }) so that
  # `env | grep sudo` and `env > file` don't FP.
  # v3.4 H2 fix: `env \sudo ls` bypassed because absorber ate `\sudo` as one
  # token. `\sudo` = `sudo` in bash (backslash quotes next char, no-op on `s`).
  # Absorber token now excludes `\` so `\keyword` forms surface to the keyword
  # match. Each token can optionally start with `\`. Keyword match uses `\\?`
  # prefix (added in grep branches, not here) to consume the leading backslash.
  ENV_PREAMBLE='(^|[;&|({)}`!]|[[:space:]])[[:space:]]*\\*env[[:space:]]+(\\*[^[:space:]|;()}\\]+[[:space:]]+)*'

  # `command` wrapper: only `-p` flag executes; `-v`/`-V` are introspection
  # (resolve path, print type). Dedicated regex allows only `-p` to avoid
  # FPing `command -v sudo` (standard "does sudo exist?" query).
  # v3.4 H3 fix: `command -p -- sudo ls` bypassed because old regex had no `--`
  # absorber. `--` is POSIX end-of-options; `command -p -- sudo` still executes
  # sudo. Added `(--[[:space:]]+)?` after `(-p[[:space:]]+)?` — also covers
  # `command -- sudo` (no -p, still exec).
  COMMAND_PREAMBLE='(^|[;&|({)}`!]|[[:space:]])[[:space:]]*\\*command[[:space:]]+(-p[[:space:]]+)?(--[[:space:]]+)?\$?['\''"]?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=([^[:space:]'\''"]|'\''[^'\'']*'\''|"[^"]*"|\$'\''[^'\'']*'\'')*[[:space:]]+)*'

  # v3.4 H1 fix: nested eval+wrapper class. `eval 'env sudo ls'`, `eval 'nohup
  # sudo'`, `eval 'exec sudo'`, `eval 'time sudo'` all bypass both CMD_STRIPPED
  # (quoted content wiped) and WRAPPER_PREAMBLE (keyword slot sees the nested
  # wrapper, not the target). Dedicated regex re-enters the eval-quoted arg to
  # match wrapper + target keyword. Quote optional so `eval env sudo ls`
  # (unquoted) also caught.
  EVAL_WRAPPER_PREAMBLE='(^|[;&|({)}`!]|[[:space:]])[[:space:]]*\\*eval[[:space:]]+(-[A-Za-z][A-Za-z0-9-]*[[:space:]]+)*\$?['\''"]?[[:space:]]*\\*(eval|bash|sh|dash|zsh|ksh|mksh|ash|fish|csh|tcsh|busybox|env|nohup|exec|time|trap|coproc([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)?|command|builtin|setsid|stdbuf|nice|ionice|chrt|taskset|unbuffer|cgexec|doas|pkexec|gosu|su-exec|strace|ltrace|gdb|valgrind|watch|chroot|timeout|numactl|su|runuser|script|[({!])[[:space:]]*(\\*[^[:space:]|;()}\\'\''"]+[[:space:]]+)*'

  # v3.7 eval-compound fix: `eval 'echo ok; sudo ls'` — eval's quoted arg has a
  # compound statement with boundary (`;`/`&`/`|`) separating a benign first kw
  # from the target kw. Pattern re-enters the eval arg, consumes up to a boundary
  # char, then matches kw at that compound-position.
  EVAL_COMPOUND_PREAMBLE='(^|[;&|({)}`!]|[[:space:]])[[:space:]]*\\*eval[[:space:]]+\$?['\''"][^'\''"]*[;&|]+[[:space:]]*'

  # v3.7 env-S fix: `env -S'sudo ls'` — env's -S flag takes a split-string arg
  # that env re-parses internally. Attacker glues `-S` to quoted kw with no
  # space, hiding kw from token absorber. Branch matches env, optional prior
  # flags/VAR= assignments, literal -S, optional space, quote, LEAD_PREFIX, kw.
  ENV_S_PREAMBLE='(^|[;&|({)}`!]|[[:space:]])[[:space:]]*\\*env[[:space:]]+((-[A-Za-z][A-Za-z0-9-]*([[:space:]]+[^-][^[:space:]]*)?|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*)[[:space:]]+)*-S[[:space:]]*['\''"][[:space:]]*'

  # Post-suffix: unquoted (stripped) + quoted (raw). Both include backtick
  # closing for command-substitution spans.
  POST_SUFFIX='([[:space:];&|)},<>`]|$)'
  POST_SUFFIX_Q='([[:space:];&|)},<>'\''"`\\]|$)'
  # v3.3 A5 fix: POST_SUFFIX_BRACE omits `}` so that `{,docker}-compose.yml`
  # (filename brace prefix) doesn't FP. Paired with `\}` inside the keyword
  # match so BRACE branches require the closing brace immediately after kw.
  POST_SUFFIX_BRACE='([[:space:];&|)<>,`'\''"]|$)'

  # v3.3: BRACE_AFTER_COMMA closes `{,kw}` brace-expansion bypass — empty first
  # element followed by keyword (e.g. `{,sudo}` runs sudo). POST_SUFFIX adds `,`
  # to close `{kw,}` symmetric form.
  # v3.7 nested-brace fix: `{,{,sudo}}` bypassed single-level BRACE_AFTER_COMMA.
  # Widened to `(\{,+)+` for 1+ empty-leading brace levels. Each branch's closing
  # pattern also widened from `,*\}` to `(,*\})+` for balanced depth.
  BRACE_AFTER_COMMA='(^|[;&|({)},`!]|[[:space:]])(\{,+)+'

  # v3.5 H1 fix: unquoted heredoc bypass — `bash <<EOF\nsudo ls\nEOF` escaped
  # all prior blocks because (a) CMD_STRIPPED strips heredoc body (correct FP
  # avoidance for `cat <<EOF\ndocker\nEOF`), (b) no preamble ran on RAW body,
  # (c) `bash` is not a prohibited keyword. SHELL_HEREDOC_PREAMBLE detects
  # `<shell> <flags>* <<WORD` leader. Then perl multiline scan inspects body
  # between delimiter lines for target kws (including `rm -rf`). Only unquoted
  # `<<WORD` (starts with `[A-Za-z_]`) triggers — quoted `<<'EOF'`, `<<"EOF"`,
  # dash-strip `<<-EOF` all correctly leave body un-stripped, caught by
  # CMD_PREAMBLE on CMD_STRIPPED.
  SHELL_HEREDOC_PREAMBLE='(^|[;&|({)}`!]|[[:space:]])[[:space:]]*\\*(bash|sh|dash|zsh|ksh|mksh|ash|fish|csh|tcsh|busybox|su|runuser|script)[[:space:]]+((-[A-Zabd-z0-9][A-Zabd-z0-9-]*([[:space:]]+[^-][^[:space:]]*)?|--[A-Za-z][A-Za-z0-9-]*(=[^[:space:]]*)?([[:space:]]+[^-][^[:space:]]*)?)[[:space:]]+)*<<[[:space:]]*[A-Za-z_]'
  if echo "$CMD" | grep -qE "$SHELL_HEREDOC_PREAMBLE"; then
    if echo "$CMD" | perl -0777 -ne '
      exit 0 if /<<[A-Za-z_]\w*\n(.*?)\n[A-Za-z_]\w*(?=\n|\z)/s &&
                $1 =~ /(?:^|[;&|({)}`!]|\s)\s*(?:sudo|docker|systemctl|shutdown|reboot|halt|rm\s+-rf)\b/m;
      exit 1;
    '; then
      echo "BLOCKED: Heredoc to shell binary contains prohibited command" >&2
      exit 2
    fi
  fi

  # v3.5: LEAD_PREFIX — 0+ chars, each either a backslash or a quote (' or ").
  # Handles three bypass classes:
  #   BUG-2: `eval "env 'sudo' ls"` — quoted keyword inside eval arg. Token
  #          absorbers exclude `'`/`"`, so a quoted keyword escapes the absorber
  #          but arrives at keyword-match position prefixed with a quote that
  #          the literal keyword cannot consume.
  #   BUG-2 nested: `eval "nohup \"sudo\" ls"` — escape+quote interleave.
  #          Alternation eats any mix of `\`, `'`, `"`.
  #   H2 extended: `env \\sudo ls` — multiple backslashes before kw.
  # POST_SUFFIX_Q also extended with `\` for trailing escape (e.g. `sudo\" ls`).
  # Applied as prefix to keyword match in every RAW grep branch. Safe (won't FP
  # on bare kw — outer preamble already anchored in command position).
  LEAD_PREFIX='(\\|['\''"])*'

  # v3.6: PATH_PREFIX — optional absolute-path prefix before keyword (e.g.
  # `/usr/bin/sudo`, `/sbin/reboot`). Applied as optional prefix in all branches
  # so `/usr/bin/sudo ls` blocks same as `sudo ls`. Leading `/` required (no
  # relative paths — those would FP on `./grep sudo` etc). Intermediate
  # segments disallow whitespace and `/`. Trailing `/` connects to keyword.
  PATH_PREFIX='((~[A-Za-z0-9_+-]*)?/+([^[:space:]/]+/+)*)?'

  # v3.6: RM_FLEX — flexible rm-destructive pattern. Catches v3.5's literal
  # `-rf` PLUS flag-order variants (-fr, split -f -r, long --recursive/--force).
  # Logic: rm, optional interstitial flags, mandatory flag containing r or R
  # (or --recursive), optional trailing flags, slash target. At least one r-flag
  # required — plain `rm /path` (non-recursive) doesn't match. Ends at `/`;
  # per-branch suffix controls what follows (strict end for STRIPPED, lax quote
  # for RAW).
  RM_FLEX='rm[[:space:]]+((-[[:alnum:]]+|--[[:alnum:]-]*(=[^[:space:]]*)?)[[:space:]]+)*(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)([[:space:]]+(-[[:alnum:]]+|--[[:alnum:]-]*(=[^[:space:]]*)?))*[[:space:]]+/'
  # v3.7 H11 fix: `rm -rf "/"` — CMD_STRIPPED wipes the quoted "/" entirely so
  # the slash vanishes before RM_FLEX scans. RM_FLEX_QS targets CMD (raw) and
  # tolerates quote chars wrapping the slash (`"/", '/', `/`).
  # v3.7.1 post-review fix (BUG-B): terminal constraint `\**['"`]*([space];&|)]|$)`
  # so pattern matches only when `/` is FOLLOWED by optional `*`, optional closing
  # quote(s), then terminator/end. Prevents FP on legitimate `rm -rf '/tmp/build'`
  # where the slash begins a non-root path. Still matches `rm -rf "/"`, `rm -rf '/'`,
  # `rm -rf "/*"`, `rm -rf '/' && echo done`.
  RM_FLEX_QS='rm[[:space:]]+((-[[:alnum:]]+|--[[:alnum:]-]*(=[^[:space:]]*)?)[[:space:]]+)*(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)([[:space:]]+(-[[:alnum:]]+|--[[:alnum:]-]*(=[^[:space:]]*)?))*[[:space:]]+['\''"`]+/\**['\''"`]*([[:space:];&|)]|$)'

  # Destructive filesystem: rm with recursive flag targeting / (+ flag-order variants)
  if echo "$CMD_STRIPPED" | grep -qE "${CMD_PREAMBLE}${PATH_PREFIX}${RM_FLEX}(\*|[[:space:]]|$)" \
     || echo "$CMD" | grep -qE "${SHELL_C_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}${RM_FLEX}" \
     || echo "$CMD" | grep -qE "${SHELL_HERE_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}${RM_FLEX}" \
     || echo "$CMD" | grep -qE "${WRAPPER_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}${RM_FLEX}" \
     || echo "$CMD" | grep -qE "${COMMAND_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}${RM_FLEX}" \
     || echo "$CMD" | grep -qE "${BRACE_AFTER_COMMA}${LEAD_PREFIX}${PATH_PREFIX}rm(,*\})+[[:space:]]+-rf[[:space:]]+/" \
     || echo "$CMD" | grep -qE "(^|[;&|({)}\`!]|[[:space:]])\{${LEAD_PREFIX}${PATH_PREFIX}rm,+\}[[:space:]]+-rf[[:space:]]+/" \
     || echo "$CMD" | grep -qE "(^|[;&|({)}\`!]|[[:space:]])\{${LEAD_PREFIX}${PATH_PREFIX}rm,[^}]+\}[[:space:]]+-rf[[:space:]]+/" \
     || echo "$CMD" | grep -qE "${ENV_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}${RM_FLEX}" \
     || echo "$CMD" | grep -qE "${EVAL_WRAPPER_PREAMBLE}${LEAD_PREFIX}rm[[:space:]'\''\"\\\\]+-rf[[:space:]'\''\"\\\\]+/" \
     || echo "$CMD" | grep -qE "${EVAL_COMPOUND_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}${RM_FLEX}" \
     || echo "$CMD" | grep -qE "${ENV_S_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}${RM_FLEX}" \
     || echo "$CMD" | grep -qE "${CMD_PREAMBLE}${PATH_PREFIX}${RM_FLEX_QS}" \
     || { [ "$HAS_SPLICE" = "1" ] && echo "$CMD_UNQUOTED" | grep -qE "${STRICT_KW_START}${PATH_PREFIX}${RM_FLEX}(\*|[[:space:]]|$)"; } \
     || { [ "$HAS_SPLICE" = "1" ] && echo "$CMD_UNQUOTED" | grep -qE "${STRICT_KW_START}${PATH_PREFIX}${RM_FLEX_QS}"; }; then
    echo "BLOCKED: Destructive filesystem operation" >&2
    exit 2
  fi

  # System-level commands: sudo, docker, systemctl
  if echo "$CMD_STRIPPED" | grep -qE "${CMD_PREAMBLE}${PATH_PREFIX}(sudo|docker|systemctl)${POST_SUFFIX}" \
     || echo "$CMD" | grep -qE "${SHELL_C_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(sudo|docker|systemctl)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${SHELL_HERE_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(sudo|docker|systemctl)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${WRAPPER_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(sudo|docker|systemctl)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${COMMAND_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(sudo|docker|systemctl)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${BRACE_AFTER_COMMA}${LEAD_PREFIX}${PATH_PREFIX}(sudo|docker|systemctl)(,*\})+${POST_SUFFIX_BRACE}" \
     || echo "$CMD" | grep -qE "(^|[;&|({)}\`!]|[[:space:]])\{${LEAD_PREFIX}${PATH_PREFIX}(sudo|docker|systemctl),[^}]+\}${POST_SUFFIX_BRACE}" \
     || echo "$CMD" | grep -qE "${ENV_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(sudo|docker|systemctl)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${EVAL_WRAPPER_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(sudo|docker|systemctl)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${EVAL_COMPOUND_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(sudo|docker|systemctl)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${ENV_S_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(sudo|docker|systemctl)${POST_SUFFIX_Q}" \
     || { [ "$HAS_SPLICE" = "1" ] && echo "$CMD_UNQUOTED" | grep -qE "${STRICT_KW_START}${PATH_PREFIX}(sudo|docker|systemctl)${POST_SUFFIX}"; }; then
    echo "BLOCKED: System-level command not permitted" >&2
    exit 2
  fi

  # System control: shutdown, reboot, halt
  if echo "$CMD_STRIPPED" | grep -qE "${CMD_PREAMBLE}${PATH_PREFIX}(shutdown|reboot|halt)${POST_SUFFIX}" \
     || echo "$CMD" | grep -qE "${SHELL_C_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(shutdown|reboot|halt)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${SHELL_HERE_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(shutdown|reboot|halt)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${WRAPPER_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(shutdown|reboot|halt)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${COMMAND_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(shutdown|reboot|halt)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${BRACE_AFTER_COMMA}${LEAD_PREFIX}${PATH_PREFIX}(shutdown|reboot|halt)(,*\})+${POST_SUFFIX_BRACE}" \
     || echo "$CMD" | grep -qE "(^|[;&|({)}\`!]|[[:space:]])\{${LEAD_PREFIX}${PATH_PREFIX}(shutdown|reboot|halt),[^}]+\}${POST_SUFFIX_BRACE}" \
     || echo "$CMD" | grep -qE "${ENV_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(shutdown|reboot|halt)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${EVAL_WRAPPER_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(shutdown|reboot|halt)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${EVAL_COMPOUND_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(shutdown|reboot|halt)${POST_SUFFIX_Q}" \
     || echo "$CMD" | grep -qE "${ENV_S_PREAMBLE}${LEAD_PREFIX}${PATH_PREFIX}(shutdown|reboot|halt)${POST_SUFFIX_Q}" \
     || { [ "$HAS_SPLICE" = "1" ] && echo "$CMD_UNQUOTED" | grep -qE "${STRICT_KW_START}${PATH_PREFIX}(shutdown|reboot|halt)${POST_SUFFIX}"; }; then
    echo "BLOCKED: System control command not permitted" >&2
    exit 2
  fi
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
    # Block Bash write patterns whose TARGET is /workspace/product/ (FW-034 fix).
    # Pre-FW-034 used two independent substring checks (mentions-product AND has-write-op),
    # which false-blocked `cat /workspace/product/x | tee /tmp/y` (read source is product,
    # write target is /tmp). Regex requires product path in the write-operator's TARGET
    # position: redirect stdout target, sed -i/--in-place file arg, tee trailing file,
    # cp/mv/rsync last arg (dest) OR -t/--target-directory=, patch filename arg.
    # Hotfix 2026-04-22 (COO + Sonnet empirical adversary on b6c7cf2): narrowed sed
    # flag anchor to -i/--in-place only (pre-hotfix `-[-a-zA-Z]+` over-matched
    # -n/-E/-e/-r — broke officer read-analysis workflows); sed `-i` suffix now
    # consumes non-space to catch `-i.bak` (Sonnet adversary BUG-1); added Patterns
    # 5a/5b for `cp|mv -t DEST` bundle (incl -rfvt/-at/-bt — Sonnet adversary
    # BUG-2/3/4) and `cp|mv|rsync --target-directory=DEST`; rsync intentionally
    # excluded from -t bundle (rsync -t means --times not target-directory — would
    # false-block `rsync -rt SOURCE DEST` source-reads from /workspace/product/);
    # added `>|` to Pattern 1 (bash force-overwrite under noclobber).
    # Hotfix 3 2026-04-22 (COO 3rd-round + Sonnet post-fix adversary on 37888dc):
    # sed script-body class `[^<]*` → `[^&]*` — sed scripts legitimately contain
    # `<` (HTML/XML bodies, e.g. `sed -i 's/<h1>/<h2>/' file.html`), `|` (valid
    # delimiter, e.g. `sed -i 's|a|b|' f`), AND `;` (intra-script command
    # separator, e.g. `sed -i 's/a/b/;s/c/d/' f`). Attempted hotfix-3a `[^|&;]`
    # over-rejected `|`; hotfix-3b `[^&;]` over-rejected `;`. Final class `[^&]*`
    # allows all three; `&` alone still flags `&&`/`|| →` command-chain
    # boundaries.
    # Hotfix 4 2026-04-23 (COO 4th-round + Sonnet adversary pass 2 & 3 on
    # hotfix-4 interim forms): `[^&]*` over-rejects sed replacement-`&`
    # (standard sed feature meaning "the matched text"): `s/foo/&bar/`,
    # `/&/d`, `s/^/& /`, and sed's `&&` = "matched text twice"
    # (`s/a/&&/`). Progression:
    #   - Interim (COO) `([^&]|&[^&])*`: fixed single-& but missed
    #     `&&`-inside-quotes (Sonnet pass 2 HIGH).
    #   - Interim 2 (quote-balanced) `([^&'"]|'[^']*'|"[^"]*"|&[^&])*`:
    #     fixed `&&`-in-quotes but broke A2 (escape-out `'\''` idiom)
    #     and A6 (quoted product path `'/workspace/product/x'`) — both
    #     HIGH (Sonnet pass 3).
    # Final class: `([^&'"]|'[^']*'|"[^"]*"|'|"|&[^&])*` — balanced-span
    # alternatives absorb `&&`/`;`/`|` inside quotes; solo `'`/`"`
    # fallbacks absorb orphan quotes (escape-out idioms, unmatched
    # trailing quotes); `&[^&]` still consumes sed-literal `&`; outside
    # quotes, none of the alternatives accept `&&` so the match still
    # halts at shell chain boundaries. Plus `/workspace/product/` anchor
    # now accepts optional `["']?` opening quote to catch quoted path
    # forms (`sed -i ... '/workspace/product/x'`). Verified: `sed -i
    # 's/x/y/' /tmp/f && cat /workspace/product/log` still correctly
    # PASSES (the `&&` halts the unquoted class before the product
    # anchor can be reached). The downstream `[[:space:]]+/workspace/product/` anchor keeps
    # the product-path write requirement (so false-pos from `sed -i /tmp/f; echo
    # /workspace/product/` is a known pre-existing greedy-match FP, not a
    # delta-3 regression). Pattern 5a `-[a-zA-Z]*t[[:space:]]+` → `[[:space:]]*`
    # — GNU cp/mv accept `-t/DIR` no-space form (bundle-flag + attached-arg),
    # bypass pre-hotfix. Known gaps tracked as FW-040 Phase B: quoted dest with
    # internal space, variable expansion, `install` + other write tools (awk/dd/
    # touch/mkdir/truncate/sqlite3), python3 -c, node -e, sed `/pat/w PATH`
    # internal-write directive (no -i needed), Pattern 4 last-arg-is-dest
    # assumption violated by `cp -t DEST SOURCE...` ordering.
    # Hotfix 5 2026-04-24 (FW-040 HIGH — CTO Sonnet crew agent, COO-adversary-rated
    # HIGH severity): Added Pattern 8 (perl -i inplace-edit) + Pattern 9 (tar
    # extract/create touching /workspace/product/).
    # Hotfix 6 2026-04-24 (FW-040 HIGH — COO Pass-1 adversary on d752992):
    # - Pattern 9b: added `--file[=[:space:]]+` long-form alt; closes 3 HIGH GNU
    #   tar `--file=` bypasses (--file=, --file<space>, -c --file=).
    # - Pattern 8: prefix char class iterated — Pass-1 `[^[:space:]]*` → `[a-z]*`
    #   (fixes -I/usr/local/lib FP), Pass-2 Sonnet `[a-z]*` → `[^[:space:]Ii]*`
    #   (restores -Ti/-Wi/-0777i coverage regressed by lowercase-only).
    # Known scope gaps deferred: (a) `tar -tf|-xf /workspace/product/archive.tar`
    # read-ops from product archive file (fail-closed FP, low sev); (b) perl
    # `$^I` special-var inplace inside `-e` body (flag-level regex can't see
    # body) — filed as FW-051 orthogonal scope-gap.
    #
    # Pattern 8 (perl -i): `-[^[:space:]Ii]*i[^[:space:]]*` matches any flag token
    # containing `i` where the prefix bundle excludes `I` (the include-path flag)
    # and `i` itself (since `i` appears at end of prefix). Covers -i, -i.bak, -pi,
    # -ip, -ipe, -ni, -i0, -Ti (taint+inplace), -Wi (warnings+inplace), -0777i
    # (record-sep+inplace), -li, -wi, -si, -ai, -lpi etc. The two optional middle
    # groups absorb additional flags between -i and the product path. Long-form
    # `--in-place[=suffix]` alternative covers the GNU long alias.
    # Hotfix-6 Pass-1 (COO 2026-04-24): narrowed prefix class from `[^[:space:]]*`
    # to `[a-z]*` to fix `-I/usr/local/lib` include-path FP (where greedy absorber
    # caught `i` in `lib`). Pass-2 (Sonnet 2026-04-24): `[a-z]*` regressed uppercase
    # (`-Ti`, `-Wi`) and digit-prefixed (`-0777i`) bundles; re-widened to
    # `[^[:space:]Ii]*` — excludes ONLY the FP-causing `I` char, not the whole
    # uppercase+digit alphabet. Discriminator: requires `-<bundle>i`-containing
    # flag token AND `/workspace/product/` as a subsequent argument. Allows:
    # `perl -pe ...` (no -i, stdout-only), `perl -ne '...' /workspace/product/x`
    # (no -i, read-only), `perl -pi /tmp/f` (inplace but non-product target),
    # `perl -I/usr/local/lib -pe ...` (include-path, not inplace),
    # `perl -Iinclude_dir -pe ...` (relative include path).
    # Accepted FPs:
    #   - `echo "perl -i /workspace/product/x"` (data-position quoted body) —
    #     fail-closed per FW-045 FP-1; workaround: omit product path from echo
    #     body or write to /tmp first.
    #   - `perl -e 'BEGIN{$^I=""}...' /workspace/product/f` — scope gap:
    #     inplace mode enabled via `$^I` special var inside `-e` body, no `-i`
    #     flag at shell level. Inherent limitation of flag-level regex; would
    #     require `-e` body inspection (same class as FW-040 Phase B gap #3:
    #     "Scripting inline-writes via python3 -c / node -e / ruby -e").
    #     Flat regex alternative (match `\$\^I` textually) is cat-and-mouse
    #     (attacker variants: `${^I}`, dynamic var name assignment). Left as
    #     FW-040 Phase B scope-gap. Low operational risk (obscure idiom, Edit/
    #     Write tools still gated for non-CTO officers via Section 3a).
    #
    # Pattern 9 (tar): Two sub-alternatives:
    #   9a: tar with -C[space|no-space] or --directory[=space] followed by
    #       /workspace/product/ (covers: -C, -C/ no-space bundle, --directory space,
    #       --directory=). GNU tar accepts -C/PATH with no space — Adversary Pass-1
    #       found -C[[:space:]]+ missed -C/PATH; fixed to -C[[:space:]]* to catch
    #       both forms. Catches all extract+create forms.
    #   9b: tar with `-[flags]f[space]|--file[=|space]` + /workspace/product/
    #       (archive FILE written to product path, e.g.
    #       `tar -cf /workspace/product/archive.tar /some/src` OR
    #       `tar --file=/workspace/product/archive.tar -c /some/src`).
    #       Hotfix-6 (COO 2026-04-24): added `--file[=[:space:]]+` long-form
    #       alt — parity with Pattern 9a's `--directory=` alt. Pre-hotfix, GNU
    #       `tar --file=/workspace/product/x.tar` bypassed short-form-only gate.
    # Allows: `tar -xf archive.tar` (no -C, no product -f), `tar -xf a.tar -C /tmp/`
    # (non-product -C), `tar -tf archive.tar` (list-only, no -C). Accepted FPs:
    # `tar -czf /tmp/x.tar -C /workspace/product/ .` (-C as SOURCE context for -c
    # where archive is written to /tmp, product is source content) — fail-closed;
    # officer workaround: `cd /workspace/product && tar -czf /tmp/x.tar .`.
    # `tar -xf /workspace/product/archive.tar` and `tar -tf /workspace/product/x.tar`
    # (read-op from product archive file) — fail-closed by Pattern 9b; workaround:
    # copy archive to /tmp first. Low severity (read-ops, not writes); tracked as
    # FW-040 scope gap for future read-op vs write-op differentiation.
    # Blocks `tar -cf /workspace/product/archive.tar /some/src` (archive written
    # TO product path — correct BLOCK). Pattern 9b gates on archive -f path position.
    if echo "$CMD" | grep -qE '(>[>|]?[[:space:]]*["'\'']?/workspace/product/|sed[[:space:]]+(([^&'\''"]|'\''[^'\'']*'\''|"[^"]*"|'\''|"|&[^&])*[[:space:]])?(-[a-zA-Z]*i[^[:space:]]*|--in-place(=[^[:space:]]*)?)([[:space:]]([^&'\''"]|'\''[^'\'']*'\''|"[^"]*"|'\''|"|&[^&])*)?[[:space:]]+["'\'']?/workspace/product/|tee[[:space:]]+(-[-a-zA-Z]+[[:space:]]+)*([^;|&<]+[[:space:]]+)?["'\'']?/workspace/product/|(cp|mv|rsync)[[:space:]]+(-[-a-zA-Z]+[[:space:]]+)*[^;|&]+[[:space:]]+["'\'']?/workspace/product/[^[:space:];|&"'\'']*["'\'']?([[:space:]]*($|[;&|<>])|[[:space:]]+[0-9]+[<>])|(cp|mv)[[:space:]]+([^;|&]*[[:space:]])?-[a-zA-Z]*t[[:space:]]*["'\'']?/workspace/product/|(cp|mv|rsync)[[:space:]]+([^;|&]*[[:space:]])?--target-directory(=|[[:space:]]+)["'\'']?/workspace/product/|patch[[:space:]]+([^;|&<]+[[:space:]]+)?["'\'']?/workspace/product/|perl[[:space:]]+([^;&|]*[[:space:]])?(-[^[:space:]Ii]*i[^[:space:]]*|--in-place(=[^[:space:]]*)?)(([[:space:]]([^;&|]*[[:space:]])?)|([[:space:]]([^;&|]*[[:space:]])?)?)[[:space:]]*["'\'']?/workspace/product/|tar[[:space:]]+([^;&|]*[[:space:]]+)?(-C[[:space:]]*|--directory[=[:space:]]+)["'\'']?/workspace/product/|tar[[:space:]]+([^;&|]*[[:space:]]+)?(-[^[:space:]]*f[[:space:]]+|--file[=[:space:]]+)["'\'']?/workspace/product/)'; then
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
# FW-041 (hotfix 2026-04-22 — Rule 4 class from FW-034): BOTH phases
#   extended to accept `git -FLAG [VALUE] push` and `gh -FLAG [VALUE]
#   pr merge`. GNU `git` accepts global flags (-C <path>, -c key=val,
#   --git-dir=<path>, --work-tree=<path>, --namespace=<ns>) BETWEEN
#   `git` and the subcommand; `gh` accepts (-R owner/repo, --repo
#   owner/repo). Pre-hotfix Phase 1 required subcommand immediately
#   after `git`/`gh`, AND Phase 2 required literal `git push` / `gh pr
#   merge` — so `git -C /path push origin main` and `gh -R owner/repo
#   pr merge N` bypassed BOTH phases (fail-open — gate silently not
#   consulted). Fix: identical optional repeated `(-FLAG [VALUE] )*`
#   group between tool and subcommand at BOTH phases. Each flag group
#   requires leading `-` on the flag and non-`-` leading char on the
#   value, so non-deploy subcommands like `git commit -m "..."` —
#   where `commit` doesn't start with `-` — still correctly fall out
#   of the flag-repeat and fail the `push` verb check. Phase 1 `gh`
#   alternation ALSO narrowed from `(pr|api)` to `(pr merge|api)` —
#   read-only `gh pr view/list/checkout/status` are not write actions
#   and have no business passing Phase 1.
# FW-043 (hotfix 2026-04-23 — COO + Sonnet empirical adversary on FW-041 ship):
#   6 bypass forms silently skipped Phase 1 because the anchor was
#   LINE-START-ONLY (`^[[:space:]]*` + `head -n1`), not statement-start.
#   Forms: (a) `cd /tmp && git push origin main` — chain prefix,
#   (b) multiline `echo ok\ngit push origin main` — head -n1 eats
#   line 1, (c) `(git push origin main)` — subshell paren prefix,
#   (d) `true && git push origin main` — always-succeed chain,
#   (e) `: ; git push origin main` — null-command + semi,
#   (f) `{ git push origin main; }` — brace-group prefix (Sonnet
#   pass-1 against initial fix). Fix for both Layer 1 + CI Green
#   gate: (1) remove `head -n1` — grep's line-mode handles
#   multiline naturally (each line checked independently against
#   the anchor, which still uses `^`). (2) Widen anchor prefix
#   from `^[[:space:]]*` to `(^|[;&|({\`][[:space:]]*)` — accepts
#   bare line-start OR a preceding shell statement-boundary char
#   (semi, amp, pipe, open-paren, open-brace, backtick) + whitespace.
#   Trade-off: false-positives when a boundary char appears INSIDE
#   a quoted string followed by literal `git push origin main` text,
#   e.g., `git commit -m "staged && git push origin main"` would fire
#   the gate (Phase 2 already substring-matched; Phase 1 now also
#   matches at `&&` inside quotes). Accepted as fail-closed trade
#   (over-block vs FW-041's silent fail-open); FP rate ~rare in
#   officer workflow, gate prompt tells CTO to set the reviewed
#   key + retry. Also extends Layer 1 Phase 2 trailing-terminator
#   class from `[[:space:];]|$` to `[[:space:];&|(){}\`]|$` so
#   trailing shell-chain chars (incl. close-brace/close-paren)
#   after `main`/`master` also match. Heredoc body FP (line-mode
#   grep sees `git push origin main` as its own line) also
#   accepted as fail-closed per same rationale.
#   FW-041 Phase 2 scope-gap (quoted-space flag value) remains
#   open — still tracked as FW-041 Phase 2.
# FW-045 (hotfix-6 2026-04-23 — COO Pass-2 empirical adversary on f7a231b):
#   17/20 probes against the FW-043 statement-boundary prefix bypassed
#   Phase 1. Four HIGH classes, 14 addressable forms:
#   (1) prefix-consumer gap — 8 POSIX command-modifier wrappers
#   absent from alternation: `exec|time|nohup|nice|ionice|coproc|stdbuf
#   |unbuffer cmd`. Fix: unified flag-tolerant branch
#   `(exec|time|nohup|nice|ionice|coproc|stdbuf|unbuffer)(
#   [[:space:]]+-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+`
#   (same flag pattern as FW-041 for git/gh — handles `nice -n 10 cmd`,
#   `ionice -c 3 -n 5 cmd`, `stdbuf -oL cmd`, bare `nohup cmd`).
#   (2) inline VAR=val prefix — `GIT_TRACE=1 git push`, `FOO=bar
#   BAZ=qux git push`. THE canonical POSIX idiom. Existing `env`
#   branch only handles `env VAR=val cmd`, not bare assignment. Fix:
#   prepend `[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+` to
#   alternation — 1+ iterations handled by outer `*`.
#   (3) boundary class gap — `!` (bash negation: `! cmd` returns
#   !exit-code). Added to class. (`<`/`>` redirects handled as prefix
#   consumer, not boundary, since they take an arg: `>/tmp/out cmd` =
#   redirect-then-run-cmd.) Fix: boundary class extended from
#   `[;&|({\`]` to `[;&|({\`!]`; redirect branch
#   `[<>][[:space:]]*[^[:space:]]+[[:space:]]+` added to prefix-consumer.
#   (4) wrapper-exec with quote-body — `bash -c 'git push'`, `sh -c`,
#   `zsh -c`, `eval 'git push'`, bare `eval git push`. Fix: two new
#   prefix-consumer branches `(bash|sh|zsh)[[:space:]]+-c[[:space:]]+
#   ['"]?` and `eval[[:space:]]+['"]?` (optional quote absorbs through
#   the opening delimiter — engine re-anchors at `git push` inside the
#   quoted body).
#   CRITICAL Phase 2 co-change: `bash -c 'git push origin main'`
#   ends with `'` after `main`, which was NOT in Phase 2 trailing
#   terminator class — Phase 2 then failed to match even after Phase 1
#   succeeded. Phase 2 trailing class extended from `[[:space:];&|(){}<>\`]`
#   to `[[:space:];&|(){}<>'"\`]` — adds quote chars as valid post-`main`
#   terminators. (Pattern 1 from memory: "Phase 2 action regex must
#   mirror Phase 1 anchor flag-tolerance" — FW-045 re-confirmed: any
#   wrapper form that introduces a new post-`main` context needs Phase
#   2 trailing class extension. 5th instance in FW-029-family work.)
#   Sonnet Pass-3 additions (same commit, 9 new findings — HIGH: H-1
#   `bash -x -c`, H-2 ANSI-C `$'...'`, H-3 `)` boundary, H-4 `}` boundary;
#   MEDIUM: M-1 bare `env` (no VAR=val), M-2 Phase 2 asymmetry (`main!`,
#   `main^`, `main~`, `main#comment`), M-3 digit-prefix redirect
#   `2>/dev/null`, M-4 `timeout --preserve-status 30s`; plus `setsid` +
#   `wget` tool additions):
#   - Boundary class `[;&|({\`!]` → `[;&|({)}\`!]` (adds close-paren
#     for case-arm end, close-brace for function-body end).
#   - `env` branch: flag-tolerant idiom `env([[:space:]]+-[^[:space:]]+
#     ([[:space:]]+[^-][^[:space:]]*)?)*[[:space:]]+` replaces
#     VAR=val-required form (bare-env now matches; inline VAR=val
#     handled by separate `[A-Za-z_]…=[…]` branch).
#   - `timeout` branch: pre-duration flag-tolerance (`timeout -k 5s
#     --preserve-status 30s cmd`).
#   - Wrapper list: add `setsid` (session leader).
#   - `bash|sh|zsh` branch: flag-tolerant before `-c` (`bash -x -c`,
#     `bash --norc -c`), ANSI-C absorber `(\$?['\''"])?` handles
#     `bash -c $'…'`.
#   - Redirect branch: digit-prefix `[0-9]?[<>]` handles `2>/dev/null cmd`
#     and `1>/tmp/out cmd`.
#   - Command alternation: add `wget[[:space:]]` (parallel to curl).
#   - Phase 2 trailing class: add `!#\\^~` to post-`main|master`
#     terminators (`main!`, `main#comment` shell-comment strip, `main^1`
#     git-ancestor, `main~2` git-ancestor, `main\\foo` backslash).
#   Sonnet Pass-4 additions (fresh-context re-review after Pass-3 fix —
#   4 real bypasses confirmed empirically; 2 Pass-4 findings were
#   false-positives: `<(cmd)` process sub already fires via existing
#   `(` boundary, and `main:refs/heads/main` fires via greedy `.*main$`):
#   - Wrapper alternation: add `command` and `builtin` — POSIX builtin
#     modifiers (`command cmd` bypasses aliases; `builtin cmd` forces
#     shell builtin). Real bypasses: `command git push origin main`.
#   - Shell -c alternation: extend `(bash|sh|zsh)` →
#     `(bash|sh|zsh|fish|ksh|dash|ash|csh|tcsh|mksh)`. Real bypass:
#     `fish -c 'git push origin main'`. All POSIX-family shells take
#     `-c CMD_STRING`, so gap covered by common alt-shells.
#   COO Pass-5 additions (fresh-context empirical post-Pass-4 — 6 real
#   bypasses in one HIGH class confirmed on e588850, all canonical bash
#   compound-statement keywords; 2 additional MEDIUM stdin-shell forms
#   documented as scope-gap):
#   - Prefix-consumer alt: add `(then|do|else|elif)[[:space:]]+` branch.
#     No flag-tolerance — bash reserved words do NOT take flags. Closes
#     `if ci_green; then git push origin main; fi` canonical conditional
#     push, `while <cond>; do git push origin main; done` retry loop,
#     `for x in a b; do git push origin main; done` batch, `until` wait-
#     then-push, `elif`/`else` branches. The reserved word follows a `;`
#     (or newline) statement-boundary — anchor fires at `;`, but prior
#     regex had no alt to consume `then|do|else|elif`, so scan halted.
#   Remaining scope-gaps (acknowledged, NOT fixable by flat regex):
#   (a) xargs-construct `echo origin main | xargs git push` — lexical
#   disaggregation across pipe, main is LHS arg not RHS refspec.
#   (b) variable expansion `X=git; $X push` — already tracked as FW-040
#   Phase B P8.
#   (c) dot-source `. /tmp/push.sh` + `source /tmp/push.sh` — hook can't
#   scan file contents.
#   (d) perl/python -e / awk 'system(…)' shell-out — not in wrapper
#   alternation; same filesystem-escape class as dot-source, deferred
#   to FW-040 Phase B shell-parse-aware gate.
#   (e) shell-stdin-mode `bash <<<"git push …"` here-string + `echo ...
#   | bash -s` explicit-stdin-read — same dataflow-decoupled class as
#   xargs and dot-source (the `git push` text is carried across a
#   stdin boundary, flat regex can't bridge). Deferred to FW-040 Phase
#   B. Pass-5 MEDIUM #2.
#   FP surface expansion (accepted fail-closed, same class as FW-043 FP-1):
#   commit bodies or inline text containing wrapper-name or inline-VAR
#   token adjacent to literal `git push origin main` text WILL fire the
#   gate. Example: commit msg "nohup git push origin main for CI" →
#   trips. Also: `git push --force-with-lease origin main` now fires
#   (was already in flag-tolerant scope but worth calling out — ACK
#   re-SET retry works). Pass-6 Sonnet widening: multi-line `-m` commit
#   bodies with a line starting `then git push origin main` / `do git
#   push …` / `else …` / `elif …` now also fire (new reserved-word
#   branch matches at `^` anchor on the second line). Same class, same
#   workaround. Mitigation: `cabinet:layer1:cto:reviewed` re-SET after
#   gate-block → retry-commit workflow (same as FW-043).
# Phase 2 (action regex): actual push-to-main-or-master / pr-merge pattern.
# AND-composed so both must pass to trip the gate.
# Action regex covers BOTH `main` (Sensed product repo) and `master`
# (framework repo default) — CTO pushes to both.
# FW-044 (2026-04-24): Phase 2b — unified positional regex.
# Covers `gh api <DELETE> refs/heads/(main|master)` + branch-protection
# endpoint + curl DELETE + wget DELETE analogs. Structure: statement-boundary
# anchor (^|[;&|({)}`!]) on gh/curl/wget prevents the pattern from matching
# inside quoted echo bodies (`gh api user && echo "gh api -X DELETE refs/heads/main"`
# → inside `"…"`, no boundary char precedes the inner `gh api` → no match).
# Env-var prefix wrapper `([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*`
# absorbs inline POSIX assignments before gh/curl/wget (`GH_TOKEN=abc gh api
# -X DELETE refs/heads/main` — Pass-2 MEDIUM-C fix, canonical auth-override).
# Clause-exclusion [^;&|#]* between anchor and DELETE/ref signals stops at
# `;`/`&`/`|`/`#` → compound-command FPs (`gh api user && git commit -m
# "…DELETE refs/heads/main…"`) don't cross clauses. Case-insensitive
# [Dd][Ee][Ll][Ee][Tt][Ee] + fused flag `(-X|--method|--request)[=[:space:]]*`
# covers -XDELETE, -X DELETE, -X=DELETE, --method DELETE, --method=DELETE,
# --request DELETE, and quoted "DELETE"/'DELETE' variants (adversary A2/A5/A6).
# Trailing-slash `(main|master)/?` handles ref with/without trailing slash
# (Pass-1 B1). Branch-protection endpoint
# `branches/(main|master)/protection` — same destructive verb class — blocked
# as OR-alternative (Pass-1 D1). curl + wget anchors handle raw REST calls
# that bypass gh (Pass-1 C3 + Pass-2 HIGH-B wget --method=DELETE).
# Terminator set includes `?` (Pass-2 HIGH-A: `?v=1` query string on ref URL).
# Order-agnostic: flag-before-ref AND ref-before-flag both covered by the two
# top-level alternatives inside the trailing group.
# Branch disambiguation via terminator [[:space:];&|(){}<>'"`!#\^~/?] — trailing
# char `l`/`.`/`-`/`s` NOT in set so mainline/main.md/main-feature/mastership
# correctly pass through.
# FW-044 hotfix-1 (2026-04-24): close 14 HIGH bypasses from COO Pass-1
# adversary across two root causes:
#   ROOT CAUSE 1 (PA-F class, 11 bypasses): Phase 2b prefix-absorber was a
#     strict SUBSET of Phase 1's — Phase 2b only absorbed VAR_ASSIGN plus
#     env-var-only prefix, so AND-composed gate `phase1 && (phase2a||phase2b)`
#     fired false on every wrapper Phase 1 absorbed but Phase 2b didn't
#     (`eval`, `bash -c`, `sh -c`, `nohup`, `time`, `exec`, `sudo`, `env CMD`,
#     `timeout 5`, `command`, `stdbuf -o0` before `gh api -X DELETE
#     refs/heads/main`). Fix: replace narrow Phase 2b prefix absorber with
#     full Phase 1 alternation (sudo/env/timeout/exec/time/nohup/nice/ionice/
#     coproc/stdbuf/unbuffer/setsid/command/builtin/VAR_ASSIGN/shell-c/eval/
#     redirect/then-do).
#   ROOT CAUSE 2 (PA-E class, 3 bypasses): VAR_ASSIGN value class
#     `[^[:space:]]+` truncated quoted values at the first space —
#     `PATH="foo bar" gh api -X DELETE refs/heads/main` broke Phase 1 at
#     the `foo` → `bar` boundary. Fix: widen value class to
#     `('...'|"..."|[^[:space:]]+)` then extend to include ANSI-C quoting
#     `\'...'` (Pass-2 P2-A2). Applied at Phase 1 AND Phase 2b for parity.
# Hotfix-1 Pass-2 adversary: 1 additional bypass closed (ANSI-C quoted
# VAR_ASSIGN value). 15 total HIGH bypasses closed in hotfix-1. Remaining
# deferrals to FW-051:
#   - `FOO=''hello world''` bash adjacent-quoted-string concatenation
#     (Pass-2 P2-A1) — same class as `-X 'DE''LETE'` quote-concat. No
#     CMD_NORM preprocessing at Layer 1.
#   - `eval "PATH=\"foo bar\" gh api -X DELETE refs/heads/main"` (Pass-1
#     CA1) — backslash-escaped quotes inside quoted eval body need
#     CMD_NORM preprocessing; same class.
# Hotfix-1 Pass-3 identified 3 orthogonal scope-gaps also deferred to
# FW-051:
#   - full-path shell `/bin/bash -c "..."` (shell alternation has no slash)
#   - fused flag `bash -lc "..."` (no `-lc` branch; only `-c`)
#   - wrapper indirection `./wrapper.sh` / `$(command -v gh)` (no
#     indirection absorber)
# Deferred to FW-051: Layer 1 quoted-splice (`"gh" api`), subshell-eval splice
# (`$(echo gh) api`), URL-encoded refs (`refs%2fheads%2fmain`), wildcard refs
# (`refs/heads/m*`), heredoc body scan, Pass-2 MEDIUM-D quote-concat DELETE
# (`-X 'DE''LETE'`). Same root class as FW-042 pre-v3.7.2 BSQ — Layer 1 does
# not apply CMD_NORM.
if [ "$OFFICER" = "cto" ] && [ "$TOOL_NAME" = "Bash" ]; then
  CMD=$(echo "$TOOL_INPUT" | jq -r '.command // empty' 2>/dev/null)
  if echo "$CMD" | grep -qE '(^|[;&|({)}`!])[[:space:]]*(sudo[[:space:]]+|env([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+|timeout([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+[0-9]+[smhd]?[[:space:]]+|(exec|time|nohup|nice|ionice|coproc|stdbuf|unbuffer|setsid|command|builtin)([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=(\$'\''[^'\'']*'\''|'\''[^'\'']*'\''|"[^"]*"|[^[:space:]]+)[[:space:]]+|(bash|sh|zsh|fish|ksh|dash|ash|csh|tcsh|mksh)([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+-c[[:space:]]+(\$?['\''"])?|eval[[:space:]]+['\''"]?|[0-9]?[<>][[:space:]]*[^[:space:]]+[[:space:]]+|(then|do|else|elif)[[:space:]]+)*(git[[:space:]]+(-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?[[:space:]]+)*push|gh[[:space:]]+(-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?[[:space:]]+)*(pr[[:space:]]+merge|api)|curl[[:space:]]|wget[[:space:]])' && \
     { echo "$CMD" | grep -qE 'git[[:space:]]+(-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?[[:space:]]+)*push.*(main|master)([[:space:];&|(){}<>'\''"`!#\\^~]|$)|gh[[:space:]]+(-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?[[:space:]]+)*pr[[:space:]]+merge' || \
       echo "$CMD" | grep -qE '(^|[;&|({)}`!])[[:space:]]*(sudo[[:space:]]+|env([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+|timeout([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+[0-9]+[smhd]?[[:space:]]+|(exec|time|nohup|nice|ionice|coproc|stdbuf|unbuffer|setsid|command|builtin)([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=(\$'\''[^'\'']*'\''|'\''[^'\'']*'\''|"[^"]*"|[^[:space:]]+)[[:space:]]+|(bash|sh|zsh|fish|ksh|dash|ash|csh|tcsh|mksh)([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+-c[[:space:]]+(\$?['\''"])?|eval[[:space:]]+['\''"]?|[0-9]?[<>][[:space:]]*[^[:space:]]+[[:space:]]+|(then|do|else|elif)[[:space:]]+)*(gh[[:space:]]+(-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?[[:space:]]+)*api[[:space:]]|curl([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]|wget([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]])[^;&|#]*((-X|--method|--request)[=[:space:]]*["'\'']?[Dd][Ee][Ll][Ee][Tt][Ee]["'\'']?[^;&|#]*(refs/heads/(main|master)([[:space:];&|(){}<>'\''"`!#\\^~/?]|$)|branches/(main|master)/protection([[:space:];&|(){}<>'\''"`!#\\^~?]|$))|(refs/heads/(main|master)([[:space:];&|(){}<>'\''"`!#\\^~/?]|$)|branches/(main|master)/protection([[:space:];&|(){}<>'\''"`!#\\^~?]|$))[^;&|#]*(-X|--method|--request)[=[:space:]]*["'\'']?[Dd][Ee][Ll][Ee][Tt][Ee]["'\'']?)'; }; then
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
  if echo "$CMD" | grep -qE '(^|[;&|({)}`!])[[:space:]]*(sudo[[:space:]]+|env([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+|timeout([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+[0-9]+[smhd]?[[:space:]]+|(exec|time|nohup|nice|ionice|coproc|stdbuf|unbuffer|setsid|command|builtin)([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=(\$'\''[^'\'']*'\''|'\''[^'\'']*'\''|"[^"]*"|[^[:space:]]+)[[:space:]]+|(bash|sh|zsh|fish|ksh|dash|ash|csh|tcsh|mksh)([[:space:]]+-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?)*[[:space:]]+-c[[:space:]]+(\$?['\''"])?|eval[[:space:]]+['\''"]?|[0-9]?[<>][[:space:]]*[^[:space:]]+[[:space:]]+|(then|do|else|elif)[[:space:]]+)*(git[[:space:]]+(-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?[[:space:]]+)*push|gh[[:space:]]+(-[^[:space:]]+([[:space:]]+([^-][^[:space:]]*|'\''[^'\'']*'\''|"[^"]*"))?[[:space:]]+)*(pr[[:space:]]+merge|api)|curl[[:space:]]|wget[[:space:]])' && \
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
