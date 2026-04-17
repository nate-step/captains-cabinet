#!/bin/bash
# FW-002 behavior eval — spending-limits gate in pre-tool-use.sh
#
# Contracts from shared/cabinet-framework-backlog.md FW-002:
#   (a) Every non-zero exit prints stderr reason (never silent-block)
#   (b) Telegram reply/react/group bypass cap with hourly sub-cap
#   (c) CoS gets 3x per-officer cap (coordinating_officer_multiplier)
#   (d) Platform.yml override; framework defaults fall through
#
# Invocation: bash /opt/founders-cabinet/memory/golden-evals/framework/fw-002-spending-limits.sh
# Exit 0 = all tests pass; non-zero = test failure (first failure reported).

# set -u intentionally off — the hook we're testing sources itself in various
# environments where not every env var is guaranteed to be set; testing under
# -u gives false failures on edge cases the hook already handles.

HOOK="/opt/founders-cabinet/cabinet/scripts/hooks/pre-tool-use.sh"
CACHE="/tmp/cabinet-spending-limits.tsv"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
TODAY=$(date -u +%Y-%m-%d)
KEY="cabinet:cost:tokens:daily:$TODAY"

PASS=0
FAIL=0
FAIL_DETAILS=""

run() {
  # usage: run <label> <officer> <tool_json> <officer_cost_micro_opt> <expect_exit> <stderr_contains_or_empty>
  local label="$1" officer="$2" tool_json="$3" cost_micro="$4" expect_exit="$5" stderr_contains="$6"

  # Set the officer's cost in redis (scoped to this test)
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HSET "$KEY" "${officer}_cost_micro" "$cost_micro" >/dev/null 2>&1

  # Invalidate the cache so the hook re-reads yaml (in case tests mutate platform.yml)
  rm -f "$CACHE"

  # Capture stderr + exit
  local err_file
  err_file=$(mktemp)
  echo "$tool_json" | OFFICER="$officer" OFFICER_NAME="$officer" bash "$HOOK" 2>"$err_file" >/dev/null
  local got_exit=$?
  local got_stderr
  got_stderr=$(cat "$err_file")
  rm -f "$err_file"

  local ok=1
  if [ "$got_exit" != "$expect_exit" ]; then
    ok=0
    FAIL_DETAILS="$FAIL_DETAILS\n  [$label] expected exit=$expect_exit, got=$got_exit; stderr='$got_stderr'"
  fi
  if [ -n "$stderr_contains" ]; then
    if ! echo "$got_stderr" | grep -q "$stderr_contains"; then
      ok=0
      FAIL_DETAILS="$FAIL_DETAILS\n  [$label] stderr did not contain '$stderr_contains'; got='$got_stderr'"
    fi
  fi
  if [ "$ok" = "1" ]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
  fi
}

cleanup() {
  # Clear test cost keys so we don't leave poison for the live cabinet
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HDEL "$KEY" \
    testofficer_cost_micro cos_cost_micro_test >/dev/null 2>&1
  # Clear any tg-whitelist hour buckets created by tests
  for k in $(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" KEYS 'cabinet:tg-whitelist:testofficer:*' 2>/dev/null); do
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "$k" >/dev/null 2>&1
  done
}
trap cleanup EXIT

# Clear prior state for testofficer
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HDEL "$KEY" testofficer_cost_micro >/dev/null 2>&1

echo "=== FW-002 Spending Limits Gate — Golden Eval ==="
echo ""

# --- Test group 1: cap=0 (instance/config/platform.yml current state) ------
# This Cabinet's platform.yml has daily_per_officer_usd=0 and
# daily_cabinet_wide_usd=0. Every call should pass regardless of cost.
echo "-- Contract d: cap=0 means unlimited --"
run "cap=0 officer under cap → allow" \
  "testofficer" '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' 0 0 ""
run "cap=0 officer at $1000 → still allow (unlimited)" \
  "testofficer" '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' 1000000000 0 ""

# --- Test group 2: simulate a fork's framework defaults by pointing the
# hook at an alternate yaml via an override cache. Writing test data
# directly to the cache file lets us assert the enforcement branches
# without editing platform.yml globally. ------
echo ""
echo "-- Contract a: stderr on block when cap is enforced --"

# Simulate: per-officer cap $75, cabinet cap disabled
cat > "$CACHE" <<'EOF'
daily_per_officer_usd	75
daily_cabinet_wide_usd	0
coordinating_officer_multiplier	3.0
telegram_whitelist_enabled	true
telegram_whitelist_hourly_cap	10
EOF
# Make cache newer than both yamls so the rebuild logic doesn't overwrite it
touch "$CACHE"

# Freeze the yaml mtimes below the cache so rebuild is skipped
# (we pass --reference but only if the cache exists — which it does now)
[ -f /opt/founders-cabinet/instance/config/platform.yml ] && touch -d @$(($(date +%s) - 60)) /opt/founders-cabinet/instance/config/platform.yml
[ -f /opt/founders-cabinet/framework/defaults/spending-limits.yml ] && touch -d @$(($(date +%s) - 60)) /opt/founders-cabinet/framework/defaults/spending-limits.yml
touch "$CACHE"

# Wrap run to preserve cache across tests in this group
run_keep_cache() {
  local label="$1" officer="$2" tool_json="$3" cost_micro="$4" expect_exit="$5" stderr_contains="$6"
  redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HSET "$KEY" "${officer}_cost_micro" "$cost_micro" >/dev/null 2>&1
  local err_file
  err_file=$(mktemp)
  echo "$tool_json" | OFFICER="$officer" OFFICER_NAME="$officer" bash "$HOOK" 2>"$err_file" >/dev/null
  local got_exit=$?
  local got_stderr
  got_stderr=$(cat "$err_file")
  rm -f "$err_file"
  local ok=1
  [ "$got_exit" != "$expect_exit" ] && { ok=0; FAIL_DETAILS="$FAIL_DETAILS\n  [$label] expected exit=$expect_exit, got=$got_exit; stderr='$got_stderr'"; }
  if [ -n "$stderr_contains" ] && ! echo "$got_stderr" | grep -q "$stderr_contains"; then
    ok=0; FAIL_DETAILS="$FAIL_DETAILS\n  [$label] stderr missing '$stderr_contains'; got='$got_stderr'"
  fi
  if [ "$ok" = "1" ]; then PASS=$((PASS+1)); echo "  PASS: $label"; else FAIL=$((FAIL+1)); echo "  FAIL: $label"; fi
}

# 76 USD > 75 USD cap → BLOCK for non-cos officer
run_keep_cache "officer over $75 cap → block with stderr" \
  "testofficer" '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' 76000000 2 "BLOCKED"
run_keep_cache "block stderr names the override path" \
  "testofficer" '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' 76000000 2 "platform.yml"
run_keep_cache "officer under $75 cap → allow" \
  "testofficer" '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' 50000000 0 ""

echo ""
echo "-- Contract c: CoS 3x multiplier --"
# cos at $76 with per_off_cap=$75 would normally block, but 3x → effective $225
run_keep_cache "cos at $76 with 3x → allow (effective cap $225)" \
  "cos" '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' 76000000 0 ""
# cos at $226 → BLOCK
run_keep_cache "cos at $226 with 3x → block" \
  "cos" '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' 226000000 2 "BLOCKED"
run_keep_cache "cos block mentions coordinator multiplier" \
  "cos" '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' 226000000 2 "coordinator multiplier"
# Reset cos cost after cos tests so we don't leave it at $226
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HDEL "$KEY" cos_cost_micro >/dev/null 2>&1

echo ""
echo "-- Contract b: Telegram whitelist bypasses cap --"
run_keep_cache "over-cap officer can still Telegram reply" \
  "testofficer" '{"tool_name":"mcp__plugin_telegram_telegram__reply","tool_input":{"chat_id":"1","text":"help"}}' 76000000 0 ""
run_keep_cache "over-cap officer can still Telegram react" \
  "testofficer" '{"tool_name":"mcp__plugin_telegram_telegram__react","tool_input":{"chat_id":"1","message_id":"1","emoji":"👍"}}' 76000000 0 ""
run_keep_cache "over-cap officer can still send-to-group.sh" \
  "testofficer" '{"tool_name":"Bash","tool_input":{"command":"bash /opt/founders-cabinet/cabinet/scripts/send-to-group.sh hi"}}' 76000000 0 ""

echo ""
echo "-- Contract a (reiterated): cabinet-wide cap with stderr --"
# Force cabinet-wide block: per-officer cap disabled, cabinet cap $1000,
# two officers at $600 each = $1200 > $1000
cat > "$CACHE" <<'EOF'
daily_per_officer_usd	0
daily_cabinet_wide_usd	1000
coordinating_officer_multiplier	3.0
telegram_whitelist_enabled	true
telegram_whitelist_hourly_cap	10
EOF
touch "$CACHE"
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HSET "$KEY" testofficer_cost_micro 600000000 >/dev/null 2>&1
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HSET "$KEY" otherofficer_cost_micro 600000000 >/dev/null 2>&1
run_keep_cache "cabinet-wide $1200 > $1000 → block" \
  "testofficer" '{"tool_name":"Bash","tool_input":{"command":"echo hi"}}' 600000000 2 "cabinet-wide"
redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HDEL "$KEY" otherofficer_cost_micro testofficer_cost_micro >/dev/null 2>&1

echo ""
echo "=== Result: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  printf "%b\n" "$FAIL_DETAILS"
  exit 1
fi
exit 0
