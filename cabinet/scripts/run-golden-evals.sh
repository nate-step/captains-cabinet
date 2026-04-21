#!/bin/bash
# run-golden-evals.sh — Automated golden eval runner
# Tests critical Cabinet behaviors by simulating scenarios and checking outcomes.
# Run after infrastructure changes to verify nothing broke.
#
# Usage: run-golden-evals.sh [--verbose]

# IMPORTANT: Do NOT use set -e — we test for non-zero exit codes intentionally.
set -uo pipefail

CABINET_ROOT="/opt/founders-cabinet"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"

# Safety: always clean up test artifacts on exit (prevents blocking all officers)
cleanup() {
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL cabinet:killswitch > /dev/null 2>&1
  # FW-016 follow-up (COO post-ship review): the legacy cabinet:cost:daily:$TODAY
  # DEL is gone — that key has no writer. EVAL-003's own save/restore handles
  # normal exit of cos_cost_micro. For interrupt-mid-test, the cost-aware wrapper
  # overwrites cos_cost_micro on the very next tool call, so a poisoned value
  # self-heals within seconds. HDEL here would risk clobbering real wrapper data.
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL cabinet:triggers:evaltest > /dev/null 2>&1
}
trap cleanup EXIT
VERBOSE=${1:-""}
PASS=0
FAIL=0
SKIP=0

log() { echo "$1"; }
pass() { PASS=$((PASS + 1)); log "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); log "  FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); log "  SKIP: $1"; }

log "=== Golden Eval Runner ==="
log "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log ""

# ------------------------------------------------------------------
# Eval 001: Kill Switch
# ------------------------------------------------------------------
# FW-022 migrated block messages from stdout → stderr. Capture stderr
# via `2>&1 >/dev/null` (swap-then-discard) so the message grep still
# works. Pre-FW-022 these evals captured stdout; they silently broke
# when FW-022 landed — EVAL-007 now catches that class of regression
# for the hook itself, but these two need stderr capture directly.
log "EVAL-001: Kill Switch"
# Set kill switch
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET cabinet:killswitch active > /dev/null 2>&1
# Test: pre-tool-use should block
RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo hello"}}' | OFFICER_NAME=cos bash "$CABINET_ROOT/cabinet/scripts/hooks/pre-tool-use.sh" 2>&1 >/dev/null)
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 2 ] && echo "$RESULT" | grep -qi "kill switch"; then
  pass "Kill switch blocks tool execution"
else
  fail "Kill switch did not block (exit=$EXIT_CODE, stderr='$RESULT')"
fi
# Test: DEL command should be allowed
RESULT2=$(echo '{"tool_name":"Bash","tool_input":{"command":"redis-cli DEL cabinet:killswitch"}}' | OFFICER_NAME=cos bash "$CABINET_ROOT/cabinet/scripts/hooks/pre-tool-use.sh" 2>/dev/null)
EXIT_CODE2=$?
if [ "$EXIT_CODE2" -eq 0 ]; then
  pass "Kill switch DEL command allowed through"
else
  fail "Kill switch DEL command was blocked"
fi
# Cleanup
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL cabinet:killswitch > /dev/null 2>&1

# ------------------------------------------------------------------
# Eval 002: Constitution Read-Only
# ------------------------------------------------------------------
# FW-022: block message is on stderr — capture via 2>&1 >/dev/null.
log "EVAL-002: Constitution Protection"
RESULT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/opt/founders-cabinet/constitution/CONSTITUTION.md"}}' | OFFICER_NAME=cos bash "$CABINET_ROOT/cabinet/scripts/hooks/pre-tool-use.sh" 2>&1 >/dev/null)
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 2 ] && echo "$RESULT" | grep -qi "constitution"; then
  pass "Constitution files are blocked from editing"
else
  fail "Constitution file edit was not blocked (exit=$EXIT_CODE, stderr='$RESULT')"
fi

# ------------------------------------------------------------------
# Eval 003: Spending Limits
# ------------------------------------------------------------------
log "EVAL-003: Spending Limits"
# FW-016: pre-tool-use.sh reads cabinet:cost:tokens:daily:$TODAY HGET
# <role>_cost_micro (microdollars). 999,999,999 ($1000) definitively
# exceeds any non-zero cap. Block message → STDERR, not stdout — so
# capture with `2>&1 >/dev/null`.
#
# When platform.yml sets daily_per_officer_usd: 0 (unlimited — the
# Captain's own Cabinet default), pre-tool-use.sh skips the per-officer
# cap block entirely. That's correct behavior, but means we cannot
# exercise the gate. Detect this and skip rather than falsely fail.
EVAL_CAP_USD=$(awk '/^[[:space:]]*daily_per_officer_usd:/{gsub(/#.*/,""); print $2; exit}' /opt/founders-cabinet/instance/config/platform.yml 2>/dev/null)
case "$EVAL_CAP_USD" in *[!0-9.]*|'') EVAL_CAP_USD=0 ;; esac
if [ "$(awk -v v="$EVAL_CAP_USD" 'BEGIN{print (v+0)==0}')" = "1" ]; then
  log "EVAL-003: skipping — daily_per_officer_usd=0 (unlimited) in platform.yml"
  pass "Spending limit eval skipped cleanly when cap=unlimited"
else
  EVAL_DATE=$(date -u +%Y-%m-%d)
  EVAL_KEY="cabinet:cost:tokens:daily:$EVAL_DATE"
  REAL_COST_MICRO=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "$EVAL_KEY" "cos_cost_micro" 2>/dev/null)
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HSET "$EVAL_KEY" "cos_cost_micro" 999999999 > /dev/null 2>&1
  RESULT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo test"}}' | OFFICER_NAME=cos bash "$CABINET_ROOT/cabinet/scripts/hooks/pre-tool-use.sh" 2>&1 >/dev/null)
  EXIT_CODE=$?
  if [ "$EXIT_CODE" -eq 2 ] && echo "$RESULT" | grep -qE "BLOCKED.*officer=cos"; then
    pass "Daily spending limit blocks when exceeded"
  else
    fail "Spending limit did not block (exit=$EXIT_CODE, stderr='$RESULT')"
  fi
  # Restore real value
  if [ -n "$REAL_COST_MICRO" ] && [ "$REAL_COST_MICRO" != "(nil)" ]; then
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HSET "$EVAL_KEY" "cos_cost_micro" "$REAL_COST_MICRO" > /dev/null 2>&1
  else
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HDEL "$EVAL_KEY" "cos_cost_micro" > /dev/null 2>&1
  fi
fi

# ------------------------------------------------------------------
# Eval 004: Codebase Ownership
# ------------------------------------------------------------------
# NOTE: This eval checks exit code only — stderr is discarded (2>/dev/null).
# If a future maintainer adds a message grep here (e.g. grep -qi "codebase"),
# switch to `2>&1 >/dev/null` per EVAL-001/EVAL-002 pattern so FW-022's
# stderr-routed blocks are captured.
log "EVAL-004: Codebase Ownership (non-CTO blocked)"
RESULT=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/workspace/product/src/app.ts"}}' | OFFICER_NAME=cpo bash "$CABINET_ROOT/cabinet/scripts/hooks/pre-tool-use.sh" 2>/dev/null)
EXIT_CODE=$?
if [ "$EXIT_CODE" -eq 2 ]; then
  pass "Non-CTO blocked from editing product codebase"
else
  fail "Non-CTO was allowed to edit product code"
fi
# CTO should be allowed
RESULT2=$(echo '{"tool_name":"Edit","tool_input":{"file_path":"/workspace/product/src/app.ts"}}' | OFFICER_NAME=cto bash "$CABINET_ROOT/cabinet/scripts/hooks/pre-tool-use.sh" 2>/dev/null)
EXIT_CODE2=$?
if [ "$EXIT_CODE2" -eq 0 ]; then
  pass "CTO allowed to edit product codebase"
else
  fail "CTO was blocked from product code"
fi

# ------------------------------------------------------------------
# Eval 005: Trigger System (Redis Streams)
# ------------------------------------------------------------------
log "EVAL-005: Redis Streams Trigger System"
source "$CABINET_ROOT/cabinet/scripts/lib/triggers.sh"
# Send a test trigger
OFFICER_NAME=eval trigger_send evaltest "Golden eval test"
# Read it
MSGS=$(trigger_read evaltest 2>/dev/null)
IDS=$(cat /tmp/.trigger_ids_evaltest 2>/dev/null)
if echo "$MSGS" | grep -q "Golden eval test"; then
  pass "Trigger send + read works"
else
  fail "Trigger not received"
fi
# ACK it
trigger_ack evaltest "$IDS"
REMAINING=$(trigger_count evaltest 2>/dev/null)
if [ "${REMAINING:-0}" -eq 0 ] 2>/dev/null; then
  pass "Trigger ACK works (count=0 after ACK)"
else
  fail "Trigger ACK failed (count=$REMAINING)"
fi
# Cleanup
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL cabinet:triggers:evaltest > /dev/null 2>&1

# ------------------------------------------------------------------
# Eval 006: Capability-Based Routing
# ------------------------------------------------------------------
log "EVAL-006: Capability-Based Routing"
CAP_FILE="$CABINET_ROOT/cabinet/officer-capabilities.conf"
if [ -f "$CAP_FILE" ]; then
  # Test has_capability
  source <(grep -v '^#' "$CABINET_ROOT/cabinet/scripts/hooks/post-tool-use.sh" | head -40)
  if grep -q "^cto:deploys_code$" "$CAP_FILE"; then
    pass "CTO has deploys_code capability"
  else
    fail "CTO missing deploys_code capability"
  fi
  if grep -q "^coo:validates_deployments$" "$CAP_FILE"; then
    pass "COO has validates_deployments capability"
  else
    fail "COO missing validates_deployments capability"
  fi
else
  fail "officer-capabilities.conf not found"
fi

# ------------------------------------------------------------------
# Eval 007: Exit-2 Stderr Invariant (FW-022 regression catcher)
# ------------------------------------------------------------------
# Claude Code's hook engine treats stdout as tool-stdout on exit 2 and
# only surfaces stderr to the operator. FW-022 fixed 19 silent-block
# paths in pre-tool-use.sh. This eval pins the invariant: for every
# `exit 2` (non-comment), the NEAREST preceding non-blank, non-comment
# line must contain `>&2`. A new gate added without stderr would
# re-introduce the original silent-brick class.
#
# Why "nearest meaningful line" and not "any line in the last 10":
# the wider window false-negatives — a stderr from an upstream block
# satisfies the check for a downstream block that forgot its own.
# "Nearest meaningful line" matches the actual pattern:
#   echo "reason" >&2
#   exit 2
#
# Scope: pre-tool-use.sh only. Only PreToolUse hooks can block a tool
# call via exit 2 — PostToolUse runs after the tool already executed;
# SessionStart/SubagentStop/etc. run outside the tool path. If future
# Claude Code versions expose a new blocking hook type, extend this
# eval to cover it.
#
# Heredocs (cat <<EOF >&2 ... EOF; exit 2) would false-POSITIVE because
# `EOF` is the nearest meaningful line and lacks `>&2`. pre-tool-use.sh
# has no heredocs today; if they appear, the eval will need heredoc-
# aware refinement.
#
# Count caveat: the `/exit 2/` awk trigger matches any line containing
# that substring — including a future `echo "requires exit 2"` string.
# EXIT2_COUNT below uses a tighter anchored regex. Today both agree
# (n=25); if they drift, the pass message's count will understate.
# The violation check itself is awk-driven so remains sound.
log "EVAL-007: pre-tool-use.sh exit-2 stderr invariant (FW-022)"
PRE_HOOK="$CABINET_ROOT/cabinet/scripts/hooks/pre-tool-use.sh"
if [ -f "$PRE_HOOK" ]; then
  VIOLATIONS=$(awk '
    /exit 2/ && !/^[[:space:]]*#/ {
      has_stderr = 0
      # Walk backwards to first non-blank, non-comment line (up to 15 back)
      for (i = NR - 1; i >= NR - 15 && i >= 1; i--) {
        line = lines[i]
        if (line ~ /^[[:space:]]*$/) continue
        if (line ~ /^[[:space:]]*#/) continue
        if (line ~ />&2/) has_stderr = 1
        break
      }
      if (!has_stderr) print "  line " NR ": " $0
    }
    { lines[NR] = $0 }
  ' "$PRE_HOOK")
  if [ -z "$VIOLATIONS" ]; then
    EXIT2_COUNT=$(grep -cE '^\s*exit 2\s*(#.*)?$' "$PRE_HOOK")
    pass "All exit 2 paths in pre-tool-use.sh have stderr on preceding meaningful line (n=$EXIT2_COUNT)"
  else
    fail "Silent-block regression in pre-tool-use.sh:"
    log "$VIOLATIONS"
  fi
else
  fail "pre-tool-use.sh not found at $PRE_HOOK"
fi

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
log ""
log "=== Results ==="
TOTAL=$((PASS + FAIL + SKIP))
log "Total: $TOTAL  |  Pass: $PASS  |  Fail: $FAIL  |  Skip: $SKIP"
if [ "$FAIL" -gt 0 ]; then
  log "STATUS: FAILED — $FAIL eval(s) broken"
  exit 1
else
  log "STATUS: ALL PASSED"
  exit 0
fi
