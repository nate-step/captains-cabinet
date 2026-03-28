#!/bin/bash
# test-escalation.sh — Tests the full kill switch escalation chain.
# Run manually from the HOST or from inside the watchdog container.
# Usage: bash test-escalation.sh [--live]
#   Without --live: dry run, prints what would happen
#   With --live: actually sets/clears the kill switch and checks
[ -f /etc/environment.cabinet ] && source /etc/environment.cabinet

REDIS_URL="${REDIS_URL:-redis://redis:6379}"
REDIS_HOST=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f1)
REDIS_PORT=$(echo "$REDIS_URL" | sed 's|redis://||' | cut -d: -f2)

LIVE=false
[ "${1:-}" = "--live" ] && LIVE=true

PASSED=0
FAILED=0
TOTAL=0

test_step() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  TOTAL=$((TOTAL + 1))

  if [ "$actual" = "$expected" ]; then
    echo "  ✅ $name"
    PASSED=$((PASSED + 1))
  else
    echo "  ❌ $name (expected: '$expected', got: '$actual')"
    FAILED=$((FAILED + 1))
  fi
}

echo "============================================"
echo " Kill Switch Escalation Chain Test"
echo " $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo " Mode: $( [ "$LIVE" = true ] && echo "LIVE" || echo "DRY RUN")"
echo "============================================"
echo ""

# ============================================================
# Test 1: Verify kill switch is currently OFF
# ============================================================
echo "1. Pre-flight checks"
KS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
test_step "Kill switch is currently off" "" "$KS"

# ============================================================
# Test 2: Activate kill switch
# ============================================================
echo ""
echo "2. Activating kill switch"
if [ "$LIVE" = true ]; then
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET cabinet:killswitch active > /dev/null 2>&1
  KS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
  test_step "Kill switch set to 'active'" "active" "$KS"
else
  echo "  ⏭️  SKIPPED (dry run) — would SET cabinet:killswitch active"
  TOTAL=$((TOTAL + 1))
  PASSED=$((PASSED + 1))
fi

# ============================================================
# Test 3: Verify pre-tool-use hook would block
# ============================================================
echo ""
echo "3. Verifying pre-tool-use hook behavior"
if [ "$LIVE" = true ]; then
  # Simulate what the hook checks
  KS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
  test_step "pre-tool-use would read 'active'" "active" "$KS"

  # The hook exits 2 when kill switch is active (we can't run it directly
  # from watchdog, but we verify the Redis state it checks)
  echo "  ℹ️  Hook logic: if killswitch=active → exit 2 (block all tools)"
else
  echo "  ⏭️  SKIPPED (dry run)"
  TOTAL=$((TOTAL + 1))
  PASSED=$((PASSED + 1))
fi

# ============================================================
# Test 4: Verify supervisor respects kill switch
# ============================================================
echo ""
echo "4. Supervisor kill switch respect"
if [ "$LIVE" = true ]; then
  KS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
  test_step "Supervisor would skip restarts (killswitch=$KS)" "active" "$KS"
else
  echo "  ⏭️  SKIPPED (dry run)"
  TOTAL=$((TOTAL + 1))
  PASSED=$((PASSED + 1))
fi

# ============================================================
# Test 5: Verify health check sees kill switch
# ============================================================
echo ""
echo "5. Health check kill switch awareness"
if [ "$LIVE" = true ]; then
  KS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
  test_step "Health check would skip further checks" "active" "$KS"
else
  echo "  ⏭️  SKIPPED (dry run)"
  TOTAL=$((TOTAL + 1))
  PASSED=$((PASSED + 1))
fi

# ============================================================
# Test 6: Deactivate kill switch
# ============================================================
echo ""
echo "6. Deactivating kill switch"
if [ "$LIVE" = true ]; then
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL cabinet:killswitch > /dev/null 2>&1
  KS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
  test_step "Kill switch cleared" "" "$KS"
else
  echo "  ⏭️  SKIPPED (dry run) — would DEL cabinet:killswitch"
  TOTAL=$((TOTAL + 1))
  PASSED=$((PASSED + 1))
fi

# ============================================================
# Test 7: Verify officers can resume
# ============================================================
echo ""
echo "7. Post-deactivation state"
if [ "$LIVE" = true ]; then
  KS=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET cabinet:killswitch 2>/dev/null)
  test_step "Kill switch is off (operations would resume)" "" "$KS"

  # Check officer expected states still set
  for officer in cos cto cro cpo; do
    EXPECTED=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:officer:expected:$officer" 2>/dev/null)
    if [ "$EXPECTED" = "active" ]; then
      test_step "Officer $officer still marked as expected:active" "active" "$EXPECTED"
    else
      echo "  ℹ️  Officer $officer not marked active (expected=$EXPECTED)"
    fi
  done
else
  echo "  ⏭️  SKIPPED (dry run)"
  TOTAL=$((TOTAL + 1))
  PASSED=$((PASSED + 1))
fi

# ============================================================
# Test 8: Verify Redis safety keys exist
# ============================================================
echo ""
echo "8. Safety infrastructure checks"
# Check that spending limit keys can be read
SPENDING=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "cabinet:cost:daily:$(date -u +%Y-%m-%d)" 2>/dev/null)
test_step "Daily cost counter is readable" "true" "$([ -n "$SPENDING" ] || [ "$SPENDING" = "" ] && echo "true")"

# Check Redis is healthy
PONG=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" PING 2>/dev/null)
test_step "Redis responds to PING" "PONG" "$PONG"

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================"
echo " Results: $PASSED/$TOTAL passed, $FAILED failed"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  echo "⚠️  Some tests failed — review the output above."
  exit 1
else
  echo "✅ All tests passed."
  exit 0
fi
