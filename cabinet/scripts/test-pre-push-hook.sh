#!/bin/bash
# test-pre-push-hook.sh — regression harness for cabinet/scripts/git-hooks/pre-push
#
# Exercises the full decision tree of the pre-push hook:
#   FW-007: force-push / delete refusal on master
#   FW-025: golden-eval gate on master pushes (stubbed to always pass)
#
# The eval gate (run-golden-evals.sh) is stubbed with exit 0 in every fixture
# so this harness focuses exclusively on FW-007 force-push logic without
# coupling to the eval suite's own regression coverage.
#
# Run:  bash /opt/founders-cabinet/cabinet/scripts/test-pre-push-hook.sh
# Exit 0 on all PASS, 1 on any FAIL.

set -uo pipefail

HOOK="/opt/founders-cabinet/cabinet/scripts/git-hooks/pre-push"
ZERO_SHA="0000000000000000000000000000000000000000"

PASS=0
FAIL=0
FAILURES=()

# ── Helpers ───────────────────────────────────────────────────────────────────

assert_contains() {
  local label="$1"; local haystack="$2"; local needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: needle='$needle' missing from output")
    printf "  [FAIL] %s: needle='%s' missing\n" "$label" "$needle"
    printf "         output: %s\n" "$haystack"
  fi
}

assert_not_contains() {
  local label="$1"; local haystack="$2"; local needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    FAIL=$((FAIL+1))
    FAILURES+=("$label: unexpected needle='$needle' in output")
    printf "  [FAIL] %s: unexpected needle='%s'\n" "$label" "$needle"
    printf "         output: %s\n" "$haystack"
  else
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  fi
}

assert_eq() {
  local label="$1"; local actual="$2"; local expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: expected='$expected' actual='$actual'")
    printf "  [FAIL] %s: expected='%s' actual='%s'\n" "$label" "$expected" "$actual"
  fi
}

# Run the hook from inside fixture_dir with optional env vars prepended.
# Caller must provide stdin via pipe/herestring.
# Usage: <stdin> | run_hook <fixture_dir> [VAR=val ...]
# Returns stdout+stderr combined in $output; exit code in $?
run_hook() {
  local fixture_dir="$1"; shift
  # env() passes additional VAR=val pairs; unset FORCE_PUSH_ANNOUNCED from
  # caller environment so tests are hermetic.
  (
    cd "$fixture_dir"
    env -u FORCE_PUSH_ANNOUNCED "$@" bash "$HOOK"
  )
}

# ── Fixture factory ───────────────────────────────────────────────────────────
#
# Creates a throwaway git repo with:
#   ANCESTOR_SHA  — first commit (used as "already on remote" commit)
#   HEAD_SHA      — second commit (used as new local commit for fast-forward)
# Stubs run-golden-evals.sh to always exit 0 (FW-025 not under test).
# Sets up shared/force-push-log.md as a real regular file (initially empty).
#
# Echoes the fixture directory path; caller assigns to a variable.
setup_fixture() {
  local dir
  dir=$(mktemp -d)
  (
    cd "$dir"
    git init -q
    git config user.email "test@test"
    git config user.name "Test"
    # First commit — will be ANCESTOR_SHA
    echo "a" > a.txt
    git add a.txt
    git commit -qm "init"
    # Second commit — will be HEAD_SHA
    echo "b" > b.txt
    git add b.txt
    git commit -qm "second"
    # Stub eval gate (FW-025 not under test)
    mkdir -p cabinet/scripts shared
    cat > cabinet/scripts/run-golden-evals.sh <<'STUB'
#!/bin/bash
exit 0
STUB
    chmod +x cabinet/scripts/run-golden-evals.sh
    # Real regular log file (starts empty)
    touch shared/force-push-log.md
  ) >/dev/null 2>&1
  echo "$dir"
}

# Pull HEAD_SHA and ANCESTOR_SHA out of a fixture repo.
get_head_sha()     { git -C "$1" rev-parse HEAD; }
get_ancestor_sha() { git -C "$1" rev-parse HEAD~1; }

# ── Global fixture setup + cleanup ────────────────────────────────────────────
FIXTURE=$(setup_fixture)
trap 'rm -rf "$FIXTURE"' EXIT

HEAD_SHA=$(get_head_sha "$FIXTURE")
ANCESTOR_SHA=$(get_ancestor_sha "$FIXTURE")

# ═════════════════════════════════════════════════════════════════════════════
# NON-MASTER PATHS — should exit 0 without reaching eval gate
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo "── Non-master paths ──────────────────────────────────────────────────────"

# Test 1: Push to a feature branch — must pass through, exit 0
echo "Test 1: push to feature branch → exit 0 (eval gate skipped)"
OUTPUT=$(echo "refs/heads/feat $HEAD_SHA refs/heads/feat $ANCESTOR_SHA" \
  | run_hook "$FIXTURE" 2>&1)
RC=$?
assert_eq "  exit code 0" "$RC" "0"
# FW-025 gate prints a message when it runs; confirm it did NOT run
assert_not_contains "  eval gate did not run" "$OUTPUT" "golden-eval suite"

# Test 2: Empty stdin (no refs pushed) → exit 0
echo "Test 2: empty stdin → exit 0"
OUTPUT=$(echo "" | run_hook "$FIXTURE" 2>&1)
RC=$?
assert_eq "  exit code 0" "$RC" "0"
assert_not_contains "  no BLOCKED" "$OUTPUT" "BLOCKED"

# Test 3: Not in a git repo → exit 0 + stderr message
echo "Test 3: invoked outside a git repo → exit 0 + stderr 'not in a git repo'"
OUTPUT=$(echo "" | (cd /tmp && bash "$HOOK") 2>&1)
RC=$?
assert_eq "  exit code 0" "$RC" "0"
assert_contains "  stderr skipping message" "$OUTPUT" "not in a git repo"

# ═════════════════════════════════════════════════════════════════════════════
# MASTER PUSH — LEGITIMATE CASES (eval gate runs → stubbed to exit 0)
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo "── Master push — legitimate cases ───────────────────────────────────────"

# Test 4: Fast-forward push — remote_sha is ancestor of local_sha → exit 0
echo "Test 4: fast-forward to master → exit 0 (eval gate runs)"
OUTPUT=$(echo "refs/heads/master $HEAD_SHA refs/heads/master $ANCESTOR_SHA" \
  | run_hook "$FIXTURE" 2>&1)
RC=$?
assert_eq "  exit code 0" "$RC" "0"
assert_not_contains "  no BLOCKED" "$OUTPUT" "BLOCKED"
# The eval gate message should appear because PUSHES_MASTER=true
assert_contains "  eval gate ran" "$OUTPUT" "golden-eval suite"

# Test 5: First-time master creation (remote_sha all zeros) → exit 0
echo "Test 5: first-time master creation (remote all-zeros) → exit 0"
OUTPUT=$(echo "refs/heads/master $HEAD_SHA refs/heads/master $ZERO_SHA" \
  | run_hook "$FIXTURE" 2>&1)
RC=$?
assert_eq "  exit code 0" "$RC" "0"
assert_not_contains "  no BLOCKED" "$OUTPUT" "BLOCKED"
assert_contains "  eval gate ran" "$OUTPUT" "golden-eval suite"

# ═════════════════════════════════════════════════════════════════════════════
# MASTER PUSH — DESTRUCTIVE WITHOUT ANNOUNCEMENT (must exit 1)
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo "── Master push — destructive without announcement ────────────────────────"

# Test 6: Force overwrite — local_sha is NOT a descendant of remote_sha.
# Use remote_sha=$HEAD_SHA, local_sha=$ANCESTOR_SHA: ANCESTOR is not an
# ancestor of HEAD… wait, HEAD is a descendant of ANCESTOR.
# We need remote_sha to NOT be an ancestor of local_sha.
# remote_sha=$HEAD_SHA (newer), local_sha=$ANCESTOR_SHA (older) → rewind.
# git merge-base --is-ancestor HEAD ANCESTOR → false (HEAD is not ancestor of ANCESTOR).
echo "Test 6: force overwrite (remote newer than local → not ancestor) → exit 1"
OUTPUT=$(echo "refs/heads/master $ANCESTOR_SHA refs/heads/master $HEAD_SHA" \
  | run_hook "$FIXTURE" 2>&1)
RC=$?
assert_eq "  exit code 1" "$RC" "1"
assert_contains "  stderr: force overwrite message" "$OUTPUT" "force overwrite of refs/heads/master"

# Test 7: Delete master (local_sha all zeros) → exit 1
echo "Test 7: delete of master (local_sha all-zeros) → exit 1"
OUTPUT=$(echo "refs/heads/master $ZERO_SHA refs/heads/master $HEAD_SHA" \
  | run_hook "$FIXTURE" 2>&1)
RC=$?
assert_eq "  exit code 1" "$RC" "1"
assert_contains "  stderr: delete message" "$OUTPUT" "delete of refs/heads/master"

# ═════════════════════════════════════════════════════════════════════════════
# is_announced() VALIDATION — each bad case must block, exit 1
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo "── is_announced() — validation branches ─────────────────────────────────"

# Helper: run a force-push scenario (local=ANCESTOR, remote=HEAD so hook
# sets BLOCK_REASON) with given env vars.
run_force_push() {
  echo "refs/heads/master $ANCESTOR_SHA refs/heads/master $HEAD_SHA" \
    | run_hook "$FIXTURE" "$@" 2>&1
}

# Test 8: FORCE_PUSH_ANNOUNCED with malformed timestamp (not ISO UTC) → exit 1, "malformed"
echo "Test 8: malformed FORCE_PUSH_ANNOUNCED → exit 1 + 'malformed'"
OUTPUT=$(run_force_push "FORCE_PUSH_ANNOUNCED=not-a-timestamp")
RC=$?
assert_eq "  exit code 1" "$RC" "1"
assert_contains "  stderr: malformed" "$OUTPUT" "malformed"

# Test 9: FORCE_PUSH_ANNOUNCED timestamp in the future → exit 1, "in the future"
echo "Test 9: future timestamp → exit 1 + 'in the future'"
FUTURE_TS=$(date -u -d "+1 hour" +%Y-%m-%dT%H:%M:%SZ)
OUTPUT=$(run_force_push "FORCE_PUSH_ANNOUNCED=$FUTURE_TS")
RC=$?
assert_eq "  exit code 1" "$RC" "1"
assert_contains "  stderr: in the future" "$OUTPUT" "in the future"

# Test 10: FORCE_PUSH_ANNOUNCED timestamp > 300s old → exit 1, age message
echo "Test 10: stale timestamp (>300s old) → exit 1 + age message"
OLD_TS=$(date -u -d "10 minutes ago" +%Y-%m-%dT%H:%M:%SZ)
OUTPUT=$(run_force_push "FORCE_PUSH_ANNOUNCED=$OLD_TS")
RC=$?
assert_eq "  exit code 1" "$RC" "1"
# Hook says "must be within 300s" in the message
assert_contains "  stderr: age/must-be-within" "$OUTPUT" "must be within"

# Test 11: Valid fresh timestamp but log file missing → exit 1, "missing"
echo "Test 11: valid timestamp, log file missing → exit 1 + 'missing'"
FRESH_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Temporarily move the log file away
mv "$FIXTURE/shared/force-push-log.md" "$FIXTURE/shared/force-push-log.md.bak"
OUTPUT=$(run_force_push "FORCE_PUSH_ANNOUNCED=$FRESH_TS")
RC=$?
mv "$FIXTURE/shared/force-push-log.md.bak" "$FIXTURE/shared/force-push-log.md"
assert_eq "  exit code 1" "$RC" "1"
assert_contains "  stderr: missing" "$OUTPUT" "missing"

# Test 12: Valid fresh timestamp but log is a symlink → exit 1, "symlink"
echo "Test 12: log file is a symlink → exit 1 + 'symlink'"
FRESH_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Replace real file with a symlink pointing to a scratch file containing the timestamp
SCRATCH=$(mktemp)
echo "$FRESH_TS  test  test" > "$SCRATCH"
mv "$FIXTURE/shared/force-push-log.md" "$FIXTURE/shared/force-push-log.md.real"
ln -s "$SCRATCH" "$FIXTURE/shared/force-push-log.md"
OUTPUT=$(run_force_push "FORCE_PUSH_ANNOUNCED=$FRESH_TS")
RC=$?
rm -f "$FIXTURE/shared/force-push-log.md"
mv "$FIXTURE/shared/force-push-log.md.real" "$FIXTURE/shared/force-push-log.md"
rm -f "$SCRATCH"
assert_eq "  exit code 1" "$RC" "1"
assert_contains "  stderr: symlink" "$OUTPUT" "symlink"

# Test 13: Valid fresh timestamp but timestamp NOT in log file → exit 1, "no line in"
echo "Test 13: timestamp not in log → exit 1 + 'no line in'"
FRESH_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# Ensure log file exists but doesn't contain the timestamp (write a different line)
echo "2020-01-01T00:00:00Z  test  unrelated entry" > "$FIXTURE/shared/force-push-log.md"
OUTPUT=$(run_force_push "FORCE_PUSH_ANNOUNCED=$FRESH_TS")
RC=$?
# Restore empty log for subsequent tests
: > "$FIXTURE/shared/force-push-log.md"
assert_eq "  exit code 1" "$RC" "1"
assert_contains "  stderr: no line in" "$OUTPUT" "no line in"

# ═════════════════════════════════════════════════════════════════════════════
# is_announced() SUCCESS PATH — all checks pass → allow + eval gate runs
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo "── is_announced() — success path ────────────────────────────────────────"

# Test 14: Fresh valid timestamp, matching log line, regular file → exit 0
echo "Test 14: valid announcement (fresh TS, log line present, regular file) → exit 0"
FRESH_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$FRESH_TS  cto  testing force-push announcement path" > "$FIXTURE/shared/force-push-log.md"
OUTPUT=$(run_force_push "FORCE_PUSH_ANNOUNCED=$FRESH_TS")
RC=$?
# Restore log
: > "$FIXTURE/shared/force-push-log.md"
assert_eq "  exit code 0" "$RC" "0"
assert_contains "  allowed message present" "$OUTPUT" "allowed"
# Eval gate must also run (PUSHES_MASTER is true)
assert_contains "  eval gate ran" "$OUTPUT" "golden-eval suite"

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════

echo ""
printf "==== %d PASS, %d FAIL ====\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf "\nFailures:\n"
  for f in "${FAILURES[@]}"; do printf "  - %s\n" "$f"; done
  exit 1
fi
exit 0
