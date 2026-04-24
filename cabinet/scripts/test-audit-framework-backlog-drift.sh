#!/bin/bash
# test-audit-framework-backlog-drift.sh — unit tests for the drift auditor.
#
# The auditor (audit-framework-backlog-drift.sh) parses shared/cabinet-
# framework-backlog.md for Status: Proposed/Paused entries and flags any
# whose embedded filing date exceeds threshold. If the auditor silently
# breaks (awk regex drift, date-parse edge case, output format regression)
# we lose the FW-002 drift-class safety net.
#
# Fixtures exercise: fresh vs stale, Proposed vs Paused, SHIPPED-skip,
# no-date-skip, env threshold overrides, missing-file handling, output
# format markers.
#
# Run: bash /opt/founders-cabinet/cabinet/scripts/test-audit-framework-backlog-drift.sh
# Exit 0 on all PASS, 1 on any FAIL.

set -uo pipefail

AUDITOR="/opt/founders-cabinet/cabinet/scripts/audit-framework-backlog-drift.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
FAILURES=()

# Absolute dates anchored on 2026-04-24 (the ship-day of this auditor).
# Using `date -u -d` to compute so the test is stable if the system clock
# drifts: we measure relative to "now" inside the auditor too.
D_TODAY=$(date -u +%Y-%m-%d)
D_2D_AGO=$(date -u -d "2 days ago" +%Y-%m-%d)
D_5D_AGO=$(date -u -d "5 days ago" +%Y-%m-%d)
D_10D_AGO=$(date -u -d "10 days ago" +%Y-%m-%d)
D_20D_AGO=$(date -u -d "20 days ago" +%Y-%m-%d)
D_60D_AGO=$(date -u -d "60 days ago" +%Y-%m-%d)

assert_contains() {
  local label="$1"; local haystack="$2"; local needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: needle='$needle' missing from output")
    printf "  [FAIL] %s: needle='%s' missing\n" "$label" "$needle"
    printf "         haystack: %s\n" "$haystack"
  fi
}

assert_not_contains() {
  local label="$1"; local haystack="$2"; local needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    FAIL=$((FAIL+1))
    FAILURES+=("$label: unexpected needle='$needle' in output")
    printf "  [FAIL] %s: unexpected needle='%s'\n" "$label" "$needle"
    printf "         haystack: %s\n" "$haystack"
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

run_auditor() {
  local fixture="$1"
  shift
  BACKLOG="$fixture" "$@" bash "$AUDITOR" 2>&1
}

# ── Test 1: Fresh Proposed entries (< default 7d) are NOT flagged ─────────────
FIXTURE1="$TMP_DIR/fresh-proposed.md"
cat > "$FIXTURE1" <<EOF
### FW-900 fresh-proposed-test
- **Status:** Proposed ${D_2D_AGO} (test fixture — should not flag)
- **Body:** nothing.
EOF
OUT=$(run_auditor "$FIXTURE1")
echo "Test 1: fresh Proposed (${D_2D_AGO}) must NOT flag"
assert_contains "  no-stale-entries message" "$OUT" "no stale Proposed/Paused entries"
assert_not_contains "  FW-900 not flagged" "$OUT" "FW-900"

# ── Test 2: Stale Proposed entries (≥ 7d) ARE flagged ─────────────────────────
FIXTURE2="$TMP_DIR/stale-proposed.md"
cat > "$FIXTURE2" <<EOF
### FW-901 stale-proposed-test
- **Status:** Proposed ${D_10D_AGO} (should flag at default threshold)
- **Body:** nothing.
EOF
OUT=$(run_auditor "$FIXTURE2")
echo "Test 2: stale Proposed (${D_10D_AGO}, 10d) MUST flag"
assert_contains "  FW-901 flagged" "$OUT" "FW-901"
assert_contains "  Proposed marker" "$OUT" "Proposed"
assert_contains "  age= marker" "$OUT" "age="
assert_contains "  filed= marker with date" "$OUT" "filed=${D_10D_AGO}"
assert_contains "  review-candidates hint" "$OUT" "review candidates above"

# ── Test 3: Fresh Paused entries (< default 14d) are NOT flagged ──────────────
FIXTURE3="$TMP_DIR/fresh-paused.md"
cat > "$FIXTURE3" <<EOF
### FW-902 fresh-paused-test
- **Status:** Paused ${D_10D_AGO} (10d — under 14d Paused threshold)
- **Body:** nothing.
EOF
OUT=$(run_auditor "$FIXTURE3")
echo "Test 3: fresh Paused (${D_10D_AGO}, 10d < 14d) must NOT flag"
assert_contains "  no-stale-entries message" "$OUT" "no stale Proposed/Paused entries"
assert_not_contains "  FW-902 not flagged" "$OUT" "FW-902"

# ── Test 4: Stale Paused entries (≥ 14d) ARE flagged ──────────────────────────
FIXTURE4="$TMP_DIR/stale-paused.md"
cat > "$FIXTURE4" <<EOF
### FW-903 stale-paused-test
- **Status:** Paused ${D_20D_AGO} (20d — over 14d Paused threshold)
- **Body:** nothing.
EOF
OUT=$(run_auditor "$FIXTURE4")
echo "Test 4: stale Paused (${D_20D_AGO}, 20d) MUST flag"
assert_contains "  FW-903 flagged" "$OUT" "FW-903"
assert_contains "  Paused marker" "$OUT" "Paused"

# ── Test 5: SHIPPED/Active entries NOT flagged regardless of age ──────────────
FIXTURE5="$TMP_DIR/shipped-old.md"
cat > "$FIXTURE5" <<EOF
### FW-904 shipped-old-test
- **Status:** SHIPPED ${D_60D_AGO} (commit deadbeef, 60d old — must not flag)
- **Body:** nothing.

### FW-905 active-old-test
- **Status:** Active ${D_60D_AGO}
- **Body:** nothing.
EOF
OUT=$(run_auditor "$FIXTURE5")
echo "Test 5: SHIPPED/Active with old date must NOT flag (wrong kind)"
assert_contains "  no-stale-entries message" "$OUT" "no stale Proposed/Paused entries"
assert_not_contains "  FW-904 skipped" "$OUT" "FW-904"
assert_not_contains "  FW-905 skipped" "$OUT" "FW-905"

# ── Test 6: Proposed with no parseable date silently skipped ──────────────────
FIXTURE6="$TMP_DIR/no-date.md"
cat > "$FIXTURE6" <<EOF
### FW-906 no-date-test
- **Status:** Proposed (no filing date embedded)
- **Body:** nothing.
EOF
OUT=$(run_auditor "$FIXTURE6")
echo "Test 6: Proposed with no date → skipped (no flag, no error)"
assert_contains "  no-stale-entries message" "$OUT" "no stale Proposed/Paused entries"
assert_not_contains "  FW-906 not flagged" "$OUT" "FW-906"

# ── Test 7: PROPOSED_STALE_DAYS env override tightens threshold ───────────────
FIXTURE7="$TMP_DIR/env-override.md"
cat > "$FIXTURE7" <<EOF
### FW-907 env-override-test
- **Status:** Proposed ${D_2D_AGO} (2d — under default 7d, over tight 1d)
- **Body:** nothing.
EOF
OUT=$(PROPOSED_STALE_DAYS=1 run_auditor "$FIXTURE7")
echo "Test 7: PROPOSED_STALE_DAYS=1 flags 2d-old entry"
assert_contains "  FW-907 flagged under tight threshold" "$OUT" "FW-907"
# And same entry under default threshold must not flag
OUT_DEFAULT=$(run_auditor "$FIXTURE7")
assert_not_contains "  FW-907 not flagged under default" "$OUT_DEFAULT" "FW-907"

# ── Test 8: PAUSED_STALE_DAYS env override tightens Paused threshold ──────────
FIXTURE8="$TMP_DIR/paused-override.md"
cat > "$FIXTURE8" <<EOF
### FW-908 paused-override-test
- **Status:** Paused ${D_5D_AGO} (5d — under default 14d, over tight 3d)
- **Body:** nothing.
EOF
OUT=$(PAUSED_STALE_DAYS=3 run_auditor "$FIXTURE8")
echo "Test 8: PAUSED_STALE_DAYS=3 flags 5d-old Paused entry"
assert_contains "  FW-908 flagged under tight threshold" "$OUT" "FW-908"

# ── Test 9: Multiple entries — only stale ones flagged ────────────────────────
FIXTURE9="$TMP_DIR/mixed.md"
cat > "$FIXTURE9" <<EOF
### FW-909 mixed-fresh
- **Status:** Proposed ${D_2D_AGO}

### FW-910 mixed-stale-proposed
- **Status:** Proposed ${D_10D_AGO}

### FW-911 mixed-shipped
- **Status:** SHIPPED ${D_60D_AGO}

### FW-912 mixed-stale-paused
- **Status:** Paused ${D_20D_AGO}
EOF
OUT=$(run_auditor "$FIXTURE9")
echo "Test 9: mixed entries — only stale Proposed/Paused flagged"
assert_not_contains "  FW-909 fresh not flagged" "$OUT" "FW-909"
assert_contains   "  FW-910 stale Proposed flagged" "$OUT" "FW-910"
assert_not_contains "  FW-911 SHIPPED not flagged" "$OUT" "FW-911"
assert_contains   "  FW-912 stale Paused flagged" "$OUT" "FW-912"

# ── Test 10: Missing backlog file → exit 0, stderr message ────────────────────
echo "Test 10: missing backlog file → exit 0 + stderr message"
OUT=$(BACKLOG="/nonexistent/path/no-file.md" bash "$AUDITOR" 2>&1)
EXIT_CODE=$?
assert_eq "  exit code 0 (advisory)" "$EXIT_CODE" "0"
assert_contains "  not-found message on stderr" "$OUT" "not found"

# ── Test 11: Empty backlog → exit 0, no-stale message ─────────────────────────
FIXTURE11="$TMP_DIR/empty.md"
: > "$FIXTURE11"
OUT=$(run_auditor "$FIXTURE11")
EXIT_CODE=$?
echo "Test 11: empty backlog → exit 0 + no-stale message"
assert_eq "  exit code 0" "$EXIT_CODE" "0"
assert_contains "  no-stale message" "$OUT" "no stale Proposed/Paused entries"

# ── Test 12: Auditor always exits 0 (advisory, never blocks CI) ───────────────
echo "Test 12: advisory-only — exit 0 even when stale entries found"
OUT=$(run_auditor "$FIXTURE2")  # fixture2 has stale FW-901
EXIT_CODE=$?
assert_eq "  exit 0 with flagged entries" "$EXIT_CODE" "0"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
printf "==== %d PASS, %d FAIL ====\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf "\nFailures:\n"
  for f in "${FAILURES[@]}"; do printf "  - %s\n" "$f"; done
  exit 1
fi
exit 0
