#!/bin/bash
# test-post-tool-use-jsonl.sh — FW-075 H3 JSONL project-field harness
#
# Invokes post-tool-use.sh with synthetic stdin under various
# CABINET_ACTIVE_PROJECT values and asserts the JSONL emit includes the
# correct `project` field. Uses CABINET_LOG_DIR + CABINET_HOOK_TEST_MODE
# to keep production logs untouched and suppress trigger fan-out.
#
# Run: bash /opt/founders-cabinet/cabinet/scripts/test-post-tool-use-jsonl.sh

set -uo pipefail

HOOK="/opt/founders-cabinet/cabinet/scripts/hooks/post-tool-use.sh"
TMP_DIR=$(mktemp -d -t fw075-jsonl-XXXX)
TODAY=$(date -u +%Y-%m-%d)

PASS=0
FAIL=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

assert_field() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS+1)); echo "  [PASS] $label"
  else
    FAIL=$((FAIL+1)); echo "  [FAIL] $label: expected='$expected' actual='$actual'"
  fi
}

# Synthetic Claude Code hook stdin — minimal valid shape
SAMPLE_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hi"},"tool_response":{"stdout":"hi"}}'

run_hook() {
  local proj="$1"
  rm -f "$TMP_DIR/${TODAY}.jsonl"
  echo "$SAMPLE_INPUT" | env \
    CABINET_LOG_DIR="$TMP_DIR" \
    CABINET_HOOK_TEST_MODE=1 \
    OFFICER_NAME=test-officer \
    CABINET_ACTIVE_PROJECT="$proj" \
    bash "$HOOK" > /dev/null 2>&1
  # Return the last JSONL line
  tail -1 "$TMP_DIR/${TODAY}.jsonl" 2>/dev/null
}

echo "=== FW-075: post-tool-use.sh JSONL project field ==="

# T1: pool mode — valid slug surfaces in JSONL
LINE=$(run_hook "sensed")
PROJ=$(echo "$LINE" | jq -r '.project // "<MISSING>"' 2>/dev/null)
assert_field "T1 pool slug 'sensed' lands in JSONL" "$PROJ" "sensed"

# T2: legacy mode — empty CABINET_ACTIVE_PROJECT → empty project field
LINE=$(run_hook "")
PROJ=$(echo "$LINE" | jq -r '.project // "<MISSING>"' 2>/dev/null)
assert_field "T2 legacy mode emits empty project field" "$PROJ" ""

# T3: malformed slug — bad charset → empty (defensive fallback)
LINE=$(run_hook "BAD!CHARS")
PROJ=$(echo "$LINE" | jq -r '.project // "<MISSING>"' 2>/dev/null)
assert_field "T3 malformed slug 'BAD!CHARS' falls back to empty" "$PROJ" ""

# T4: malformed slug — leading hyphen → empty
LINE=$(run_hook "-leading")
PROJ=$(echo "$LINE" | jq -r '.project // "<MISSING>"' 2>/dev/null)
assert_field "T4 leading-hyphen slug falls back to empty" "$PROJ" ""

# T5: malformed slug — 33+ chars → empty (length cap)
LONG=$(printf 'a%.0s' {1..33})
LINE=$(run_hook "$LONG")
PROJ=$(echo "$LINE" | jq -r '.project // "<MISSING>"' 2>/dev/null)
assert_field "T5 33-char slug falls back to empty (length cap)" "$PROJ" ""

# T6: valid slug at boundary (32 chars) — accepted
BOUNDARY=$(printf 'a%.0s' {1..32})
LINE=$(run_hook "$BOUNDARY")
PROJ=$(echo "$LINE" | jq -r '.project // "<MISSING>"' 2>/dev/null)
assert_field "T6 32-char boundary slug accepted" "$PROJ" "$BOUNDARY"

# T7: existing fields still emitted (officer, tool, ts, cabinet_id)
LINE=$(run_hook "sensed")
OFFICER=$(echo "$LINE" | jq -r '.officer' 2>/dev/null)
TOOL=$(echo "$LINE" | jq -r '.tool' 2>/dev/null)
assert_field "T7a JSONL retains officer field" "$OFFICER" "test-officer"
assert_field "T7b JSONL retains tool field" "$TOOL" "Bash"

# T8: emit is valid JSON (would fail jq parse otherwise)
LINE=$(run_hook "step-network")
JSON_VALID=$(echo "$LINE" | jq -e . 2>/dev/null > /dev/null && echo "valid" || echo "invalid")
assert_field "T8 emit is valid JSON" "$JSON_VALID" "valid"

echo
echo "=========================================="
echo "FW-075 JSONL project field: PASS=$PASS FAIL=$FAIL"
echo "=========================================="
[ "$FAIL" -eq 0 ]
