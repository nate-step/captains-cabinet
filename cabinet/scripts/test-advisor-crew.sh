#!/bin/bash
# test-advisor-crew.sh — Smoke tests for the advisor-crew wrapper
#
# Tests:
#   1. Missing API key → clean error (no crash, exit 1)
#   2. Context ceiling check → clean error when context is too large
#   3. --dry-run flag → request body emitted, cache_control present when expected-calls >=3
#   4. --dry-run flag → cache_control absent when expected-calls <3
#   5. --dry-run flag → cache_control absent when expected-calls not set
#   6. Real API call (only if ANTHROPIC_API_KEY is set) → result + Redis keys populated
#
# Usage: bash cabinet/scripts/test-advisor-crew.sh [--live]
#   --live: force live API test even if it might skip

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADVISOR="$SCRIPT_DIR/advisor-crew.sh"

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP + 1)); }

echo "=== advisor-crew smoke tests ==="
echo ""

# ────────────────────────────────────────────────────────────
# Test 1: Missing API key → clean error
# ────────────────────────────────────────────────────────────
echo "Test 1: Missing ANTHROPIC_API_KEY → clean error, exit 1"

# Write a temp .env with no API key, then invoke advisor-crew.sh pointed at that temp env.
# We patch the env-load path by temporarily swapping the .env file — the script sources
# cabinet/.env only when ANTHROPIC_API_KEY is unset, so we also unset it in this subshell.
CABINET_ENV="$SCRIPT_DIR/../.env"
TEMP_ENV=$(mktemp)
# Write an .env with ANTHROPIC_API_KEY explicitly unset so the source'd file clears it
echo 'unset ANTHROPIC_API_KEY' > "$TEMP_ENV"
echo 'ANTHROPIC_API_KEY=""' >> "$TEMP_ENV"

# Back up real .env and swap in the key-less one
BACKUP_ENV=""
if [ -f "$CABINET_ENV" ]; then
  BACKUP_ENV=$(mktemp)
  cp "$CABINET_ENV" "$BACKUP_ENV"
  cp "$TEMP_ENV" "$CABINET_ENV"
fi

T1_OUTPUT=$(
  unset ANTHROPIC_API_KEY
  bash "$ADVISOR" --task "test task" 2>&1
) || T1_EXIT=$?

T1_EXIT="${T1_EXIT:-0}"

# Restore real .env
if [ -n "$BACKUP_ENV" ]; then
  cp "$BACKUP_ENV" "$CABINET_ENV"
  rm -f "$BACKUP_ENV"
fi
rm -f "$TEMP_ENV"

if [ "$T1_EXIT" -eq 1 ] && echo "$T1_OUTPUT" | grep -q "ANTHROPIC_API_KEY"; then
  pass "exit 1 + clear error message about ANTHROPIC_API_KEY"
else
  fail "Expected exit 1 with ANTHROPIC_API_KEY error. Got exit $T1_EXIT. Output: ${T1_OUTPUT:0:200}"
fi

echo ""

# ────────────────────────────────────────────────────────────
# Test 2: Context ceiling check
# ────────────────────────────────────────────────────────────
echo "Test 2: Oversized context → clean error, exit 1"

LARGE_CONTEXT=$(python3 -c "print('x' * 900000)" 2>/dev/null || node -e "process.stdout.write('x'.repeat(900000))")
LARGE_FILE=$(mktemp)
echo "$LARGE_CONTEXT" > "$LARGE_FILE"

T2_OUTPUT=$(
  ANTHROPIC_API_KEY="test-key-not-real" \
  bash "$ADVISOR" --task "test" --context "$LARGE_FILE" 2>&1
) || T2_EXIT=$?

T2_EXIT="${T2_EXIT:-0}"

rm -f "$LARGE_FILE"

if [ "$T2_EXIT" -eq 1 ] && echo "$T2_OUTPUT" | grep -qi "context too large\|200k"; then
  pass "exit 1 + clear error message about context ceiling"
else
  fail "Expected exit 1 with context-too-large error. Got exit $T2_EXIT. Output: ${T2_OUTPUT:0:200}"
fi

echo ""

# ────────────────────────────────────────────────────────────
# Test 3: --dry-run with --expected-calls 3 → cache_control present
# ────────────────────────────────────────────────────────────
echo "Test 3: --dry-run + --expected-calls 3 → cache_control in request body"

T3_OUTPUT=$(
  ANTHROPIC_API_KEY="test-key-not-real" \
  bash "$ADVISOR" \
    --task "summarize this in 3 bullets" \
    --expected-calls 3 \
    --dry-run true 2>&1
) || T3_EXIT=$?

T3_EXIT="${T3_EXIT:-0}"

if [ "$T3_EXIT" -eq 0 ] && echo "$T3_OUTPUT" | grep -q "cache_control"; then
  pass "dry-run exit 0 + cache_control present in request body"
else
  fail "Expected exit 0 + cache_control in body. Got exit $T3_EXIT. Output: ${T3_OUTPUT:0:300}"
fi

echo ""

# ────────────────────────────────────────────────────────────
# Test 4: --dry-run with --expected-calls 2 → cache_control absent
# ────────────────────────────────────────────────────────────
echo "Test 4: --dry-run + --expected-calls 2 → cache_control NOT in request body"

T4_OUTPUT=$(
  ANTHROPIC_API_KEY="test-key-not-real" \
  bash "$ADVISOR" \
    --task "summarize this in 3 bullets" \
    --expected-calls 2 \
    --dry-run true 2>&1
) || T4_EXIT=$?

T4_EXIT="${T4_EXIT:-0}"

if [ "$T4_EXIT" -eq 0 ] && ! echo "$T4_OUTPUT" | grep -q "cache_control"; then
  pass "dry-run exit 0 + cache_control absent (expected-calls=2)"
else
  fail "Expected exit 0 + NO cache_control. Got exit $T4_EXIT. Output: ${T4_OUTPUT:0:300}"
fi

echo ""

# ────────────────────────────────────────────────────────────
# Test 5: --dry-run with no expected-calls → cache_control absent
# ────────────────────────────────────────────────────────────
echo "Test 5: --dry-run + no --expected-calls → cache_control NOT in request body"

T5_OUTPUT=$(
  ANTHROPIC_API_KEY="test-key-not-real" \
  bash "$ADVISOR" \
    --task "summarize this in 3 bullets" \
    --dry-run true 2>&1
) || T5_EXIT=$?

T5_EXIT="${T5_EXIT:-0}"

if [ "$T5_EXIT" -eq 0 ] && ! echo "$T5_OUTPUT" | grep -q "cache_control"; then
  pass "dry-run exit 0 + cache_control absent (no expected-calls flag)"
else
  fail "Expected exit 0 + NO cache_control. Got exit $T5_EXIT. Output: ${T5_OUTPUT:0:300}"
fi

echo ""

# ────────────────────────────────────────────────────────────
# Test 6: Live API call (only if ANTHROPIC_API_KEY is set)
# ────────────────────────────────────────────────────────────
echo "Test 6: Live API call + Redis cost keys populated"

# Load .env to get API key
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/../.env"
  set +a
fi

if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  skip "ANTHROPIC_API_KEY not set — skipping live API test"
else
  REDIS_HOST="${REDIS_HOST:-redis}"
  REDIS_PORT="${REDIS_PORT:-6379}"
  TEST_OFFICER="test-advisor-smoke"
  TODAY=$(date -u +%Y-%m-%d)

  # Clear any previous test keys
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "cabinet:cost:advisor:$TEST_OFFICER" > /dev/null 2>&1 || true
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HDEL "cabinet:cost:advisor:daily:$TODAY" \
    "${TEST_OFFICER}_input" "${TEST_OFFICER}_output" "${TEST_OFFICER}_cost_micro" > /dev/null 2>&1 || true

  T6_OUTPUT=$(
    bash "$ADVISOR" \
      --task "Reply with exactly the word: ACKNOWLEDGED" \
      --officer "$TEST_OFFICER" \
      --max-tokens 50 \
      2>/tmp/advisor-crew-test6-stderr.txt
  ) || T6_EXIT=$?

  T6_EXIT="${T6_EXIT:-0}"

  if [ "$T6_EXIT" -ne 0 ]; then
    fail "Live call failed with exit $T6_EXIT. stderr: $(cat /tmp/advisor-crew-test6-stderr.txt)"
  else
    # Check result has text
    if [ -n "$T6_OUTPUT" ]; then
      pass "Live call returned non-empty result: ${T6_OUTPUT:0:80}"
    else
      fail "Live call returned empty result"
    fi

    # Check Redis keys were populated
    REDIS_LAST_UPDATED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "cabinet:cost:advisor:$TEST_OFFICER" last_updated 2>/dev/null)
    if [ -n "$REDIS_LAST_UPDATED" ]; then
      pass "Redis per-officer key cabinet:cost:advisor:$TEST_OFFICER populated (last_updated: $REDIS_LAST_UPDATED)"
    else
      fail "Redis per-officer key not populated after live call"
    fi

    REDIS_DAILY_COST=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "cabinet:cost:advisor:daily:$TODAY" "${TEST_OFFICER}_cost_micro" 2>/dev/null)
    if [ -n "$REDIS_DAILY_COST" ]; then
      pass "Redis daily key cabinet:cost:advisor:daily:$TODAY populated (cost_micro: $REDIS_DAILY_COST)"
    else
      # Daily key might be 0 if advisor wasn't invoked (executor-only call) — check _output instead
      REDIS_DAILY_OUT=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "cabinet:cost:advisor:daily:$TODAY" "${TEST_OFFICER}_output" 2>/dev/null)
      if [ -n "$REDIS_DAILY_OUT" ]; then
        pass "Redis daily key populated (output_tokens: $REDIS_DAILY_OUT)"
      else
        fail "Redis daily key not populated after live call"
      fi
    fi
  fi
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
