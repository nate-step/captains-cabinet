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
  # EVAL-008: clean stop-hook test residue. HDEL both today's + yesterday's
  # keys so a midnight-spanning eval (stop-hook wrote to yesterday's key,
  # trap fires after 00:00 UTC) still cleans up correctly. The transcript
  # rm uses $$ scope — the glob could race against a concurrent eval run
  # and delete a peer's in-flight transcript, so we only rm this run's file.
  _ET_TODAY=$(date -u +%Y-%m-%d)
  _ET_YDAY=$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null)
  for _ET_DT in "$_ET_TODAY" "$_ET_YDAY"; do
    [ -z "$_ET_DT" ] && continue
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HDEL "cabinet:cost:tokens:daily:$_ET_DT" \
      evaltest_input evaltest_output evaltest_cache_write evaltest_cache_read evaltest_cost_micro \
      > /dev/null 2>&1
  done
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "cabinet:cost:tokens:evaltest" > /dev/null 2>&1
  rm -f "/tmp/eval-transcript-$$.jsonl" 2>/dev/null
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
# Eval 008: stop-hook cost-write integrity (FW-016 regression catcher)
# ------------------------------------------------------------------
# stop-hook.sh writes per-turn cost data to cabinet:cost:tokens:daily:$DATE
# HSET (FW-016). pre-tool-use.sh reads that HSET to enforce spending caps
# (FW-002). If stop-hook silently stops writing — e.g. a jq upgrade breaks
# the transcript parse, or the HSET pipeline loses a field — pre-tool-use
# reads 0, every cap reads as unhit, and FW-002 silently fails open.
#
# This eval simulates one stop-hook invocation with a canned Opus
# transcript (known token counts) and asserts the HSET fields populated
# with the exact expected values. Any drift in the jq extraction, the
# HINCRBY fields, or the COST_MICRO math flips the assertion.
#
# Canned Opus turn: input=1000, output=500, cache_write=200, cache_read=3000.
# Expected cost_micro per stop-hook.sh line 52 Opus case:
#   1000*15 + 500*75 + 200*3750/1000 + 3000*300/1000
# = 15000 + 37500 + 750 + 900 = 54150 microdollars.
#
# Uses a fake officer "evaltest" (no real tier2 dir, no collision with
# live officers). HDEL cleanup in both the inline path and the EXIT trap.
#
# Scope — what this eval does NOT cover:
#   * Sonnet pricing path (stop-hook line 56) — officers run Opus per
#     CLAUDE.md, so Opus is the primary drift surface. Extend with a
#     second fixture if Sonnet becomes an officer model.
#   * Unknown-model silent fallthrough to Sonnet pricing (stop-hook
#     lines 54-57 default case) — a new model like claude-opus-5 would
#     silently use Sonnet (5x cheaper) pricing, under-reporting cost.
#     Proper fix is a stderr warn in stop-hook for unrecognized models;
#     filed as a latent drift concern, not what this eval catches.
#   * New-field schema additions (e.g. Claude Code adds a 6th usage
#     field stop-hook should track) — the eval asserts the 5 known
#     fields match; it won't detect that a new field exists and is
#     being ignored. Field-rename drift DOES trip the eval (the rename
#     makes stop-hook's jq return 0 → HSET value mismatches expected).
#   * Redis-down or jq-missing silent failure — those require preflight
#     checks in stop-hook itself, not observable via this round-trip test.
#   * Cabinet-wide cap false-positive window — evaltest_cost_micro is
#     briefly (~10ms between stop-hook HINCRBY and inline HDEL) visible
#     in the *_cost_micro sum that pre-tool-use.sh computes for the
#     cabinet-wide cap. Blast radius: $0.054 extra in the sum.
#     REVISITED 2026-04-21 (FW-025 shipped — evals now run on every
#     master push): accepted as a known window. Mitigation via
#     non-*_cost_micro-suffixed test field would require editing
#     stop-hook.sh (which hardcodes `${OFFICER}_cost_micro` as the
#     pricing-derived output field and is the very target of this
#     regression test — changing it defeats the test). Mitigation via
#     pre-tool-use.sh exclusion list is out of scope for FW-025 and
#     would introduce a new untested exception path. FW-025's flock
#     serializes eval runs across officers, capping the residue at
#     ONE $0.054 entry at any moment rather than N×$0.054. Current
#     platform.yml cap=0 (unlimited) gives zero false-positive risk;
#     if Captain later tightens daily_cabinet_wide_usd below ~$1,
#     file a follow-up FW to add an exclusion or swap the probe
#     identity to a non-cost-summed field family.
#
# Reserved test identity: the officer name "evaltest" is a convention
# reserved across golden evals (also used in EVAL-005 for triggers).
# If someone genuinely creates an officer named "evaltest", the
# cleanup trap's HDEL would clobber their real cost data. Convention
# not enforcement; rename if you're hiring a 100th officer.
log "EVAL-008: stop-hook cost-write integrity (FW-016 regression catcher)"
STOP_HOOK="$CABINET_ROOT/cabinet/scripts/hooks/stop-hook.sh"
if [ -f "$STOP_HOOK" ]; then
  # Pre-clean: HINCRBY accumulates, so prior residue would skew the test.
  # HDEL both today + yesterday to stay symmetric with the EXIT trap and
  # defend against a midnight-boundary flip between our pre-clean and
  # stop-hook's internal TODAY compute.
  EVAL_PRE_TODAY=$(date -u +%Y-%m-%d)
  EVAL_PRE_YDAY=$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null)
  for _EV_DT in "$EVAL_PRE_TODAY" "$EVAL_PRE_YDAY"; do
    [ -z "$_EV_DT" ] && continue
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HDEL "cabinet:cost:tokens:daily:$_EV_DT" \
      evaltest_input evaltest_output evaltest_cache_write evaltest_cache_read evaltest_cost_micro \
      > /dev/null 2>&1
  done
  EVAL_TX="/tmp/eval-transcript-$$.jsonl"
  cat > "$EVAL_TX" <<'EOT'
{"type":"assistant","message":{"model":"claude-opus-4-7","usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000}}}
EOT
  echo "{\"session_id\":\"eval-session\",\"transcript_path\":\"$EVAL_TX\"}" \
    | OFFICER_NAME=evaltest bash "$STOP_HOOK" > /dev/null 2>&1
  # Post-read: stop-hook.sh line 82 computes TODAY=$(date -u +%Y-%m-%d) at
  # HINCRBY time — if the eval straddles 00:00 UTC between our pre-clean
  # and stop-hook's write, the target key shifts by one day. Probe today
  # AND the pre-clean date and take whichever HSET has our write; pick a
  # loud fail if neither does (real stop-hook breakage). Symmetric with
  # the trap-cleanup fix from the initial Sonnet review.
  EVAL_POST_TODAY=$(date -u +%Y-%m-%d)
  EVAL_KEY=""
  for _EV_DT in "$EVAL_POST_TODAY" "$EVAL_PRE_TODAY"; do
    _CAND_KEY="cabinet:cost:tokens:daily:$_EV_DT"
    _PROBE=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "$_CAND_KEY" evaltest_cost_micro 2>/dev/null)
    if [ -n "$_PROBE" ] && [ "$_PROBE" != "(nil)" ]; then
      EVAL_KEY="$_CAND_KEY"
      break
    fi
  done
  if [ -z "$EVAL_KEY" ]; then
    fail "stop-hook did not write evaltest_cost_micro to any expected date key (probed today=$EVAL_POST_TODAY, start=$EVAL_PRE_TODAY)"
  else
    ACTUAL_INPUT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "$EVAL_KEY" evaltest_input 2>/dev/null)
    ACTUAL_OUTPUT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "$EVAL_KEY" evaltest_output 2>/dev/null)
    ACTUAL_CW=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "$EVAL_KEY" evaltest_cache_write 2>/dev/null)
    ACTUAL_CR=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "$EVAL_KEY" evaltest_cache_read 2>/dev/null)
    ACTUAL_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "$EVAL_KEY" evaltest_cost_micro 2>/dev/null)
    if [ "$ACTUAL_INPUT" = "1000" ] && [ "$ACTUAL_OUTPUT" = "500" ] && \
       [ "$ACTUAL_CW" = "200" ] && [ "$ACTUAL_CR" = "3000" ] && \
       [ "$ACTUAL_COST" = "54150" ]; then
      pass "stop-hook writes cost HSET correctly (all 5 fields, cost_micro=54150)"
    else
      fail "stop-hook cost-write drift (input=$ACTUAL_INPUT/1000 output=$ACTUAL_OUTPUT/500 cache_write=$ACTUAL_CW/200 cache_read=$ACTUAL_CR/3000 cost_micro=$ACTUAL_COST/54150)"
    fi
    # Inline cleanup — HDEL the key we actually wrote to. Trap still sweeps
    # both dates on interrupt.
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HDEL "$EVAL_KEY" \
      evaltest_input evaltest_output evaltest_cache_write evaltest_cache_read evaltest_cost_micro \
      > /dev/null 2>&1
  fi
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "cabinet:cost:tokens:evaltest" > /dev/null 2>&1
  rm -f "$EVAL_TX"
else
  fail "stop-hook.sh not found at $STOP_HOOK"
fi

# ------------------------------------------------------------------
# Eval 009: trigger_send stderr-on-Redis-down invariant (FW-027 H-1)
# ------------------------------------------------------------------
# FW-027 Phase A fixed `trigger_send` to emit a stderr WARN when XADD
# fails (previously 2>&1 > /dev/null silently dropped the trigger). This
# eval pins that invariant: stub redis-cli to exit 1 with a connection
# error, invoke trigger_send, assert stderr carries the WARN line.
#
# Without this regression catcher, a future refactor that re-suppresses
# XADD output (e.g. "noise cleanup" pass) would silently re-introduce the
# FW-027 H-1 bug — validators would stop receiving deploy-notify triggers
# on any Redis hiccup, and no one would know until the next audit.
#
# Mechanism: PATH-prefix stub. Write a fake `redis-cli` script to a temp
# dir that exits 1 + emits a stderr connection-refused message, prepend
# that dir to PATH inside a subshell, source triggers.sh, call trigger_send,
# capture subshell stderr via `(...) 2>tmpfile`.
#
# Why not function-override: works but more fragile across nested $()
# subshells inside trigger_send; PATH-stub is portable.
#
# Test identity: "ev9target" — if a real officer is ever named ev9target
# this test would attempt to send to their (non-existent due to stub) stream.
# Since redis-cli is stubbed, no real Redis write happens regardless.
log "EVAL-009: trigger_send stderr-on-Redis-down invariant (FW-027 H-1 regression catcher)"
EV9_STUB_DIR=$(mktemp -d /tmp/ev9-stub.XXXXXX)
cat > "$EV9_STUB_DIR/redis-cli" <<'EOT'
#!/bin/bash
echo "Could not connect to Redis at 127.0.0.1:6379: Connection refused" >&2
exit 1
EOT
chmod +x "$EV9_STUB_DIR/redis-cli"
EV9_STDERR_FILE="$EV9_STUB_DIR/stderr.log"
(
  export PATH="$EV9_STUB_DIR:$PATH"
  export OFFICER_NAME=evaltest
  source "$CABINET_ROOT/cabinet/scripts/lib/triggers.sh"
  trigger_send ev9target "EVAL-009 probe — should warn to stderr" > /dev/null
  # Best-effort: the memory-queue backgrounded subshell may still be running.
  # wait to reap it before subshell exits; PATH stub persists for it too.
  wait 2>/dev/null
) 2>"$EV9_STDERR_FILE"
# Grep: semantic invariant is "stderr mentions XADD failure," not the
# precise current wording. Match either the current WARN form or any
# reasonable future rewording that still surfaces XADD + failure. A
# refactor that drops the stderr entirely would fail both branches.
# (Risk acknowledged: the backgrounded memory-queue subshell inside
# trigger_send could theoretically emit stderr containing "XADD" or
# "WARN" and cause a false-pass; memory.sh does not today, and the
# test stubs redis-cli so no real write path reaches Postgres.)
if grep -qE "(trigger_send WARN|XADD.*fail|WARN.*XADD|cabinet:triggers:.*fail)" "$EV9_STDERR_FILE"; then
  pass "trigger_send emits stderr warn when XADD fails (FW-027 H-1 invariant holds)"
else
  fail "trigger_send did NOT emit stderr warn on Redis-down (first 3 lines: $(head -3 "$EV9_STDERR_FILE" | tr '\n' '|'))"
fi
rm -rf "$EV9_STUB_DIR"

# ------------------------------------------------------------------
# Eval 010: post-tool-use.sh does NOT silence triggers.sh source (FW-027 H-2)
# ------------------------------------------------------------------
# FW-027 Phase A fixed the hook to surface source failures via a CRITICAL
# stderr line. A dynamic test would need to remove triggers.sh from disk,
# which is unsafe in a shared-tree Cabinet (would brick every officer's
# next hook invocation for the duration of the test). Instead, this is a
# STATIC invariant check: grep the hook source for the anti-pattern.
#
# Anti-pattern: `. …triggers.sh 2>/dev/null` at the top-level source line
# — silences ENOENT/syntax errors, leaving trigger_read undefined.
#
# Positive invariant: the CRITICAL stderr diagnostic string must appear
# in the hook source. Its presence + absence of the anti-pattern together
# prove the FW-027 H-2 fix is still in effect.
#
# Scope: post-tool-use.sh only. Other scripts that source triggers.sh
# (e.g. notify-officer.sh, run-golden-evals.sh itself) are out of scope —
# they are not the central tool-call-driven delivery path.
log "EVAL-010: post-tool-use.sh surfaces triggers.sh load failures (FW-027 H-2 static invariant)"
EV10_POST_HOOK="$CABINET_ROOT/cabinet/scripts/hooks/post-tool-use.sh"
if [ ! -f "$EV10_POST_HOOK" ]; then
  fail "post-tool-use.sh not found at $EV10_POST_HOOK"
elif grep -qE '^[[:space:]]*(\.|source)[[:space:]]+[^[:space:]]*triggers\.sh[[:space:]]+2>/dev/null' "$EV10_POST_HOOK"; then
  fail "post-tool-use.sh STILL silences triggers.sh source errors (FW-027 H-2 regression — anti-pattern re-introduced)"
elif ! grep -q "CRITICAL.*triggers\.sh failed to load" "$EV10_POST_HOOK"; then
  fail "post-tool-use.sh is missing the CRITICAL triggers.sh load-failure diagnostic (FW-027 H-2 regression)"
else
  pass "post-tool-use.sh surfaces triggers.sh load failures (FW-027 H-2 invariant holds)"
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
