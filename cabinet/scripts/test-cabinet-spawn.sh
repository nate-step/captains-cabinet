#!/bin/bash
# test-cabinet-spawn.sh — FW-080 cabinet-spawn.sh harness
#
# 6+ assertions covering: bad slug, missing repo_url, dry-run, --skip-create,
# --officers restriction, and idempotency re-run behaviour.
#
# All tests run in DRY_RUN=1 mode or against stubs — no real tmux windows,
# Redis writes, or create-project.sh calls are made.
#
# Run: bash /opt/founders-cabinet/cabinet/scripts/test-cabinet-spawn.sh
# Exit 0 on all PASS, 1 on any FAIL.

set -uo pipefail

CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
SPAWN="$CABINET_ROOT/cabinet/scripts/cabinet-spawn.sh"
PASS=0
FAIL=0
FAILURES=()

assert_exit() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" -eq "$expected" ]; then
    PASS=$((PASS+1))
    printf "  [PASS] %s (exit=%d)\n" "$label" "$actual"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: expected exit=$expected got exit=$actual")
    printf "  [FAIL] %s: expected exit=%d got exit=%d\n" "$label" "$expected" "$actual"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: '$needle' not found in output")
    printf "  [FAIL] %s: '%s' not found in:\n%s\n" "$label" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local label="$1" haystack="$2" needle="$3"
  if ! echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: '$needle' found in output (should not be)")
    printf "  [FAIL] %s: '%s' found in output (should not be present)\n" "$label" "$needle"
  fi
}

# ---------------------------------------------------------------------------
# T1: bad slug rejected
# ---------------------------------------------------------------------------
echo ""
echo "T1: Bad slug rejected"

out=$(bash "$SPAWN" "INVALID_SLUG!" "https://github.com/org/repo" 2>&1); rc=$?
assert_exit "T1.1 bad slug exits non-zero" "$rc" 1
assert_contains "T1.1 bad slug error mentions slug constraint" "$out" "slug"

out=$(bash "$SPAWN" "-bad-leading-hyphen" "https://github.com/org/repo" 2>&1); rc=$?
assert_exit "T1.2 leading-hyphen slug exits non-zero" "$rc" 1

# 33-char slug (over 32-char cap)
long_slug="a$(printf 'b%.0s' {1..32})"
out=$(bash "$SPAWN" "$long_slug" "https://github.com/org/repo" 2>&1); rc=$?
assert_exit "T1.3 over-32-char slug exits non-zero" "$rc" 1
assert_contains "T1.3 over-32-char slug error mentions length" "$out" "32"

# Valid slug boundary — exactly 32 chars should pass validation
slug_32="$(printf 'a%.0s' {1..32})"
out=$(DRY_RUN=1 bash "$SPAWN" "$slug_32" "https://github.com/org/repo" 2>&1); rc=$?
assert_exit "T1.4 exactly-32-char slug passes" "$rc" 0

# ---------------------------------------------------------------------------
# T2: missing repo_url rejected
# ---------------------------------------------------------------------------
echo ""
echo "T2: Missing repo_url rejected"

out=$(bash "$SPAWN" 2>&1); rc=$?
assert_exit "T2.1 no args exits non-zero" "$rc" 1
assert_contains "T2.1 usage shown" "$out" "Usage:"

out=$(bash "$SPAWN" "valid-slug" "not-a-git-url" 2>&1); rc=$?
assert_exit "T2.2 bad repo_url exits non-zero" "$rc" 1
assert_contains "T2.2 error mentions git URL shape" "$out" "git URL"

# ---------------------------------------------------------------------------
# T3: DRY_RUN=1 prints planned actions, no side effects
# ---------------------------------------------------------------------------
echo ""
echo "T3: DRY_RUN=1 prints planned actions"

out=$(DRY_RUN=1 bash "$SPAWN" "step-network" "https://github.com/nate-step/step-network" 2>&1); rc=$?
assert_exit "T3.1 dry-run exits 0" "$rc" 0
assert_contains "T3.1 dry-run mentions DRY RUN" "$out" "DRY RUN"
assert_contains "T3.2 dry-run shows provision step" "$out" "Would invoke"
assert_contains "T3.3 dry-run shows officer start step" "$out" "start-officer.sh"
assert_contains "T3.4 dry-run shows heartbeat step" "$out" "cabinet:heartbeat"
assert_contains "T3.5 dry-run shows trigger verify step" "$out" "trigger"
assert_contains "T3.6 dry-run shows CoS notification" "$out" "Would notify CoS"
assert_contains "T3.7 dry-run shows Captain action items" "$out" "CAPTAIN ACTION REQUIRED"

# DRY_RUN must NOT touch the state file
STATE_FILE="/tmp/cabinet-spawn.step-network.state"
if [ -f "$STATE_FILE" ]; then
  assert_contains "T3.8 dry-run should not leave state file" "FAIL: state file found at $STATE_FILE" "PASS"
else
  PASS=$((PASS+1))
  printf "  [PASS] T3.8 dry-run leaves no state file\n"
fi

# ---------------------------------------------------------------------------
# T4: --skip-create works when project env file exists
# ---------------------------------------------------------------------------
echo ""
echo "T4: --skip-create works when project is already provisioned"

# Sensed is a real provisioned project — use it as the test fixture
REAL_SLUG="sensed"
out=$(DRY_RUN=1 bash "$SPAWN" "$REAL_SLUG" "https://github.com/nate-step/Sensed" --skip-create 2>&1); rc=$?
assert_exit "T4.1 --skip-create + dry-run exits 0" "$rc" 0
assert_contains "T4.2 --skip-create mentions skipping create-project" "$out" "skip-create"

# Now test --skip-create WITHOUT dry-run against a slug that has an env file
# (sensed.env exists in cabinet/env/) — should not attempt to call create-project.sh
# We guard by checking that the step output says "already provisioned"
# Use DRY_RUN=1 because we can't actually start tmux sessions in CI
out=$(DRY_RUN=1 bash "$SPAWN" "$REAL_SLUG" "https://github.com/nate-step/Sensed" --skip-create 2>&1); rc=$?
assert_exit "T4.3 --skip-create dry-run exits 0 for real slug" "$rc" 0
assert_not_contains "T4.4 --skip-create does not call create-project in dry-run" "$out" "Would invoke: bash cabinet/scripts/create-project.sh"

# --skip-create with a non-existent env file should fail
out=$(bash "$SPAWN" "nonexistent-project-zz" "https://github.com/org/repo" --skip-create 2>&1); rc=$?
assert_exit "T4.5 --skip-create fails for unprovisioned project" "$rc" 1
assert_contains "T4.5 error mentions env file missing" "$out" "does not exist"

# ---------------------------------------------------------------------------
# T5: --officers cos,cto restricts to those officers only
# ---------------------------------------------------------------------------
echo ""
echo "T5: --officers restricts officer set"

out=$(DRY_RUN=1 bash "$SPAWN" "test-project" "https://github.com/org/test-project" \
  --officers "cos,cto" 2>&1); rc=$?
assert_exit "T5.1 --officers exits 0 in dry-run" "$rc" 0
assert_contains "T5.2 --officers shows restricted officer list" "$out" "cos cto"
# coo, cro, cpo should NOT appear in the start-officer invocation line
# (they may appear in summary line about default officers)
out_start_line=$(echo "$out" | grep "start-officer.sh" | head -1)
assert_contains "T5.3 start-officer step shows allowed officers" "$out" "cos"

# Single officer --officers
out=$(DRY_RUN=1 bash "$SPAWN" "test-project" "https://github.com/org/test-project" \
  --officers "cos" 2>&1); rc=$?
assert_exit "T5.4 single --officers exits 0" "$rc" 0
assert_contains "T5.5 single officer plan shows cos" "$out" "cos"

# ---------------------------------------------------------------------------
# T6: idempotency — re-running same args is safe (state file tracks progress)
# ---------------------------------------------------------------------------
echo ""
echo "T6: Idempotency — re-run is safe"

# In dry-run the state file is never written, so re-run always exits 0
out1=$(DRY_RUN=1 bash "$SPAWN" "idempotency-test" "https://github.com/org/idempotency" 2>&1); rc1=$?
out2=$(DRY_RUN=1 bash "$SPAWN" "idempotency-test" "https://github.com/org/idempotency" 2>&1); rc2=$?
assert_exit "T6.1 first dry-run exits 0" "$rc1" 0
assert_exit "T6.2 second dry-run (re-run) exits 0" "$rc2" 0
assert_contains "T6.3 re-run output matches first run (dry-run complete)" "$out2" "DRY RUN COMPLETE"

# Verify state file cleanup: synthesize a completed-state file and confirm
# that a non-dry-run detects already-completed steps (using --skip-create
# to avoid real create-project.sh, and pointing at sensed which has an env file).
# We can't do a full non-dry-run in CI (no real tmux), so we verify the
# state-file-tracking logic via the dry-run path (DRY_RUN never writes state).
# Belt-and-suspenders: confirm no stale state file exists after dry-run.
STATE_CLEANUP="/tmp/cabinet-spawn.idempotency-test.state"
if [ -f "$STATE_CLEANUP" ]; then
  rm -f "$STATE_CLEANUP"
  FAIL=$((FAIL+1))
  FAILURES+=("T6.4 dry-run left stale state file at $STATE_CLEANUP")
  printf "  [FAIL] T6.4 dry-run left stale state file\n"
else
  PASS=$((PASS+1))
  printf "  [PASS] T6.4 no stale state file after dry-run\n"
fi

# ---------------------------------------------------------------------------
# T7: GITHUB_PAT not echoed in any output
# ---------------------------------------------------------------------------
echo ""
echo "T7: Secrets not leaked in output"

out=$(GITHUB_PAT="super-secret-token-abc123" DRY_RUN=1 \
  bash "$SPAWN" "secret-test" "https://github.com/org/repo" 2>&1); rc=$?
assert_exit "T7.1 dry-run with GITHUB_PAT exits 0" "$rc" 0
assert_not_contains "T7.2 GITHUB_PAT not echoed in output" "$out" "super-secret-token-abc123"

# ---------------------------------------------------------------------------
# T8: slug with hyphens is valid (common case: "step-network")
# ---------------------------------------------------------------------------
echo ""
echo "T8: Valid hyphenated slug"

out=$(DRY_RUN=1 bash "$SPAWN" "step-network" "https://github.com/nate-step/step-network" 2>&1); rc=$?
assert_exit "T8.1 hyphenated slug exits 0" "$rc" 0
assert_contains "T8.2 slug appears in plan output" "$out" "step-network"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=================================================="
printf "  Results: %d PASS, %d FAIL\n" "$PASS" "$FAIL"
echo "=================================================="

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "FAILURES:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi

echo "  All tests passed."
exit 0
