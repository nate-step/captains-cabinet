#!/bin/bash
# FW-019 behavior eval — checkpoint-review pre-commit hook
#
# Contracts from shared/interfaces/retro-proposals.md P-001 + Captain msg 1535:
#   (a) Diff under threshold passes silently (exit 0, no stderr)
#   (b) Diff over threshold without review artifact → exit 1 + BLOCKED stderr
#   (c) Diff over threshold WITH review artifact → exit 0 + "artifact found" stderr
#   (d) COMMIT_NO_REVIEW=1 bypasses threshold with bypass stderr
#   (e) Merge commits skip enforcement (exit 0)
#
# Invocation: bash /opt/founders-cabinet/memory/golden-evals/framework/fw-019-checkpoint-review.sh
# Exit 0 = all pass; non-zero = failure (first failure reported).

set -u

HOOK="/opt/founders-cabinet/cabinet/scripts/git-hooks/pre-commit"
TESTDIR=$(mktemp -d -t fw019-XXXXXX)
trap "rm -rf $TESTDIR" EXIT

PASS=0
FAIL=0
FAIL_DETAILS=""

# ---- Set up a throwaway git repo ----
cd "$TESTDIR"
git init -q -b master
git config user.email "eval@local"
git config user.name "FW-019 Eval"
# Simulate the framework layout
mkdir -p shared/interfaces/reviews cabinet/scripts/git-hooks
# Copy the real hook so the artifact-path calculation (find by branch slug) works
cp "$HOOK" cabinet/scripts/git-hooks/pre-commit
chmod +x cabinet/scripts/git-hooks/pre-commit
git config core.hooksPath cabinet/scripts/git-hooks

# Initial commit so we have a HEAD to diff against
echo "initial" > README.md
git add README.md
COMMIT_NO_REVIEW=1 git commit -q -m "initial"

run() {
  # usage: run <label> <expect_exit> <stderr_expect_contains> [COMMIT_NO_REVIEW=...]
  local label="$1" expect_exit="$2" stderr_contains="$3"
  shift 3
  local err_file
  err_file=$(mktemp)
  env "$@" bash cabinet/scripts/git-hooks/pre-commit 2>"$err_file"
  local got_exit=$?
  local got_stderr
  got_stderr=$(cat "$err_file")
  rm -f "$err_file"

  local ok=1
  if [ "$got_exit" != "$expect_exit" ]; then
    ok=0
    FAIL_DETAILS="$FAIL_DETAILS
  [$label] expected exit=$expect_exit, got=$got_exit; stderr='$got_stderr'"
  fi
  if [ -n "$stderr_contains" ] && ! echo "$got_stderr" | grep -qF "$stderr_contains"; then
    ok=0
    FAIL_DETAILS="$FAIL_DETAILS
  [$label] stderr missing '$stderr_contains'; got: '$got_stderr'"
  fi
  if [ "$stderr_contains" = "" ] && [ -n "$got_stderr" ]; then
    ok=0
    FAIL_DETAILS="$FAIL_DETAILS
  [$label] expected no stderr, got: '$got_stderr'"
  fi
  if [ $ok -eq 1 ]; then
    PASS=$((PASS+1))
    echo "PASS [$label]"
  else
    FAIL=$((FAIL+1))
    echo "FAIL [$label]"
  fi
}

# Small helper: stage a file with N lines
stage_lines() {
  local lines="$1" name="$2"
  : > "$name"
  for i in $(seq 1 "$lines"); do echo "line $i" >> "$name"; done
  git add "$name"
}

clear_staged() {
  git reset -q
  rm -f a_file.txt b_file.txt c_file.txt
}

# ============================================================
# Test (a) — Under threshold passes silently
# ============================================================
clear_staged
stage_lines 50 a_file.txt
run "a_under_threshold_silent" 0 ""

# ============================================================
# Test (b) — Over threshold without review artifact → blocked
# ============================================================
clear_staged
stage_lines 400 a_file.txt
run "b_over_threshold_blocked" 1 "BLOCKED"

# Also check the block message tells the user how to unblock
clear_staged
stage_lines 400 a_file.txt
err=$(bash cabinet/scripts/git-hooks/pre-commit 2>&1 >/dev/null)
if echo "$err" | grep -q "COMMIT_NO_REVIEW=1" && echo "$err" | grep -q "Spawn a reviewer"; then
  PASS=$((PASS+1)); echo "PASS [b_block_message_actionable]"
else
  FAIL=$((FAIL+1)); echo "FAIL [b_block_message_actionable]: '$err'"
  FAIL_DETAILS="$FAIL_DETAILS
  [b_block_message_actionable] block message missing override hint or reviewer nudge"
fi

# ============================================================
# Test (c) — Over threshold WITH review artifact → passes
# ============================================================
clear_staged
stage_lines 400 a_file.txt
# Artifact filename must contain the branch slug (master here)
echo "review body" > shared/interfaces/reviews/master-cp1.md
run "c_over_threshold_with_artifact" 0 "checkpoint-review artifact found"
rm -f shared/interfaces/reviews/master-cp1.md

# ============================================================
# Test (d) — COMMIT_NO_REVIEW=1 bypasses
# ============================================================
clear_staged
stage_lines 400 a_file.txt
run "d_env_override_bypass" 0 "bypassed via COMMIT_NO_REVIEW=1" COMMIT_NO_REVIEW=1

# ============================================================
# Test (e) — Merge commit skips enforcement
# ============================================================
clear_staged
stage_lines 400 a_file.txt
# Simulate merge state (MERGE_HEAD must be a valid ref for git rev-parse --verify)
git rev-parse HEAD > .git/MERGE_HEAD
run "e_merge_commit_skipped" 0 ""
rm -f .git/MERGE_HEAD

# ============================================================
# Test (f) — Real end-to-end commit: small change goes through git commit cleanly
# ============================================================
clear_staged
stage_lines 50 a_file.txt
if git commit -q -m "small real commit" 2>/dev/null; then
  PASS=$((PASS+1)); echo "PASS [f_real_small_commit_succeeds]"
else
  FAIL=$((FAIL+1)); echo "FAIL [f_real_small_commit_succeeds]"
  FAIL_DETAILS="$FAIL_DETAILS
  [f_real_small_commit_succeeds] git commit failed for 50-line diff"
fi

# ============================================================
# Test (g) — Real end-to-end commit: large change without artifact blocked by git
# ============================================================
clear_staged
stage_lines 400 b_file.txt
if git commit -q -m "large no review" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "FAIL [g_real_large_commit_blocked]"
  FAIL_DETAILS="$FAIL_DETAILS
  [g_real_large_commit_blocked] git commit succeeded for 400-line unreviewed diff (should be blocked)"
  # Undo the accidental commit so later tests stay clean
  git reset --hard HEAD^ -q
else
  PASS=$((PASS+1)); echo "PASS [g_real_large_commit_blocked]"
fi

# ============================================================
# Test (h) — Real end-to-end commit: large change with artifact passes
# ============================================================
clear_staged
stage_lines 400 c_file.txt
echo "cp2 review" > shared/interfaces/reviews/master-cp2.md
git add shared/interfaces/reviews/master-cp2.md
if git commit -q -m "large with review" 2>/dev/null; then
  PASS=$((PASS+1)); echo "PASS [h_real_large_commit_with_artifact_succeeds]"
else
  FAIL=$((FAIL+1)); echo "FAIL [h_real_large_commit_with_artifact_succeeds]"
  FAIL_DETAILS="$FAIL_DETAILS
  [h_real_large_commit_with_artifact_succeeds] git commit blocked despite review artifact present"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "======================================================"
echo "FW-019 golden eval: $PASS passed, $FAIL failed"
echo "======================================================"
if [ "$FAIL" -gt 0 ]; then
  echo -e "Failures:$FAIL_DETAILS"
  exit 1
fi
exit 0
