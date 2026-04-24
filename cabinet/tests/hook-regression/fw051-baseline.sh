#!/bin/bash
# FW-051 baseline probe — verify current gate state against 12 ACs
# Expected pre-fix: AC-1,2,6,7,8,9,10,11 = exit 0 (fail-open, bypass)
#                   AC-5 = exit 0 (benign heredoc, correctly passes)
#                   AC-12 = verified via EVAL-014

HOOK=/opt/founders-cabinet/cabinet/scripts/hooks/pre-tool-use.sh

probe() {
  local label="$1"; local cmd="$2"; local expect="$3"
  local json=$(jq -cn --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}')
  # clear reviewed gate so we test the raw block path
  redis-cli -h redis -p 6379 DEL cabinet:layer1:cto:reviewed >/dev/null 2>&1
  CABINET_HOOK_TEST_MODE=1 OFFICER_NAME=cto bash "$HOOK" <<<"$json" >/dev/null 2>&1
  local ec=$?
  local result="?"
  if [ "$expect" = "BLOCK" ]; then
    [ "$ec" = "2" ] && result="PASS" || result="FAIL(bypass)"
  elif [ "$expect" = "PASS" ]; then
    [ "$ec" = "0" ] && result="PASS" || result="FAIL(FP)"
  fi
  printf "  [exit=%d %s] %-40s %s\n" "$ec" "$result" "$label" "$cmd"
}

echo "=== FW-051 Phase 1 scope: MUST BLOCK ==="
probe "AC-1 SP1-dq-wrap-gh"   '"gh" api -X DELETE repos/O/R/git/refs/heads/main' BLOCK
probe "AC-2 SP2-dq-split-gh"  'g"h" api -X DELETE repos/O/R/git/refs/heads/main' BLOCK
probe "AC-6 PA-D1-sq-concat"  "gh api -X 'DE''LETE' repos/O/R/git/refs/heads/main" BLOCK
probe "AC-7 PA-D2-dq-concat"  'gh api -X "DE""LETE" repos/O/R/git/refs/heads/main' BLOCK
probe "AC-8 CA1-escape-eval"  'eval "PATH=\"foo bar\" gh api -X DELETE refs/heads/main"' BLOCK
probe "AC-9 P2-A1-var-concat" "FOO=''hello world'' gh api -X DELETE refs/heads/main" BLOCK
probe "AC-10 full-path-shell" '/bin/bash -c "gh api -X DELETE refs/heads/main"' BLOCK
probe "AC-11 fused-lc-flag"   'bash -lc "gh api -X DELETE refs/heads/main"' BLOCK

echo ""
echo "=== FW-051 deferred scope (AC-3/4 not targeted in Phase 1): ==="
probe "AC-3 E3-subshell"      '$(echo gh) api -X DELETE repos/O/R/git/refs/heads/main' BLOCK
probe "AC-4 B2-urlencoded"    'gh api -X DELETE repos/O/R/git/refs%2fheads%2fmain' BLOCK

echo ""
echo "=== FW-051 regression guards: MUST PASS (no prompt) ==="
probe "AC-5 benign-heredoc"   $'cat <<EOF\ngh api user\nEOF' PASS
probe "REG-1 git-commit-body" 'git commit -m "git push origin main"' PASS
probe "REG-2 echo-body"       'echo "gh api -X DELETE refs/heads/main"' PASS
probe "REG-3 grep-body"       'grep "gh api -X DELETE refs/heads/main" logfile' PASS
probe "REG-4 gh-pr-view"      'gh pr view 42' PASS
probe "REG-5 git-log"         'git log --oneline' PASS
probe "REG-6 git-C-ansi"      "git -C \$'my dir' log" PASS
