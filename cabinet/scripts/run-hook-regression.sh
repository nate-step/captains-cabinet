#!/bin/bash
# run-hook-regression.sh — execute permanent hook-regression harnesses
#
# Harnesses in cabinet/tests/hook-regression/ are snapshots of the
# adversary-finding validation suites originally lived in /tmp/ (ephemeral).
# Each harness validates a different FW-0xx fix — running this script after
# any pre-tool-use.sh edit catches silent reverts of prior bypass closures.
#
# Exit 0: all harnesses passed
# Exit 1: one or more harnesses reported failures (check output)
#
# Harness contract: each harness prints its own PASS/FAIL summary line.
# This runner counts "FAIL" lines + checks non-zero exit as regression signal.

set -u

REGRESSION_DIR="/opt/founders-cabinet/cabinet/tests/hook-regression"
LOG_DIR="${REGRESSION_DIR}/.last-run"
mkdir -p "$LOG_DIR"

HARNESSES=(
  "fw041-phase2.sh"
  "fw042-v37-adversary.sh"
  "fw043-adversary.sh"
  "fw044-verify.sh"
  "fw045-pass7-adversary.sh"
  "fw051-baseline.sh"
  "fw051-adversary.sh"
)

OVERALL_FAIL=0
TOTAL_HARNESSES=${#HARNESSES[@]}
PASSED=0

echo "=== Hook Regression Suite ==="
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Directory: $REGRESSION_DIR"
echo ""

for harness in "${HARNESSES[@]}"; do
  path="$REGRESSION_DIR/$harness"
  log="$LOG_DIR/${harness%.sh}.log"

  if [ ! -x "$path" ]; then
    printf "  [SKIP] %-32s (not executable: %s)\n" "$harness" "$path"
    OVERALL_FAIL=1
    continue
  fi

  # Run harness, capture stdout+stderr
  bash "$path" > "$log" 2>&1
  ec=$?

  # Extract summary: last non-blank line commonly holds PASS/FAIL counts
  summary=$(grep -Ei '^(===|Summary|PASS:|FAIL:)' "$log" | tail -3 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')
  fail_signal=$(grep -cE 'FAIL[[:space:]]*[:=]?[[:space:]]*[1-9]|FAIL\(bypass\)|FAIL\(FP\)' "$log")

  # Per-harness tolerance for intentional/documented FAILs:
  # - fw044-verify.sh: up to 8 "FAILs" (SP1-4, B2, HD1, PA-D1, PA-D2 now block
  #   per FW-051 Phase 1 — harness labels them "deferred to FW-051" but they
  #   are closed now).
  # - fw051-baseline.sh: up to 2 "FAILs" (AC-9 VAR-concat non-exploit + AC-3
  #   subshell-eval deferred to FW-040 Phase B).
  case "$harness" in
    fw044-verify.sh)         tolerate=8; note="FW-051-closures ok" ;;
    fw051-baseline.sh)       tolerate=2; note="AC-9+AC-3 accepted-deferred" ;;
    *)                       tolerate=0; note="" ;;
  esac
  # Accept ec up to the tolerance count (some harnesses exit with FAIL count
  # as their exit code). ec=0 always OK; ec>tolerate is a real regression.
  if [ "$fail_signal" -le "$tolerate" ] && [ "$ec" -le "$tolerate" ]; then
    if [ -n "$note" ] && { [ "$fail_signal" -gt 0 ] || [ "$ec" -gt 0 ]; }; then
      status="PASS ($note)"
    else
      status="PASS"
    fi
    PASSED=$((PASSED + 1))
  else
    status="FAIL (ec=$ec fail-lines=$fail_signal)"
    OVERALL_FAIL=1
  fi

  printf "  [%-28s] %-32s %s\n" "$status" "$harness" "$summary"
done

echo ""
echo "=== Result ==="
echo "Harnesses: $PASSED / $TOTAL_HARNESSES passed"
if [ "$OVERALL_FAIL" -ne 0 ]; then
  echo "STATUS: REGRESSION DETECTED — inspect $LOG_DIR/*.log"
  exit 1
fi
echo "STATUS: ALL GREEN"
exit 0
