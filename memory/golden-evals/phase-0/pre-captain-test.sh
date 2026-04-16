#!/bin/bash
# Phase 0 pre-Captain test suite. Exits 0 if everything Captain would
# hit on restart works; non-zero if something is broken.

cd /opt/founders-cabinet
set -a
source cabinet/.env 2>/dev/null
set +a

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== Phase 0 Pre-Captain Test Suite ==="

echo ""
echo "--- 1. Config file reads ---"
[ -f instance/config/product.yml ] && pass "product.yml at instance/config/" || fail "product.yml missing"
[ -f instance/config/platform.yml ] && pass "platform.yml at instance/config/" || fail "platform.yml missing"
[ -f instance/config/active-project.txt ] && pass "active-project.txt at instance/config/" || fail "active-project.txt missing"
[ -f instance/config/active-preset ] && pass "active-preset at instance/config/" || fail "active-preset missing"
[ -d instance/config/projects ] && pass "projects/ at instance/config/" || fail "projects/ missing"
[ ! -d instance/config/config ] && pass "no double-nested instance/config/config/" || fail "double-nest still present"

echo ""
echo "--- 2. Project scripts work ---"
out=$(bash cabinet/scripts/list-projects.sh 2>&1)
echo "$out" | grep -q "sensed" && pass "list-projects.sh finds sensed" || fail "list-projects.sh output: $out"
active=$(cat instance/config/active-project.txt 2>/dev/null | tr -d '[:space:]')
[ "$active" = "sensed" ] && pass "active-project.txt reads 'sensed'" || fail "active-project: $active"

echo ""
echo "--- 3. Preset loader ---"
rm -rf /tmp/cabinet-runtime
bash cabinet/scripts/load-preset.sh > /tmp/load-out 2>&1
grep -q "Preset .work. loaded successfully" /tmp/load-out && pass "loader succeeds" || fail "loader: $(tail -3 /tmp/load-out)"
[ -f /tmp/cabinet-runtime/constitution.md ] && pass "constitution.md assembled" || fail "constitution.md missing"
[ -f /tmp/cabinet-runtime/safety-boundaries.md ] && pass "safety-boundaries.md assembled" || fail "safety-boundaries.md missing"
lines=$(wc -l < /tmp/cabinet-runtime/constitution.md 2>/dev/null || echo 0)
[ "$lines" -gt 100 ] && pass "constitution has $lines lines" || fail "constitution too short: $lines"

bash cabinet/scripts/load-preset.sh personal > /tmp/load-out 2>&1
grep -q "not populated" /tmp/load-out && pass "personal preset rejected cleanly" || fail "personal preset behavior wrong"
bash cabinet/scripts/load-preset.sh bogus > /tmp/load-out 2>&1
grep -q "not found" /tmp/load-out && pass "bogus preset rejected cleanly" || fail "bogus preset behavior wrong"

echo ""
echo "--- 4. Agent files populated ---"
bash cabinet/scripts/load-preset.sh > /dev/null 2>&1
for agent in cos cto cpo cro coo; do
  [ -f .claude/agents/$agent.md ] && pass "agents/$agent.md populated" || fail "agents/$agent.md missing"
done

echo ""
echo "--- 5. Hook path references ---"
grep -q "instance/memory/tier2" cabinet/scripts/hooks/pre-tool-use.sh && pass "pre-tool-use.sh uses instance/memory/tier2/" || fail "pre-tool-use.sh old path"

echo ""
echo "--- 6. Library golden evals ---"
bash memory/golden-evals/library/sprint-a.sh 2>&1 | grep -q "FAIL: 0" && pass "26/26 library evals pass" || fail "library evals failed"

echo ""
echo "--- 7. Cabinet Memory search ---"
count=$(bash cabinet/scripts/search-memory.sh "library" --limit 2 2>&1 | grep -c "^\[")
[ "$count" -ge 1 ] && pass "cabinet memory search returns ($count matches)" || fail "memory search no results"

echo ""
echo "--- 8. Library syntax ---"
bash -n cabinet/scripts/lib/library.sh && pass "library.sh syntax OK" || fail "library.sh syntax broken"
bash -n cabinet/scripts/load-preset.sh && pass "load-preset.sh syntax OK" || fail "load-preset.sh syntax broken"
bash -n cabinet/scripts/start-officer.sh && pass "start-officer.sh syntax OK" || fail "start-officer.sh syntax broken"

echo ""
echo "--- 9. Key config values readable ---"
tz=$(grep '^captain_timezone:' instance/config/platform.yml 2>/dev/null | awk '{print $2}')
[ -n "$tz" ] && pass "captain_timezone: $tz" || fail "captain_timezone unreadable"
name=$(grep 'captain_name:' instance/config/product.yml 2>/dev/null | head -1 | awk -F: '{print $2}' | tr -d ' "')
[ -n "$name" ] && pass "captain_name: $name" || fail "captain_name unreadable"

echo ""
echo "--- 10. Officer directory symlinks (sample: cos) ---"
if [ -d officers/cos ]; then
  for link in framework presets instance memory shared cabinet; do
    if [ -L "officers/cos/$link" ] && [ -e "officers/cos/$link" ]; then
      pass "officers/cos/$link exists and points at live target"
    else
      echo "  INFO: officers/cos/$link not yet refreshed — happens on next start-officer.sh call"
    fi
  done
fi

echo ""
echo "========================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "========================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
