#!/bin/bash
# test-triggers.sh — unit tests for lib/triggers.sh
# Covers: trigger_send, trigger_read, trigger_read_pending, trigger_ack,
# trigger_count. Uses a throwaway test-scoped officer so real streams
# are not perturbed. Requires redis running on REDIS_HOST:REDIS_PORT.
#
# Run: bash /opt/founders-cabinet/cabinet/scripts/test-triggers.sh
# Exit 0 on all PASS, 1 on any FAIL.

set -uo pipefail

TEST_OFFICER="test-trg-$$-$(date +%s)"
TRIG_REDIS_HOST="${REDIS_HOST:-redis}"
TRIG_REDIS_PORT="${REDIS_PORT:-6379}"
STREAM="cabinet:triggers:${TEST_OFFICER}"
GROUP="officer-${TEST_OFFICER}"

PASS=0
FAIL=0
FAILURES=()

assert() {
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

assert_nonempty() {
  local label="$1"; local actual="$2"
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
  local label="$1"; local haystack="$2"; local needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: '$needle' not found in output")
    printf "  [FAIL] %s: '%s' not in output\n" "$label" "$needle"
  fi
}

cleanup() {
  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" DEL "$STREAM" > /dev/null 2>&1
  rm -f "/tmp/.trigger_ids_${TEST_OFFICER}"
}
trap cleanup EXIT

. /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh

echo "=== trigger_send ==="
OFFICER_NAME=sender-a trigger_send "$TEST_OFFICER" "hello from A"
STREAM_LEN=$(redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" XLEN "$STREAM")
assert "trigger_send adds to stream (len=1)" "$STREAM_LEN" "1"

OFFICER_NAME=sender-b trigger_send "$TEST_OFFICER" "message from B"
STREAM_LEN=$(redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" XLEN "$STREAM")
assert "second trigger_send appends (len=2)" "$STREAM_LEN" "2"

# Verify sender + timestamp metadata embedded
ENTRIES=$(redis-cli --raw -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" XRANGE "$STREAM" - +)
assert_contains "stream carries sender=sender-a" "$ENTRIES" "sender-a"
assert_contains "stream carries sender=sender-b" "$ENTRIES" "sender-b"
assert_contains "message body preserved" "$ENTRIES" "hello from A"
assert_contains "message body preserved (B)" "$ENTRIES" "message from B"
assert_contains "timestamp prefix [YYYY-MM-DD present" "$ENTRIES" "UTC] From sender-a"

echo ""
echo "=== trigger_count (pending before read) ==="
PENDING=$(trigger_count "$TEST_OFFICER")
assert "count=0 before any read (messages not yet delivered to consumer)" "$PENDING" "0"

echo ""
echo "=== trigger_read (delivers both) ==="
READ_OUT=$(trigger_read "$TEST_OFFICER")
assert_contains "read output contains msg A body" "$READ_OUT" "hello from A"
assert_contains "read output contains msg B body" "$READ_OUT" "message from B"

IDS=$(cat "/tmp/.trigger_ids_${TEST_OFFICER}")
IDS_TRIMMED=$(echo "$IDS" | xargs)
ID_COUNT=$(echo "$IDS_TRIMMED" | awk '{print NF}')
assert "IDs file has 2 message IDs" "$ID_COUNT" "2"

# IDs should match the Redis-stream format: millis-seq
for id in $IDS_TRIMMED; do
  if echo "$id" | grep -qE '^[0-9]+-[0-9]+$'; then
    :
  else
    FAIL=$((FAIL+1))
    FAILURES+=("ID '$id' not in millis-seq format")
    printf "  [FAIL] ID format: %s\n" "$id"
  fi
done
PASS=$((PASS+1))
printf "  [PASS] both IDs match millis-seq format\n"

echo ""
echo "=== trigger_count (pending after read, before ACK) ==="
PENDING=$(trigger_count "$TEST_OFFICER")
assert "count=2 after read, before ACK" "$PENDING" "2"

echo ""
echo "=== trigger_read returns empty second time (all delivered) ==="
READ_AGAIN=$(trigger_read "$TEST_OFFICER")
RC=$?
assert "re-read returns exit 1 (no new messages)" "$RC" "1"
assert "re-read output is empty" "$READ_AGAIN" ""

echo ""
echo "=== trigger_read_pending (crash-recovery path) ==="
PENDING_OUT=$(trigger_read_pending "$TEST_OFFICER")
assert_contains "pending read recovers msg A" "$PENDING_OUT" "hello from A"
assert_contains "pending read recovers msg B" "$PENDING_OUT" "message from B"

echo ""
echo "=== trigger_ack ==="
trigger_ack "$TEST_OFFICER" "$IDS_TRIMMED"
PENDING=$(trigger_count "$TEST_OFFICER")
assert "count=0 after ACK" "$PENDING" "0"

# Post-ACK read should still be empty
READ_POST_ACK=$(trigger_read_pending "$TEST_OFFICER")
assert "pending read empty after ACK" "$READ_POST_ACK" ""

echo ""
echo "=== trigger_ack no-op on empty IDs ==="
# Should not error out, should not crash
trigger_ack "$TEST_OFFICER" ""
RC=$?
assert "trigger_ack with empty IDs exits 0 gracefully" "$RC" "0"

echo ""
echo "=== trigger_send with default OFFICER_NAME (unknown fallback) ==="
unset OFFICER_NAME
OTHER_OFFICER="${TEST_OFFICER}-2"
OTHER_STREAM="cabinet:triggers:${OTHER_OFFICER}"
trigger_send "$OTHER_OFFICER" "no-sender-set"
FALLBACK_ENTRIES=$(redis-cli --raw -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" XRANGE "$OTHER_STREAM" - +)
assert_contains "fallback sender=unknown when OFFICER_NAME unset" "$FALLBACK_ENTRIES" "unknown"
redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" DEL "$OTHER_STREAM" > /dev/null

echo ""
echo "=== trigger_count on never-written stream (defensive init) ==="
NEW_OFFICER="${TEST_OFFICER}-3"
PENDING=$(trigger_count "$NEW_OFFICER")
assert "count=0 on fresh stream (XGROUP CREATE MKSTREAM defensive)" "$PENDING" "0"
redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" DEL "cabinet:triggers:${NEW_OFFICER}" > /dev/null

echo ""
echo "=== trigger_read on never-written stream ==="
READ_NEW=$(trigger_read "$NEW_OFFICER")
RC=$?
assert "read fresh stream returns exit 1" "$RC" "1"
assert "read fresh stream yields empty" "$READ_NEW" ""
redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" DEL "cabinet:triggers:${NEW_OFFICER}" > /dev/null
rm -f "/tmp/.trigger_ids_${NEW_OFFICER}"

echo ""
echo "=== Summary ==="
echo "PASS: $PASS | FAIL: $FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "STATUS: ALL PASSED"
  exit 0
else
  echo "STATUS: FAILED"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
