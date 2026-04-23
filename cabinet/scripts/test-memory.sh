#!/bin/bash
# test-memory.sh — unit tests for lib/memory.sh
# Covers defensive input validation paths: empty-content rejection, invalid-
# metadata JSON fallback, queue-payload shape. Does NOT hit Voyage API or
# Neon — those require live credentials + are covered by integration tests.
# Focuses on the paths where validation bugs would silently corrupt the
# embedding queue or lose data.
#
# Run: bash /opt/founders-cabinet/cabinet/scripts/test-memory.sh
# Exit 0 on all PASS, 1 on any FAIL.

set -uo pipefail

TEST_QUEUE_KEY="cabinet:test:memory:embed_queue-$$-$(date +%s)"
MEM_REDIS_HOST="${REDIS_HOST:-redis}"
MEM_REDIS_PORT="${REDIS_PORT:-6379}"

PASS=0
FAIL=0
FAILURES=()

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
  redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" DEL "$TEST_QUEUE_KEY" > /dev/null 2>&1
}
trap cleanup EXIT

. /opt/founders-cabinet/cabinet/scripts/lib/memory.sh 2>/dev/null || true

# Override the queue key to test-scoped so we don't pollute the real queue
MEM_QUEUE_KEY="$TEST_QUEUE_KEY"

echo "=== memory_queue_embed: empty content rejected ==="
memory_queue_embed "test" "id-1" "cto" "cto" "" '{}'
RC=$?
assert_eq "empty content returns exit 1" "$RC" "1"
LEN=$(redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XLEN "$TEST_QUEUE_KEY" 2>/dev/null)
LEN="${LEN:-0}"
assert_eq "empty content does NOT enqueue (stream len=0)" "$LEN" "0"

echo ""
echo "=== memory_queue_embed: whitespace-only content rejected ==="
memory_queue_embed "test" "id-ws" "cto" "cto" "   " '{}'
RC=$?
assert_eq "whitespace-only returns exit 1" "$RC" "1"
memory_queue_embed "test" "id-ws2" "cto" "cto" $'\n\n\t ' '{}'
RC=$?
assert_eq "mixed whitespace returns exit 1" "$RC" "1"
LEN=$(redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XLEN "$TEST_QUEUE_KEY" 2>/dev/null)
LEN="${LEN:-0}"
assert_eq "whitespace-content does NOT enqueue" "$LEN" "0"

echo ""
echo "=== memory_queue_embed: valid content enqueues ==="
memory_queue_embed "task_summary" "task-1" "cto" "cto" "Task description here" '{"priority":"high"}'
RC=$?
assert_eq "valid content returns exit 0" "$RC" "0"
LEN=$(redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XLEN "$TEST_QUEUE_KEY" 2>/dev/null)
assert_eq "stream len=1 after valid enqueue" "$LEN" "1"

echo ""
echo "=== memory_queue_embed: payload JSON shape ==="
ENTRY=$(redis-cli --raw -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XRANGE "$TEST_QUEUE_KEY" - +)
PAYLOAD=$(echo "$ENTRY" | awk '/^payload$/{getline; print}')
assert_contains "payload has source_type" "$PAYLOAD" '"source_type":"task_summary"'
assert_contains "payload has source_id" "$PAYLOAD" '"source_id":"task-1"'
assert_contains "payload has officer" "$PAYLOAD" '"officer":"cto"'
assert_contains "payload has sender" "$PAYLOAD" '"sender":"cto"'
assert_contains "payload has content" "$PAYLOAD" '"content":"Task description here"'
assert_contains "payload embeds nested metadata.priority" "$PAYLOAD" '"priority":"high"'
assert_contains "payload has source_ts" "$PAYLOAD" '"source_ts":'

# Assert payload is one-line (required for XADD single-value parsing)
LINE_COUNT=$(echo "$PAYLOAD" | wc -l | tr -d ' ')
assert_eq "payload is single-line (line count=1)" "$LINE_COUNT" "1"

echo ""
echo "=== memory_queue_embed: invalid metadata falls back to {} ==="
# Malformed JSON metadata → should be coerced to {}, message still enqueues
memory_queue_embed "test" "id-badmeta" "cto" "cto" "content with bad meta" 'this is not json'
RC=$?
assert_eq "bad-metadata message still returns exit 0" "$RC" "0"
LEN=$(redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XLEN "$TEST_QUEUE_KEY" 2>/dev/null)
assert_eq "stream len=2 after bad-metadata enqueue" "$LEN" "2"

ENTRIES=$(redis-cli --raw -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XRANGE "$TEST_QUEUE_KEY" - +)
BADMETA_ENTRY=$(echo "$ENTRIES" | grep -A1 "id-badmeta" | tail -1)
# The payload for id-badmeta should have metadata: {} (empty object), not the
# invalid string. Find the payload line.
LAST_PAYLOAD=$(echo "$ENTRIES" | awk '/^payload$/{getline; print}' | tail -1)
assert_contains "bad-metadata payload has source_id=id-badmeta" "$LAST_PAYLOAD" '"source_id":"id-badmeta"'
assert_contains "bad-metadata coerced to empty object {}" "$LAST_PAYLOAD" '"metadata":{}'

echo ""
echo "=== memory_queue_embed: default timestamp when omitted ==="
# Clear queue for clean assertion
redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" DEL "$TEST_QUEUE_KEY" > /dev/null 2>&1

memory_queue_embed "test" "id-default-ts" "cto" "cto" "content" '{}'
ENTRY=$(redis-cli --raw -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XRANGE "$TEST_QUEUE_KEY" - +)
PAYLOAD=$(echo "$ENTRY" | awk '/^payload$/{getline; print}')
# Default timestamp has ISO-8601 UTC shape: YYYY-MM-DDTHH:MM:SSZ
if echo "$PAYLOAD" | grep -qE '"source_ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"'; then
  PASS=$((PASS+1))
  printf "  [PASS] default source_ts is ISO-8601 UTC shape\n"
else
  FAIL=$((FAIL+1))
  FAILURES+=("default source_ts not ISO-8601")
  printf "  [FAIL] default source_ts not ISO-8601 shape: %s\n" "$PAYLOAD"
fi

echo ""
echo "=== memory_queue_embed: explicit timestamp preserved ==="
redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" DEL "$TEST_QUEUE_KEY" > /dev/null 2>&1
memory_queue_embed "test" "id-explicit-ts" "cto" "cto" "content" '{}' "2026-04-23T12:00:00Z"
ENTRY=$(redis-cli --raw -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XRANGE "$TEST_QUEUE_KEY" - +)
PAYLOAD=$(echo "$ENTRY" | awk '/^payload$/{getline; print}')
assert_contains "explicit source_ts preserved" "$PAYLOAD" '"source_ts":"2026-04-23T12:00:00Z"'

echo ""
echo "=== memory_queue_embed: unicode content preserved ==="
redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" DEL "$TEST_QUEUE_KEY" > /dev/null 2>&1
UNICODE_TEXT="café résumé 日本語 👋"
memory_queue_embed "test" "id-unicode" "cto" "cto" "$UNICODE_TEXT" '{}'
ENTRY=$(redis-cli --raw -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XRANGE "$TEST_QUEUE_KEY" - +)
PAYLOAD=$(echo "$ENTRY" | awk '/^payload$/{getline; print}')
# jq escapes unicode as \uXXXX or preserves it, both acceptable; the bytes
# should round-trip via JSON parse
DECODED=$(echo "$PAYLOAD" | jq -r '.content')
assert_eq "unicode content round-trips through queue" "$DECODED" "$UNICODE_TEXT"

echo ""
echo "=== memory_queue_embed: content with embedded quotes escaped ==="
redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" DEL "$TEST_QUEUE_KEY" > /dev/null 2>&1
QUOTED_TEXT='He said "hello", then left.'
memory_queue_embed "test" "id-quotes" "cto" "cto" "$QUOTED_TEXT" '{}'
ENTRY=$(redis-cli --raw -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XRANGE "$TEST_QUEUE_KEY" - +)
PAYLOAD=$(echo "$ENTRY" | awk '/^payload$/{getline; print}')
DECODED=$(echo "$PAYLOAD" | jq -r '.content')
assert_eq "embedded-quote content round-trips" "$DECODED" "$QUOTED_TEXT"

echo ""
echo "=== memory_queue_embed: content with newlines preserved ==="
redis-cli -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" DEL "$TEST_QUEUE_KEY" > /dev/null 2>&1
MULTILINE=$'Line 1\nLine 2\nLine 3'
memory_queue_embed "test" "id-multiline" "cto" "cto" "$MULTILINE" '{}'
ENTRY=$(redis-cli --raw -h "$MEM_REDIS_HOST" -p "$MEM_REDIS_PORT" XRANGE "$TEST_QUEUE_KEY" - +)
PAYLOAD=$(echo "$ENTRY" | awk '/^payload$/{getline; print}')
DECODED=$(echo "$PAYLOAD" | jq -r '.content')
assert_eq "multiline content round-trips" "$DECODED" "$MULTILINE"

# Also verify the XADD payload itself is one-line (not broken by the \n inside)
# Count redis-stream payload lines by fetching the raw entry and locating the value
RAW_BYTE_SIZE=$(echo "$PAYLOAD" | wc -l | tr -d ' ')
assert_eq "multiline payload still serialized as 1 JSON line" "$RAW_BYTE_SIZE" "1"

echo ""
echo "=== memory_embed: empty content skips DB insert (NEON not hit) ==="
# Calling memory_embed with empty content should short-circuit before any
# network call. We can verify by checking exit code only.
memory_embed "test" "id-x" "cto" "cto" "" '{}' 2>/dev/null
RC=$?
assert_eq "memory_embed empty content returns exit 1" "$RC" "1"

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
