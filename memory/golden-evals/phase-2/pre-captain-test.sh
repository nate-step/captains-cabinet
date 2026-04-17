#!/bin/bash
# Phase 2 pre-Captain test suite — behavior-level regression gate.
#
# 100% behavior tests (no file-existence-only checks per Phase 1 polish
# discipline). Exercises: personal preset loading, Cabinet MCP tool set,
# trust policy enforcement in pre-tool-use.sh, split-cabinet.sh dry-run,
# and Phase 2 schema columns on target tables.

cd /opt/founders-cabinet
set -a
source cabinet/.env 2>/dev/null
set +a

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== Phase 2 Pre-Captain Test Suite ==="
echo "Locked Captain decisions (2026-04-17):"
echo "  - scope: framework-ready (not live second Cabinet)"
echo "  - peers.yml is single source for multi-Cabinet config"
echo "  - Cabinet MCP stdio; HTTP-compatible signatures"
echo "  - personal-capacity Cabinets refuse federation tools"
echo ""

NEON_URL="${NEON_CONNECTION_STRING:-}"
CAB_URL="${DATABASE_URL:-}"
CAB_PSQL() { [ -n "$CAB_URL" ] && psql "$CAB_URL" -tAc "$1" 2>/dev/null; }
PROD_PSQL() { [ -n "$NEON_URL" ] && psql "$NEON_URL" -tAc "$1" 2>/dev/null; }

echo "--- BEHAVIOR: personal preset loads cleanly ---"
out=$(bash cabinet/scripts/load-preset.sh personal 2>&1)
echo "$out" | grep -q "Preset 'personal' loaded successfully" && pass "personal preset loads" || fail "personal preset load failed: $out"
echo "$out" | grep -q "Assembled constitution" && pass "personal constitution assembled" || fail "constitution not assembled"
echo "$out" | grep -q "Applied preset schema: personal/schemas.sql" && pass "personal schemas applied" || fail "personal schemas not applied"
echo "$out" | grep -q "staged" && pass "scaffold-skip honored (agents staged, not hired)" || fail "scaffold-skip broken"

# Restore work preset
bash cabinet/scripts/load-preset.sh > /dev/null 2>&1

echo ""
echo "--- BEHAVIOR: personal preset schemas present in Neon ---"
for tbl in longitudinal_metrics coaching_narratives coaching_consent_log coaching_experiments; do
  PROD_PSQL "SELECT 1 FROM information_schema.tables WHERE table_name='$tbl'" | grep -q 1 \
    && pass "table $tbl exists" || fail "table $tbl missing"
done

echo ""
echo "--- BEHAVIOR: cabinet_id + context_slug on every Cabinet-infrastructure table ---"
for tbl in experience_records; do
  for col in cabinet_id context_slug; do
    CAB_PSQL "SELECT 1 FROM information_schema.columns WHERE table_name='$tbl' AND column_name='$col'" | grep -q 1 \
      && pass "cabinet.$tbl.$col exists" || fail "cabinet.$tbl.$col missing"
  done
done
for tbl in cabinet_memory library_records session_memories coaching_narratives coaching_experiments longitudinal_metrics coaching_consent_log; do
  for col in cabinet_id context_slug; do
    PROD_PSQL "SELECT 1 FROM information_schema.columns WHERE table_name='$tbl' AND column_name='$col'" | grep -q 1 \
      && pass "neon.$tbl.$col exists" || fail "neon.$tbl.$col missing"
  done
done

echo ""
echo "--- BEHAVIOR: Cabinet MCP server exposes 5 tools ---"
MCP="/opt/founders-cabinet/cabinet/mcp-server/server.py"
tools_list=$(echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | python3 "$MCP" 2>/dev/null)
for t in identify presence availability send_message request_handoff; do
  echo "$tools_list" | grep -q "\"$t\"" && pass "tools/list includes $t" || fail "tools/list missing $t"
done

# identify returns required fields including Phase 2 capacity
idr=$(echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"identify","arguments":{}}}' | python3 "$MCP" 2>/dev/null)
echo "$idr" | python3 -c "
import sys,json
d = json.loads(sys.stdin.read())
p = json.loads(d['result']['content'][0]['text'])
assert p['cabinet_id'], 'cabinet_id missing'
assert p['captain_id'], 'captain_id missing'
assert p['capacity'] in ('work','personal'), f'capacity={p.get(\"capacity\")}'
assert isinstance(p['available_agents'], list)
assert p['server']['version'].startswith('0.2'), f'version={p[\"server\"][\"version\"]}'
" 2>/dev/null && pass "identify() returns cabinet_id+captain_id+capacity+agents+server v0.2+" || fail "identify() shape wrong: $idr"

# availability returns unavailable_no_source when no calendar.yml
av=$(echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"availability","arguments":{"start":"2026-04-17T00:00Z","end":"2026-04-18T00:00Z"}}}' | python3 "$MCP" 2>/dev/null)
echo "$av" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); p=json.loads(d['result']['content'][0]['text']); assert p['status'] in ('unavailable_no_source','ok')" 2>/dev/null \
  && pass "availability() handles missing calendar source" || fail "availability() shape wrong: $av"

# presence on unknown peer returns known_peers + this_cabinet_id
pr=$(echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"presence","arguments":{"peer_id":"nonexistent"}}}' | python3 "$MCP" 2>/dev/null)
echo "$pr" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); p=json.loads(d['result']['content'][0]['text']); assert p['status']=='unknown_peer'; assert 'this_cabinet_id' in p" 2>/dev/null \
  && pass "presence() unknown peer → unknown_peer + this_cabinet_id" || fail "presence shape wrong: $pr"

echo ""
echo "--- BEHAVIOR: pre-tool-use.sh peers.yml trust policy ---"
HOOK="/opt/founders-cabinet/cabinet/scripts/hooks/pre-tool-use.sh"
rm -f /tmp/cabinet-peers.tsv /tmp/cabinet-mcp-scope.tsv

run_hook() {
  local envs="$1" json="$2"
  echo "$json" | env $envs bash "$HOOK" 2>&1
  echo "EXIT=$?"
}

# identify passes (no peer check needed)
out=$(run_hook "OFFICER_NAME=cos" '{"tool_name":"mcp__cabinet__identify","tool_input":{}}')
echo "$out" | grep -q 'EXIT=0' && pass "mcp__cabinet__identify → allowed (no peer needed)" || fail "identify blocked unexpectedly: $out"

# send_message to unknown peer blocks
out=$(run_hook "OFFICER_NAME=cos" '{"tool_name":"mcp__cabinet__send_message","tool_input":{"to_cabinet":"nonexistent","from_agent":"cos","content":"hi"}}')
echo "$out" | grep -q 'EXIT=2' && pass "send_message → unknown peer → blocked exit 2" || fail "unknown peer not blocked: $out"

# send_message to unconsented peer (personal, consented_by_captain=false) blocks
out=$(run_hook "OFFICER_NAME=cos" '{"tool_name":"mcp__cabinet__send_message","tool_input":{"to_cabinet":"personal","from_agent":"cos","content":"hi"}}')
echo "$out" | grep -q 'EXIT=2' && echo "$out" | grep -q 'consented_by_captain=false' && pass "send_message → unconsented peer → blocked exit 2 with clear reason" || fail "unconsented peer handling wrong: $out"

echo ""
echo "--- BEHAVIOR: split-cabinet.sh dry-run ---"
out=$(bash cabinet/scripts/split-cabinet.sh --target-cabinet personal --capacity personal 2>&1)
echo "$out" | grep -q 'Mode: DRY-RUN' && pass "split-cabinet default is dry-run" || fail "split not dry-run by default"
echo "$out" | grep -q 'Done. Mode: dry-run' && pass "split exits cleanly (no writes)" || fail "split dry-run non-clean: $out"

# Unknown target cabinet rejected
err=$(bash cabinet/scripts/split-cabinet.sh --target-cabinet nonexistent --capacity personal 2>&1)
echo "$err" | grep -q "not declared in peers.yml" && pass "split-cabinet rejects unknown target" || fail "split accepted unknown target: $err"

# Invalid capacity rejected
err=$(bash cabinet/scripts/split-cabinet.sh --target-cabinet personal --capacity invalid 2>&1)
echo "$err" | grep -q 'invalid --capacity' && pass "split-cabinet rejects invalid capacity" || fail "split accepted invalid capacity"

echo ""
echo "--- BEHAVIOR: peers.yml validator rejects bad config in multi mode ---"
# Make a known-bad peers.yml temp copy
cp instance/config/peers.yml /tmp/peers-backup.yml
cat > instance/config/peers.yml <<'EOF'
peers:
  badpeer:
    role: broken
    capacity: wrong_value
    trust_level: sometimes
    consented_by_captain: maybe
    allowed_tools: [fake_tool]
EOF
# Multi mode should fail
out=$(CABINET_MODE=multi CABINET_ID=work bash cabinet/scripts/load-preset.sh 2>&1)
echo "$out" | grep -q "peers.yml validation failed" && pass "peers.yml invalid config fails boot in multi mode" || fail "multi-mode validator not firing: $out"
# Single mode should pass with warnings
out=$(bash cabinet/scripts/load-preset.sh 2>&1)
echo "$out" | grep -q "Preset 'work' loaded successfully" && pass "peers.yml invalid config warns+continues in single mode" || fail "single-mode validator broke boot"
# Restore
cp /tmp/peers-backup.yml instance/config/peers.yml
rm /tmp/peers-backup.yml
bash cabinet/scripts/load-preset.sh > /dev/null 2>&1

echo ""
echo "========================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "========================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
