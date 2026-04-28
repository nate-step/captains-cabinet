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
echo "=== FW-074 (Pool Phase 1B) — per-(officer, project) stream routing ==="

# Pool-mode tests use a separate test officer + project slug to keep
# isolation from the legacy-mode tests above. Cleanup via trap appends.
POOL_OFFICER="test-trg-pool-$$-$(date +%s)"
POOL_PROJECT="testproj"
POOL_STREAM="cabinet:triggers:${POOL_OFFICER}:${POOL_PROJECT}"
POOL_GROUP="officer-${POOL_OFFICER}-${POOL_PROJECT}"
LEGACY_STREAM="cabinet:triggers:${POOL_OFFICER}"

# Augment cleanup. Includes the otherproj stream T-pool-4 creates via the
# XGROUP MKSTREAM side-effect of trigger_read — if the test aborts mid-flight
# under set -uo pipefail, the trap still wipes that stream.
_pool_cleanup() {
  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" DEL \
    "$POOL_STREAM" "$LEGACY_STREAM" \
    "cabinet:triggers:${POOL_OFFICER}:otherproj" > /dev/null 2>&1
  rm -f "/tmp/.trigger_ids_${POOL_OFFICER}" \
    "/tmp/.trigger_ids_${POOL_OFFICER}_${POOL_PROJECT}" \
    "/tmp/.trigger_ids_${POOL_OFFICER}_otherproj"
}
trap '_pool_cleanup; cleanup' EXIT

# T-pool-1: trigger_send under CABINET_ACTIVE_PROJECT routes to per-project stream
CABINET_ACTIVE_PROJECT="$POOL_PROJECT" OFFICER_NAME=pool-sender \
  trigger_send "$POOL_OFFICER" "pool message"
POOL_LEN=$(redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" XLEN "$POOL_STREAM")
LEG_LEN=$(redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" XLEN "$LEGACY_STREAM" 2>/dev/null || echo 0)
assert "pool send writes to per-project stream (len=1)" "$POOL_LEN" "1"
assert "pool send does NOT write to legacy stream" "$LEG_LEN" "0"

# T-pool-2: trigger_read under matching CABINET_ACTIVE_PROJECT reads it
POOL_READ=$(CABINET_ACTIVE_PROJECT="$POOL_PROJECT" trigger_read "$POOL_OFFICER")
assert_contains "pool read sees the pool message" "$POOL_READ" "pool message"

# T-pool-3: legacy read (no env) on same officer does NOT see pool message
unset CABINET_ACTIVE_PROJECT
LEGACY_READ=$(trigger_read "$POOL_OFFICER")
LEGACY_RC=$?
assert "legacy read on pool officer returns exit 1 (empty)" "$LEGACY_RC" "1"
assert "legacy read does NOT see pool message" "$LEGACY_READ" ""

# T-pool-4: cross-project — different project's read does NOT see this project
CROSS_READ=$(CABINET_ACTIVE_PROJECT="otherproj" trigger_read "$POOL_OFFICER")
CROSS_RC=$?
assert "cross-project read returns exit 1" "$CROSS_RC" "1"
assert "cross-project read does NOT see this project's message" "$CROSS_READ" ""
# Cleanup the cross-project stream the read created via XGROUP CREATE
redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" DEL \
  "cabinet:triggers:${POOL_OFFICER}:otherproj" > /dev/null 2>&1

# T-pool-5: trigger_count counts in the right (project) group
POOL_PENDING=$(CABINET_ACTIVE_PROJECT="$POOL_PROJECT" trigger_count "$POOL_OFFICER")
assert "pool trigger_count after read=2 pending" "$POOL_PENDING" "1"

# T-pool-6: trigger_ack under matching project clears the right group.
# Use trigger_ids_path so we read from the per-(officer, project) file
# (FW-074 file-path collision fix — see _trigger_keys docstring).
POOL_IDS_PATH=$(CABINET_ACTIVE_PROJECT="$POOL_PROJECT" trigger_ids_path "$POOL_OFFICER")
POOL_IDS=$(cat "$POOL_IDS_PATH" | xargs)
CABINET_ACTIVE_PROJECT="$POOL_PROJECT" trigger_ack "$POOL_OFFICER" "$POOL_IDS"
POST_ACK=$(CABINET_ACTIVE_PROJECT="$POOL_PROJECT" trigger_count "$POOL_OFFICER")
assert "pool trigger_ack drops pending to 0" "$POST_ACK" "0"

# T-pool-7: malformed slug falls back to legacy stream (defensive — never
# emit a malformed Redis key even if env var is corrupted). Covers both
# bad-charset and length-cap-exceeded paths.
CABINET_ACTIVE_PROJECT="UPPER_BAD!" OFFICER_NAME=defensive-sender \
  trigger_send "$POOL_OFFICER" "fallback to legacy"
LEG_LEN_AFTER=$(redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" XLEN "$LEGACY_STREAM" 2>/dev/null || echo 0)
assert "malformed CABINET_ACTIVE_PROJECT charset falls back to legacy" "$LEG_LEN_AFTER" "1"

# 33-char slug (passes regex but fails length cap) also falls back
LONG_PROJ=$(printf 'a%.0s' {1..33})
CABINET_ACTIVE_PROJECT="$LONG_PROJ" OFFICER_NAME=defensive-sender \
  trigger_send "$POOL_OFFICER" "33-char slug fallback"
LEG_LEN_AFTER=$(redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" XLEN "$LEGACY_STREAM" 2>/dev/null || echo 0)
assert "33-char CABINET_ACTIVE_PROJECT falls back to legacy (length cap)" "$LEG_LEN_AFTER" "2"
redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" DEL "$LEGACY_STREAM" > /dev/null 2>&1

# T-pool-8: pool-mode trigger_read_pending (crash recovery). Send + read
# (deliver to consumer, leaves it pending). Then re-read via _pending —
# must surface the same message even though the new-message cursor is
# already past it. This is the pod-restart code path.
CABINET_ACTIVE_PROJECT="$POOL_PROJECT" OFFICER_NAME=pool-sender \
  trigger_send "$POOL_OFFICER" "crash-recovery probe"
CABINET_ACTIVE_PROJECT="$POOL_PROJECT" trigger_read "$POOL_OFFICER" > /dev/null
PENDING_OUT=$(CABINET_ACTIVE_PROJECT="$POOL_PROJECT" trigger_read_pending "$POOL_OFFICER")
assert_contains "pool trigger_read_pending recovers pending message" \
  "$PENDING_OUT" "crash-recovery probe"

# T-pool-9: trigger_ids_path with no arg returns rc=1 + stderr message
TIP_OUT=$(trigger_ids_path 2>&1)
TIP_RC=$?
assert "trigger_ids_path no-arg returns rc=1" "$TIP_RC" "1"
assert_contains "trigger_ids_path no-arg emits diagnostic" "$TIP_OUT" "officer argument required"

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
