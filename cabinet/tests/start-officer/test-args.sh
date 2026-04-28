#!/bin/bash
# test-args.sh — FW-073 start-officer.sh arg + var-resolution harness
#
# Invokes start-officer.sh with CABINET_TEST_DRY_RUN=1 (early-exit before
# tmux/claude side effects) across legacy + pool modes and asserts:
#   - legacy invocation preserves WINDOW + OFFICER_DIR layout
#   - legacy invocation does NOT export CABINET_ACTIVE_PROJECT
#     (so FW-072 cost-counter keeps legacy `<officer>_<dim>` field shape)
#   - --project flag scopes WINDOW + OFFICER_DIR per (officer, project)
#   - --project flag exports CABINET_ACTIVE_PROJECT
#   - bad slugs are rejected (path-injection guard)
#   - pool mode without per-project env file is rejected
#
# Run: bash cabinet/tests/start-officer/test-args.sh

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$ROOT/cabinet/scripts/start-officer.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

# Mock TELEGRAM_<UPPER>_TOKEN (required by script). Test slug must already
# exist in cabinet/env/ — sensed.env is shipped, use that.
export TELEGRAM_CTO_TOKEN="x-test-token"
export TELEGRAM_HQ_CHAT_ID="x-test-chat"
export CABINET_TEST_DRY_RUN=1

# ----------------------------------------------------------------------------
# T1: Legacy invocation (no --project) — back-compat.
# ----------------------------------------------------------------------------
output=$(bash "$SCRIPT" cto 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "T1: legacy mode exited rc=$rc — $output"
else
  if echo "$output" | grep -q '^POOL_MODE=false$'; then
    pass "T1: legacy mode POOL_MODE=false"
  else
    fail "T1: expected POOL_MODE=false, got: $(echo "$output" | grep '^POOL_MODE=')"
  fi
  if echo "$output" | grep -q '^WINDOW=officer-cto$'; then
    pass "T1: legacy WINDOW=officer-cto preserved"
  else
    fail "T1: expected WINDOW=officer-cto, got: $(echo "$output" | grep '^WINDOW=')"
  fi
  if echo "$output" | grep -q '^OFFICER_DIR=.*/officers/cto$'; then
    pass "T1: legacy OFFICER_DIR=.../officers/cto preserved"
  else
    fail "T1: expected OFFICER_DIR=.../officers/cto, got: $(echo "$output" | grep '^OFFICER_DIR=')"
  fi
  # Critical FW-072 contract: legacy must NOT export CABINET_ACTIVE_PROJECT.
  if echo "$output" | grep -q 'CABINET_ACTIVE_PROJECT'; then
    fail "T1: legacy mode LEAKED CABINET_ACTIVE_PROJECT — would corrupt FW-072 cost shape"
  else
    pass "T1: legacy mode does not export CABINET_ACTIVE_PROJECT (FW-072 contract held)"
  fi
fi

# ----------------------------------------------------------------------------
# T2: Pool mode invocation (--project sensed) — uses shipped sensed env.
# ----------------------------------------------------------------------------
output=$(bash "$SCRIPT" cto --project sensed 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "T2: pool mode exited rc=$rc — $output"
else
  if echo "$output" | grep -q '^POOL_MODE=true$'; then
    pass "T2: pool mode POOL_MODE=true"
  else
    fail "T2: expected POOL_MODE=true, got: $(echo "$output" | grep '^POOL_MODE=')"
  fi
  if echo "$output" | grep -q '^WINDOW=officer-cto-sensed$'; then
    pass "T2: pool WINDOW=officer-cto-sensed (per-project)"
  else
    fail "T2: expected WINDOW=officer-cto-sensed, got: $(echo "$output" | grep '^WINDOW=')"
  fi
  if echo "$output" | grep -q '^OFFICER_DIR=.*/officers/cto/sensed$'; then
    pass "T2: pool OFFICER_DIR=.../officers/cto/sensed (per-project)"
  else
    fail "T2: expected OFFICER_DIR=.../officers/cto/sensed, got: $(echo "$output" | grep '^OFFICER_DIR=')"
  fi
  if echo "$output" | grep -q '^ACTIVE_SLUG=sensed$'; then
    pass "T2: pool ACTIVE_SLUG=sensed"
  else
    fail "T2: expected ACTIVE_SLUG=sensed, got: $(echo "$output" | grep '^ACTIVE_SLUG=')"
  fi
  if echo "$output" | grep -q 'CABINET_ACTIVE_PROJECT=sensed'; then
    pass "T2: pool exports CABINET_ACTIVE_PROJECT=sensed (FW-072 trigger)"
  else
    fail "T2: pool mode missing CABINET_ACTIVE_PROJECT export"
  fi
fi

# ----------------------------------------------------------------------------
# T3: Bad slug — path-injection guard.
# ----------------------------------------------------------------------------
for bad in 'foo;rm' '../etc' 'UPPER' 'has space' 'with/slash' '-leading-hyphen' '-rf'; do
  output=$(bash "$SCRIPT" cto --project "$bad" 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "T3: bad slug '$bad' was accepted (rc=0)"
  else
    pass "T3: bad slug '$bad' rejected (rc=$rc)"
  fi
done

# ----------------------------------------------------------------------------
# T4: Pool mode with non-existent env file.
# ----------------------------------------------------------------------------
output=$(bash "$SCRIPT" cto --project nonexistent-test-slug 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  fail "T4: pool mode without env file was accepted (rc=0)"
else
  if echo "$output" | grep -q "cabinet/env/nonexistent-test-slug.env"; then
    pass "T4: missing env file rejected with helpful message"
  else
    fail "T4: rejected but message unclear — $output"
  fi
fi

# ----------------------------------------------------------------------------
# T5: Unknown argument — explicit rejection.
# ----------------------------------------------------------------------------
output=$(bash "$SCRIPT" cto --bogus-flag 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  fail "T5: unknown flag was accepted"
else
  pass "T5: unknown flag rejected"
fi

# ----------------------------------------------------------------------------
# T6: Missing officer arg — usage error.
# ----------------------------------------------------------------------------
output=$(bash "$SCRIPT" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  fail "T6: missing officer arg was accepted"
else
  pass "T6: missing officer arg rejected"
fi

# ----------------------------------------------------------------------------
# T7: Defensive unset — env-file pollution must not leak into legacy mode.
# Simulates an upstream caller (or sourced env file) that already exported
# CABINET_ACTIVE_PROJECT. Legacy invocation must scrub it so the FW-072
# cost-counter contract holds even under hostile env conditions.
# ----------------------------------------------------------------------------
output=$(CABINET_ACTIVE_PROJECT=poisoned bash "$SCRIPT" cto 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
  fail "T7: poisoned legacy invocation exited rc=$rc"
elif echo "$output" | grep -q 'CABINET_ACTIVE_PROJECT'; then
  fail "T7: poisoned env LEAKED into EXPORT_VARS — FW-072 contract broken"
else
  pass "T7: defensive unset scrubs CABINET_ACTIVE_PROJECT pollution in legacy mode"
fi

# ----------------------------------------------------------------------------
# T8: Slug length cap — 33-char slug rejected.
# ----------------------------------------------------------------------------
long_slug=$(printf 'a%.0s' {1..33})
output=$(bash "$SCRIPT" cto --project "$long_slug" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  fail "T8: 33-char slug accepted (length cap not enforced)"
elif echo "$output" | grep -q '32 chars'; then
  pass "T8: 33-char slug rejected with length-cap message"
else
  fail "T8: 33-char slug rejected but message unclear — $output"
fi

# T8b: 32-char slug — boundary, must be ACCEPTED (ends in env-file-missing
# error, not length-cap error).
boundary_slug=$(printf 'a%.0s' {1..32})
output=$(bash "$SCRIPT" cto --project "$boundary_slug" 2>&1)
rc=$?
if [ "$rc" -eq 0 ]; then
  fail "T8b: 32-char slug accepted but should error on missing env file"
elif echo "$output" | grep -q '32 chars'; then
  fail "T8b: 32-char boundary slug rejected by length cap (off-by-one)"
elif echo "$output" | grep -q "cabinet/env/.*\.env"; then
  pass "T8b: 32-char slug accepted by length cap (errors on missing env-file as expected)"
else
  fail "T8b: 32-char slug error path unexpected — $output"
fi

echo
echo "=========================================="
echo "FW-073 start-officer.sh: PASS=$PASS  FAIL=$FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ]
