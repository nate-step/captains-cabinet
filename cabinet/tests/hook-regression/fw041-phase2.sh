#!/bin/bash
# FW-041 Phase 2 empirical bypass verifier.
# Confirms whether `git -c 'key=value with spaces' push origin main` bypasses
# the Layer 1 gate by feeding the command through pre-tool-use.sh's jq +
# regex pipeline — same way Claude Code invokes the hook in production.
set -u
HOOK="/opt/founders-cabinet/cabinet/scripts/hooks/pre-tool-use.sh"
FAIL=0
PASS=0

# Clear attestations so gate-trips return exit=2
redis-cli -h redis -p 6379 DEL "cabinet:layer1:cto:reviewed" >/dev/null 2>&1
redis-cli -h redis -p 6379 DEL "cabinet:layer1:cto:ci-green" >/dev/null 2>&1

run_case() {
  local label="$1" expected="$2" cmd="$3"
  local json ec stderr
  json=$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  stderr=$(echo "$json" | OFFICER_NAME=cto bash "$HOOK" 2>&1 >/dev/null)
  ec=$?
  if [ "$ec" = "$expected" ]; then
    printf "  [PASS] %s: exit=%d (expected=%d)\n" "$label" "$ec" "$expected"
    PASS=$((PASS + 1))
  else
    printf "  [FAIL] %s: exit=%d (expected=%d)\n" "$label" "$ec" "$expected"
    printf "         cmd: %s\n" "$cmd"
    [ -n "$stderr" ] && printf "         stderr: %s\n" "$(echo "$stderr" | head -1)"
    FAIL=$((FAIL + 1))
  fi
  redis-cli -h redis -p 6379 DEL "cabinet:layer1:cto:reviewed" >/dev/null 2>&1
  redis-cli -h redis -p 6379 DEL "cabinet:layer1:cto:ci-green" >/dev/null 2>&1
}

echo "=== FW-041 Phase 2 CLAIMED BYPASSES (want exit=2 to confirm gate fires) ==="
echo "  If any exit=0, the bypass is REAL and FW-041 Phase 2 needs the hotfix."
echo ""
# Single-quoted value with embedded space (shell-level single-quote — jq preserves)
run_case "git -c single-quoted space value" 2 "git -c 'user.name=val with space' push origin main"
# Double-quoted value with embedded space
run_case "git -c double-quoted space value" 2 "git -c \"x.y=val with space\" push origin main"
# gh --repo with quoted value (spec doesn't allow space in owner/repo, but probe anyway)
run_case "gh -R quoted value" 2 "gh -R 'nate-step/captains-cabinet' pr merge 999"
# Edge: multiple -c with one quoted
run_case "git -c plain + -c quoted" 2 "git -c user.email=a@b -c 'user.name=val space' push origin main"

echo ""
echo "=== PRESERVED POSITIVES (sanity check harness itself) ==="
run_case "bare git push main" 2 "git push origin main"
run_case "git -C path push main" 2 "git -C /workspace/product push origin main"

echo ""
echo "=== PRESERVED NEGATIVES (no false-positive from harness regex) ==="
run_case "git commit quoted" 0 "git commit -m 'fixing quoted value'"

echo ""
echo "=== SUMMARY ==="
echo "PASS: $PASS · FAIL: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "→ Phase 2 bypass CONFIRMED (at least one FAIL above = gate didn't fire on bypass form)"
  exit 1
fi
echo "→ No bypass detected (all claimed bypasses returned exit=2 as expected)"
exit 0
