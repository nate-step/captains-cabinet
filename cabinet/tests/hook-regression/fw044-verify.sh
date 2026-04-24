#!/bin/bash
# FW-044 harness: gh api -X DELETE refs/heads/main bypass
# 47 probes: 4 ACs + 6 flag-variants + 7 safe + 4 branch-disambig + 4 splice
# + 5 data-position + 9 adversary + 8 review-agent FPs
HOOK=/opt/founders-cabinet/cabinet/scripts/hooks/pre-tool-use.sh
PASS=0; FAIL=0

probe() {
  local label="$1" cmd="$2" expected="$3"
  # Reset key before each probe so one match doesn't consume it
  redis-cli -h redis -p 6379 DEL cabinet:layer1:cto:reviewed > /dev/null 2>&1
  local result
  result=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$cmd" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}}" | OFFICER_NAME=cto bash "$HOOK" 2>/dev/null; echo "EXIT:$?")
  local exit_code="${result##*EXIT:}"
  local verdict
  if [ "$expected" = "BLOCK" ]; then
    if [ "$exit_code" = "2" ]; then verdict="PASS"; PASS=$((PASS+1)); else verdict="FAIL"; FAIL=$((FAIL+1)); fi
  else
    if [ "$exit_code" = "0" ]; then verdict="PASS"; PASS=$((PASS+1)); else verdict="FAIL"; FAIL=$((FAIL+1)); fi
  fi
  printf "%-6s | %-58s | exit=%s\n" "$verdict" "$label" "$exit_code"
}

echo "=== FW-044 ACs ==="
probe 'AC1 -X DELETE main'       'gh api -X DELETE repos/OWNER/REPO/git/refs/heads/main'   BLOCK
probe 'AC2 -X DELETE master'     'gh api -X DELETE repos/OWNER/REPO/git/refs/heads/master' BLOCK
probe 'AC3 GET default main'     'gh api repos/OWNER/REPO/git/refs/heads/main'             ALLOW
probe 'AC4 non-main branch'      'gh api -X DELETE repos/OWNER/REPO/git/refs/heads/feature' ALLOW

echo ""
echo "=== Flag-variant forms (all must BLOCK) ==="
probe 'F1 --method DELETE'       'gh api --method DELETE repos/O/R/git/refs/heads/main'    BLOCK
probe 'F2 -X DELETE at end'      'gh api repos/O/R/git/refs/heads/main -X DELETE'          BLOCK
probe 'F3 --method at end'       'gh api repos/O/R/git/refs/heads/master --method DELETE'  BLOCK
probe 'F4 --method=DELETE eq'    'gh api --method=DELETE repos/O/R/git/refs/heads/main'    BLOCK
probe 'F5 --method=DELETE end'   'gh api repos/O/R/git/refs/heads/master --method=DELETE'  BLOCK
probe 'F6 flags before api'      'gh --help=false api -X DELETE repos/O/R/git/refs/heads/main' BLOCK

echo ""
echo "=== Safe forms (must ALLOW) ==="
probe 'S1 gh pr view'            'gh pr view 42'                                           ALLOW
probe 'S2 gh repo list'          'gh repo list'                                            ALLOW
probe 'S3 gh api user'           'gh api user'                                             ALLOW
probe 'S4 gh api -X GET ref'     'gh api -X GET repos/O/R/git/refs/heads/feature'          ALLOW
probe 'S5 gh api DELETE issue'   'gh api -X DELETE repos/O/R/issues/comments/42'           ALLOW
probe 'S6 gh api graphql'        'gh api graphql -f query=XXX'                             ALLOW
probe 'S7 gh api POST dispatch'  'gh api -X POST repos/O/R/dispatches'                     ALLOW

echo ""
echo "=== Branch disambiguation (must ALLOW — not exact main/master) ==="
probe 'B1 branch mainline'       'gh api -X DELETE repos/O/R/git/refs/heads/mainline'      ALLOW
probe 'B2 branch main.md'        'gh api -X DELETE repos/O/R/git/refs/heads/main.md'       ALLOW
probe 'B3 branch mastership'     'gh api -X DELETE repos/O/R/git/refs/heads/mastership'    ALLOW
probe 'B4 branch main-feature'   'gh api -X DELETE repos/O/R/git/refs/heads/main-feature'  ALLOW

echo ""
echo "=== Splice/BSQ forms (closed by FW-051 — Layer 1 triple-scan) ==="
probe 'SP1 quoted-splice gh'     '"gh" api -X DELETE repos/O/R/git/refs/heads/main'        BLOCK
probe 'SP2 inner-quote gh'       'g"h" api -X DELETE repos/O/R/git/refs/heads/main'        BLOCK
probe 'SP3 backslash-splice'     '\"gh\" api -X DELETE repos/O/R/git/refs/heads/main'      BLOCK
probe 'SP4 empty-quote splice'   'gh"" api -X DELETE repos/O/R/git/refs/heads/main'        BLOCK

echo ""
echo "=== Data-position forms (must ALLOW — keyword in grep/echo/cat body) ==="
probe 'D1 echo the string'       'echo "gh api -X DELETE refs/heads/main"'                 ALLOW
probe 'D2 grep for the string'   'grep "gh api -X DELETE" /tmp/log.txt'                    ALLOW
probe 'D3 git commit body'       'git commit -m "fixed gh api -X DELETE refs/heads/main bug"' ALLOW
probe 'D4 cat docs'              'cat /tmp/fw044-notes.md'                                 ALLOW
probe 'D5 notify prose'          'notify-officer.sh cpo "investigated gh api -X DELETE bypass"' ALLOW

echo ""
echo "=== Adversary Pass-1 bypasses (must BLOCK — FW-044 scope) ==="
probe 'A2 -XDELETE fused HIGH'   'gh api -XDELETE repos/O/R/git/refs/heads/main'           BLOCK
probe 'A5 -X "DELETE" quoted'    'gh api -X "DELETE" repos/O/R/git/refs/heads/main'        BLOCK
probe 'A6 -X delete lowercase'   'gh api -X delete repos/O/R/git/refs/heads/main'          BLOCK
probe 'A6b --method=delete lc'   'gh api --method=delete repos/O/R/git/refs/heads/main'    BLOCK
probe 'B1 trailing slash ref'    'gh api -X DELETE repos/O/R/git/refs/heads/main/'         BLOCK
probe 'C3 curl DELETE HIGH'      'curl -X DELETE -H "Authorization: token $T" https://api.github.com/repos/O/R/git/refs/heads/main'  BLOCK
probe 'D1 branch-protection'     'gh api -X DELETE repos/O/R/branches/main/protection'     BLOCK
probe 'D1b protection master'    'gh api -X DELETE repos/O/R/branches/master/protection'   BLOCK

echo ""
echo "=== Adversary bypasses: B2 closed by FW-051; B3/E3 still deferred ==="
probe 'B2 URL-enc ref'           'gh api -X DELETE repos/O/R/git/refs%2fheads%2fmain'      BLOCK
probe 'B3 wildcard ref'          'gh api -X DELETE repos/O/R/git/refs/heads/m*'            ALLOW
probe 'E3 subshell splice'       '$(echo gh) api -X DELETE repos/O/R/git/refs/heads/main'  ALLOW

echo ""
echo "=== Review agent FPs (must ALLOW — clause-exclusion + boundary-anchor) ==="
probe 'MC1 semicolon compound'   'gh api user; gh api -X DELETE repos/O/R/issues/comments/42' ALLOW
probe 'MC2 && compound'          'gh api user && gh api -X DELETE repos/O/R/issues/comments/42' ALLOW
probe 'MC3 && echo body'         'gh api user && echo "gh api -X DELETE refs/heads/main"'  ALLOW
probe 'ND1 git commit body'      'gh api user && git commit -m "fixed DELETE refs/heads/main bug"' ALLOW
probe 'ND2 comment clause'       'gh api user # TODO: -X DELETE refs/heads/main'           ALLOW
probe 'ND3 pipe to grep'         'gh api user | grep "DELETE refs/heads/main"'             ALLOW
probe 'WH1 webhook POST'         'gh api -X POST /user/events -f action=DELETE -f ref=refs/heads/main' ALLOW
probe 'HD1 heredoc body (fail-closed blocks)' 'cat <<EOF
gh api -X DELETE refs/heads/main
EOF'  BLOCK

echo ""
echo "=== Adversary Pass-2 bypasses (must BLOCK — Pass-3 fix) ==="
probe 'PA-A1 ?v=1 query refs'     'gh api -X DELETE repos/O/R/git/refs/heads/main?v=1'       BLOCK
probe 'PA-A2 ?v=1 full URL'       'curl -X DELETE https://api.github.com/repos/O/R/git/refs/heads/main?v=1' BLOCK
probe 'PA-A3 ?v=1 protection'     'gh api -X DELETE repos/O/R/branches/main/protection?v=1'  BLOCK
probe 'PA-B1 wget --method=DEL'   'wget --method=DELETE https://api.github.com/repos/O/R/git/refs/heads/main' BLOCK
probe 'PA-B2 wget --method DEL'   'wget --method DELETE https://api.github.com/repos/O/R/git/refs/heads/main' BLOCK
probe 'PA-C1 GH_TOKEN= envvar'    'GH_TOKEN=abc gh api -X DELETE repos/O/R/git/refs/heads/main' BLOCK
probe 'PA-C2 FOO=bar envvar'      'FOO=bar gh api -X DELETE repos/O/R/git/refs/heads/main'   BLOCK
probe 'PA-C3 2 envvars'           'GH_TOKEN=abc FOO=bar gh api -X DELETE repos/O/R/git/refs/heads/main' BLOCK

echo ""
echo "=== Adversary Pass-2 closed by FW-051 (quote-concat) ==="
probe 'PA-D1 sq-concat DELETE'   'gh api -X '\''DE'\'''\''LETE'\'' repos/O/R/git/refs/heads/main' BLOCK
probe 'PA-D2 dq-concat DELETE'   'gh api -X "DE""LETE" repos/O/R/git/refs/heads/main'       BLOCK

echo ""
echo "=== Adversary Pass-2 non-bypasses (must ALLOW — legitimate) ==="
probe 'PA-E1 UPPERCASE MAIN'     'gh api -X DELETE repos/O/R/git/refs/heads/MAIN'           ALLOW
probe 'PA-E2 UPPERCASE MASTER'   'gh api -X DELETE repos/O/R/git/refs/heads/MASTER'         ALLOW

echo ""
echo "=== Summary: PASS=$PASS  FAIL=$FAIL ==="
exit $FAIL
