#!/bin/bash
# test-captain-attention.sh — FW-084 captain-attention.sh harness (Spec 034 v3 AC #74)
#
# ≥8 assertions covering:
#   T1: captain_attention_push with valid urgency succeeds; XADD writes to stream
#   T2: captain_attention_push with bad urgency rejected (urgency guard)
#   T3: captain_attention_push slug guard (project must match regex / 32-char cap)
#   T4: captain_attention_read returns pending entries via consumer group
#   T5: captain_attention_ack with disposition=handled (no notify, no forward)
#   T6: captain_attention_ack with disposition=forwarded triggers notify-officer to source
#   T7: audit log entry written per ack with source + payload + disposition + captain_reply
#   T8: idempotent ack (re-ack same entry_id is safe)
#   T9 (bonus): captain_attention_push bad project slug rejected
#  T10 (bonus): captain_attention_ack bad disposition rejected
#  T11 (bonus): captain_attention_ack bad entry_id format rejected
#  T12 (bonus): captain_attention_scan returns non-zero when queue empty
#
# All assertions use a throwaway test-scoped project slug so real streams
# are not perturbed. Requires redis running on REDIS_HOST:REDIS_PORT.
# notify-officer.sh forwarding test uses CABINET_HOOK_TEST_MODE=1 env to
# prevent real trigger fan-out.
#
# Run: bash /opt/founders-cabinet/cabinet/scripts/test-captain-attention.sh
# Exit 0 on all PASS, 1 on any FAIL.

set -uo pipefail

CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
CATN_LIB="$CABINET_ROOT/cabinet/scripts/lib/captain-attention.sh"

# Use a unique ephemeral project slug per test run
TEST_SLUG="test-catn-$$-$(date +%s | tail -c 6)"
# Ensure slug is ≤32 chars and valid
TEST_SLUG="${TEST_SLUG:0:32}"

PASS=0
FAIL=0
FAILURES=()

# ---------------------------------------------------------------------------
# Assert helpers (mirrors test-triggers.sh pattern)
# ---------------------------------------------------------------------------
assert() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: expected='$expected' actual='$actual'")
    printf "  [FAIL] %s: expected='%s' actual='%s'\n" "$label" "$expected" "$actual"
  fi
}

assert_eq() { assert "$1" "$2" "$3"; }

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

assert_nonempty() {
  local label="$1" actual="$2"
  if [ -n "$actual" ]; then
    PASS=$((PASS+1))
    printf "  [PASS] %s (non-empty)\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: expected non-empty, got empty")
    printf "  [FAIL] %s (expected non-empty)\n" "$label"
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
    printf "  [FAIL] %s: '%s' not in output\n" "$label" "$needle"
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
    printf "  [FAIL] %s: '%s' found in output (should not)\n" "$label" "$needle"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: file '$path' does not exist")
    printf "  [FAIL] %s: file '%s' does not exist\n" "$label" "$path"
  fi
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  local stream="cabinet:captain-attention:${TEST_SLUG}"
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "$stream" > /dev/null 2>&1 || true
  rm -f "/tmp/.captain_attention_ids_${TEST_SLUG}"
  # Remove test audit log
  local log_dir="$CABINET_ROOT/cabinet/logs/captain-attention"
  rm -f "${log_dir}/${TEST_SLUG}.jsonl" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight: Redis + library
# ---------------------------------------------------------------------------
if ! redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" PING > /dev/null 2>&1; then
  echo "SKIP: Redis not reachable at ${REDIS_HOST}:${REDIS_PORT} — cannot run captain-attention tests"
  exit 0
fi

if [ ! -f "$CATN_LIB" ]; then
  echo "FAIL: captain-attention.sh library not found at $CATN_LIB"
  exit 1
fi

# Source the library under test
# shellcheck disable=SC1090
. "$CATN_LIB"

STREAM="cabinet:captain-attention:${TEST_SLUG}"

echo ""
echo "=== test-captain-attention.sh ==="
echo "Test slug: $TEST_SLUG"
echo ""

# ---------------------------------------------------------------------------
# T1: captain_attention_push with valid urgency succeeds; XADD writes to stream
# ---------------------------------------------------------------------------
echo "T1: captain_attention_push valid urgency — stream write"

OFFICER_NAME="test-cto" captain_attention_push \
  "$TEST_SLUG" "high" "Prod deploy blocked" "Neon timeout on startup"; push_rc=$?
assert_exit "T1.1 push returns 0" "$push_rc" 0

stream_len=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" XLEN "$STREAM")
assert "T1.2 stream has 1 entry after push" "$stream_len" "1"

# Check stream contents
entries=$(redis-cli --raw -h "$REDIS_HOST" -p "$REDIS_PORT" XRANGE "$STREAM" - +)
assert_contains "T1.3 stream contains source officer" "$entries" "test-cto"
assert_contains "T1.4 stream contains urgency=high" "$entries" "high"
assert_contains "T1.5 stream contains summary" "$entries" "Prod deploy blocked"

# Second push (medium urgency, different officer)
OFFICER_NAME="test-coo" captain_attention_push \
  "$TEST_SLUG" "medium" "Vercel health check failing" "3 consecutive 503s"; push_rc2=$?
assert_exit "T1.6 second push returns 0" "$push_rc2" 0

stream_len2=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" XLEN "$STREAM")
assert "T1.7 stream has 2 entries after second push" "$stream_len2" "2"

# ---------------------------------------------------------------------------
# T2: captain_attention_push with bad urgency rejected
# ---------------------------------------------------------------------------
echo ""
echo "T2: captain_attention_push bad urgency rejected"

bad_urgency_out=$(OFFICER_NAME="test-cto" captain_attention_push \
  "$TEST_SLUG" "critical" "Bad urgency test" "body" 2>&1); bad_rc=$?
assert_exit "T2.1 bad urgency exits non-zero" "$bad_rc" 1
assert_contains "T2.2 error message mentions urgency" "$bad_urgency_out" "urgency"
assert_contains "T2.3 error shows allowlist" "$bad_urgency_out" "low medium high blocking"

# Empty urgency also rejected
empty_urg_out=$(OFFICER_NAME="test-cto" captain_attention_push \
  "$TEST_SLUG" "" "test" "test" 2>&1); empty_urg_rc=$?
assert_exit "T2.4 empty urgency exits non-zero" "$empty_urg_rc" 1

# Stream length unchanged (no XADD on bad urgency)
stream_len_t2=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" XLEN "$STREAM")
assert "T2.5 stream unchanged after bad urgency push" "$stream_len_t2" "2"

# ---------------------------------------------------------------------------
# T3: captain_attention_push slug guard
# ---------------------------------------------------------------------------
echo ""
echo "T3: captain_attention_push slug guard"

# Invalid slug: uppercase
bad_slug_out=$(OFFICER_NAME="test-cto" captain_attention_push \
  "INVALID_SLUG" "high" "test" "test" 2>&1); bad_slug_rc=$?
assert_exit "T3.1 uppercase slug exits non-zero" "$bad_slug_rc" 1
assert_contains "T3.2 error mentions slug" "$bad_slug_out" "slug"

# Invalid slug: leading hyphen
leading_hyph_out=$(OFFICER_NAME="test-cto" captain_attention_push \
  "-bad-slug" "high" "test" "test" 2>&1); leading_hyph_rc=$?
assert_exit "T3.3 leading-hyphen slug exits non-zero" "$leading_hyph_rc" 1

# Invalid slug: >32 chars
long_slug="a$(printf 'b%.0s' {1..32})"  # 33 chars
long_slug_out=$(OFFICER_NAME="test-cto" captain_attention_push \
  "$long_slug" "high" "test" "test" 2>&1); long_slug_rc=$?
assert_exit "T3.4 over-32-char slug exits non-zero" "$long_slug_rc" 1
assert_contains "T3.5 over-32-char slug error mentions length" "$long_slug_out" "32"

# Empty slug
empty_slug_out=$(OFFICER_NAME="test-cto" captain_attention_push \
  "" "high" "test" "test" 2>&1); empty_slug_rc=$?
assert_exit "T3.6 empty slug exits non-zero" "$empty_slug_rc" 1

# ---------------------------------------------------------------------------
# T4: captain_attention_read returns pending entries via consumer group
# ---------------------------------------------------------------------------
echo ""
echo "T4: captain_attention_read — consumer group delivery"

# Reset stream for clean read test
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "$STREAM" > /dev/null 2>&1

# Push a fresh known payload
OFFICER_NAME="test-cpo" captain_attention_push \
  "$TEST_SLUG" "blocking" "Captain approval needed for billing" "Stripe subscription expired"

read_output=$(captain_attention_read "$TEST_SLUG"); read_rc=$?
assert_exit "T4.1 captain_attention_read returns 0 (entries found)" "$read_rc" 0
assert_nonempty "T4.2 read output is non-empty" "$read_output"
assert_contains "T4.3 read output contains JSON entry_id" "$read_output" "entry_id"
assert_contains "T4.4 read output contains source=test-cpo" "$read_output" "test-cpo"
assert_contains "T4.5 read output contains urgency=blocking" "$read_output" "blocking"
assert_contains "T4.6 read output contains summary" "$read_output" "Captain approval needed"

# IDs file written
ids_file="/tmp/.captain_attention_ids_${TEST_SLUG}"
assert_file_exists "T4.7 IDs file written after read" "$ids_file"
ids_content=$(cat "$ids_file" 2>/dev/null || echo "")
assert_nonempty "T4.8 IDs file has content" "$ids_content"

# Extract the entry_id from the JSON output for use in T5/T6/T7/T8
FIRST_ENTRY_ID=$(echo "$read_output" | grep -o '"entry_id":"[^"]*"' | head -1 | sed 's/"entry_id":"//;s/"//')

# ---------------------------------------------------------------------------
# T5: captain_attention_ack disposition=handled (no notify, no forward)
# ---------------------------------------------------------------------------
echo ""
echo "T5: captain_attention_ack disposition=handled"

if [ -z "$FIRST_ENTRY_ID" ]; then
  echo "  [SKIP] No entry_id extracted from T4 read — skipping T5/T6/T7"
  FAIL=$((FAIL+1))
  FAILURES+=("T5: could not extract entry_id from captain_attention_read output")
else
  ack_out=$(OFFICER_NAME="test-cos" captain_attention_ack \
    "$TEST_SLUG" "$FIRST_ENTRY_ID" "handled" "" 2>&1); ack_rc=$?
  assert_exit "T5.1 ack handled returns 0" "$ack_rc" 0

  # Verify XACK: pending count should drop to 0
  pending_after=$(redis-cli --raw -h "$REDIS_HOST" -p "$REDIS_PORT" \
    XPENDING "$STREAM" "ceo-reader-${TEST_SLUG}" 2>/dev/null | head -1)
  assert "T5.2 pending count is 0 after ack" "${pending_after:-0}" "0"

  # No notify-officer triggered (handled — no forwarding)
  assert_not_contains "T5.3 handled disposition does not forward" "$ack_out" "CAPTAIN REPLY"
fi

# ---------------------------------------------------------------------------
# T6: captain_attention_ack disposition=forwarded triggers notify-officer to source
# ---------------------------------------------------------------------------
echo ""
echo "T6: captain_attention_ack disposition=forwarded — routes to source"

# Push a new entry for forwarding test
OFFICER_NAME="test-cro" captain_attention_push \
  "$TEST_SLUG" "high" "Research finding for Captain" "New competitor launched"

read_output2=$(captain_attention_read "$TEST_SLUG"); _rc2=$?
FWD_ENTRY_ID=$(echo "$read_output2" | grep -o '"entry_id":"[^"]*"' | head -1 | sed 's/"entry_id":"//;s/"//')

if [ -z "$FWD_ENTRY_ID" ]; then
  echo "  [SKIP] No entry_id for T6"
  FAIL=$((FAIL+1))
  FAILURES+=("T6: could not extract entry_id for forwarded test")
else
  # Mock notify-officer.sh: replace with a test double that records calls
  # We use CABINET_HOOK_TEST_MODE=1 style approach: override via env in subshell
  _MOCK_NOTIFY_LOG="/tmp/.test-catn-notify-$$.log"
  rm -f "$_MOCK_NOTIFY_LOG"

  # Override notify-officer.sh path by temporarily pointing CATN_CABINET_ROOT
  # to a temp dir with a mock script. Use a subshell to isolate.
  _MOCK_CABINET="$(mktemp -d)"
  mkdir -p "$_MOCK_CABINET/cabinet/scripts"
  cat > "$_MOCK_CABINET/cabinet/scripts/notify-officer.sh" <<'MOCK'
#!/bin/bash
echo "MOCK_NOTIFY: target=$1 message=$2" >> "/tmp/.test-catn-notify-${MOCK_LOG_SUFFIX:-test}.log"
MOCK
  chmod +x "$_MOCK_CABINET/cabinet/scripts/notify-officer.sh"

  MOCK_LOG_SUFFIX="$$" CATN_CABINET_ROOT="$_MOCK_CABINET" \
    OFFICER_NAME="test-cos" captain_attention_ack \
    "$TEST_SLUG" "$FWD_ENTRY_ID" "forwarded" "Captain says: approved" > /dev/null 2>&1
  fwd_ack_rc=$?
  assert_exit "T6.1 forwarded ack returns 0" "$fwd_ack_rc" 0

  # Check that notify-officer was invoked with the source officer
  fwd_notify_log="$_MOCK_CABINET/cabinet/logs/captain-attention/${TEST_SLUG}.jsonl"
  notify_actual=$(cat "$_MOCK_NOTIFY_LOG" 2>/dev/null || echo "")
  assert_contains "T6.2 notify-officer called with source officer" "$notify_actual" "test-cro"
  assert_contains "T6.3 notify-officer called with captain reply" "$notify_actual" "Captain says: approved"

  rm -rf "$_MOCK_CABINET" "$_MOCK_NOTIFY_LOG" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# T7: audit log entry written per ack with source + payload + disposition + captain_reply
# ---------------------------------------------------------------------------
echo ""
echo "T7: audit log entry written per ack"

audit_log="$CABINET_ROOT/cabinet/logs/captain-attention/${TEST_SLUG}.jsonl"

# The ack calls in T5 and the forwarded ack in T6 (real, using real CABINET_ROOT)
# should have written entries. Push + ack one more to ensure we have a real log entry.
OFFICER_NAME="test-cto" captain_attention_push \
  "$TEST_SLUG" "low" "Low priority note" "FYI only"
read_output3=$(captain_attention_read "$TEST_SLUG")
AUDIT_ENTRY_ID=$(echo "$read_output3" | grep -o '"entry_id":"[^"]*"' | head -1 | sed 's/"entry_id":"//;s/"//')

if [ -n "$AUDIT_ENTRY_ID" ]; then
  OFFICER_NAME="test-cos" captain_attention_ack \
    "$TEST_SLUG" "$AUDIT_ENTRY_ID" "handled" "" > /dev/null 2>&1

  assert_file_exists "T7.1 audit log file exists" "$audit_log"
  if [ -f "$audit_log" ]; then
    log_content=$(cat "$audit_log")
    assert_contains "T7.2 audit log has project field" "$log_content" "\"project\""
    assert_contains "T7.3 audit log has entry_id field" "$log_content" "\"entry_id\""
    assert_contains "T7.4 audit log has disposition field" "$log_content" "\"disposition\""
    assert_contains "T7.5 audit log has source field" "$log_content" "\"source\""
    assert_contains "T7.6 audit log has ts field" "$log_content" "\"ts\""
    assert_contains "T7.7 audit log records ceo officer" "$log_content" "test-cos"
  fi
else
  echo "  [SKIP] No entry_id for T7 audit log test"
  FAIL=$((FAIL+1))
  FAILURES+=("T7: could not extract entry_id for audit test")
fi

# ---------------------------------------------------------------------------
# T8: idempotent ack (re-ack same entry_id is safe)
# ---------------------------------------------------------------------------
echo ""
echo "T8: idempotent ack — re-ack same entry_id"

# Use AUDIT_ENTRY_ID from T7 (already acked)
if [ -n "${AUDIT_ENTRY_ID:-}" ]; then
  reack_out=$(OFFICER_NAME="test-cos" captain_attention_ack \
    "$TEST_SLUG" "$AUDIT_ENTRY_ID" "handled" "" 2>&1); reack_rc=$?
  # XACK is idempotent in Redis — should return 0 even for already-acked entry
  assert_exit "T8.1 re-ack same entry_id returns 0 (idempotent)" "$reack_rc" 0
  assert_not_contains "T8.2 re-ack does not error" "$reack_out" "ERROR"
else
  echo "  [SKIP] No entry_id for T8 idempotent ack test"
  FAIL=$((FAIL+1))
  FAILURES+=("T8: no AUDIT_ENTRY_ID from T7")
fi

# ---------------------------------------------------------------------------
# T9 (bonus): captain_attention_push bad project slug types
# ---------------------------------------------------------------------------
echo ""
echo "T9: additional slug guard scenarios"

# Space in slug
space_out=$(OFFICER_NAME="test-cto" captain_attention_push \
  "bad slug" "high" "test" "test" 2>&1); space_rc=$?
assert_exit "T9.1 space in slug exits non-zero" "$space_rc" 1

# Slug with path traversal chars
traversal_out=$(OFFICER_NAME="test-cto" captain_attention_push \
  "../evil" "high" "test" "test" 2>&1); traversal_rc=$?
assert_exit "T9.2 path-traversal slug exits non-zero" "$traversal_rc" 1

# Valid 32-char slug works
valid32="$(printf 'a%.0s' {1..32})"  # exactly 32 chars
OFFICER_NAME="test-cto" captain_attention_push \
  "$valid32" "low" "test" "test" > /dev/null 2>&1; valid32_rc=$?
assert_exit "T9.3 exactly-32-char slug accepted" "$valid32_rc" 0
# Cleanup the test stream for the 32-char slug
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "cabinet:captain-attention:${valid32}" > /dev/null 2>&1

# ---------------------------------------------------------------------------
# T10 (bonus): captain_attention_ack bad disposition rejected
# ---------------------------------------------------------------------------
echo ""
echo "T10: captain_attention_ack bad disposition rejected"

bad_disp_out=$(OFFICER_NAME="test-cos" captain_attention_ack \
  "$TEST_SLUG" "1234567890-0" "ignored" "" 2>&1); bad_disp_rc=$?
assert_exit "T10.1 bad disposition exits non-zero" "$bad_disp_rc" 1
assert_contains "T10.2 error mentions disposition" "$bad_disp_out" "disposition"

# ---------------------------------------------------------------------------
# T11 (bonus): captain_attention_ack bad entry_id format rejected
# ---------------------------------------------------------------------------
echo ""
echo "T11: captain_attention_ack bad entry_id format rejected"

bad_eid_out=$(OFFICER_NAME="test-cos" captain_attention_ack \
  "$TEST_SLUG" "not-an-id" "handled" "" 2>&1); bad_eid_rc=$?
assert_exit "T11.1 malformed entry_id exits non-zero" "$bad_eid_rc" 1
assert_contains "T11.2 error mentions entry_id format" "$bad_eid_out" "entry_id"

# ---------------------------------------------------------------------------
# T12 (bonus): captain_attention_scan returns non-zero when queue empty
# ---------------------------------------------------------------------------
echo ""
echo "T12: captain_attention_scan — empty queue returns non-zero"

# Use a brand-new slug that has never been pushed to
EMPTY_SLUG="test-empty-$$"
EMPTY_SLUG="${EMPTY_SLUG:0:32}"
scan_out=$(captain_attention_scan "$EMPTY_SLUG" 2>/dev/null); scan_rc=$?
assert_exit "T12.1 scan on empty queue returns 1 (no entries)" "$scan_rc" 1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "cabinet:captain-attention:${EMPTY_SLUG}" > /dev/null 2>&1

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== captain-attention test results ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
echo ""

if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  echo ""
fi

[ "$FAIL" -eq 0 ]
