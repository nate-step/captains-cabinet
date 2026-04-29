#!/bin/bash
# FW-056 baseline harness: tar Pattern 9a/9b coverage post-fix
# 29 probes: 12 9a-attack + 2 9a-FP + 6 9a-legit + 7 9b-attack + 2 9b-legit
#
# Closes the long-standing /tmp-only FW-040 hotfix harness gap (task #141 missed it).
HOOK=/opt/founders-cabinet/cabinet/scripts/hooks/pre-tool-use.sh
PASS=0; FAIL=0

probe() {
  local label="$1" cmd="$2" expected="$3"
  local result
  result=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$cmd" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}}" | CABINET_HOOK_TEST_MODE=1 OFFICER_NAME=cos bash "$HOOK" 2>/dev/null; echo "EXIT:$?")
  local exit_code="${result##*EXIT:}"
  local verdict
  if [ "$expected" = "BLOCK" ]; then
    if [ "$exit_code" = "2" ]; then verdict="PASS"; PASS=$((PASS+1)); else verdict="FAIL"; FAIL=$((FAIL+1)); fi
  else
    if [ "$exit_code" = "0" ]; then verdict="PASS"; PASS=$((PASS+1)); else verdict="FAIL"; FAIL=$((FAIL+1)); fi
  fi
  printf "%-6s | %-44s | exit=%s\n" "$verdict" "$label" "$exit_code"
}

echo "=== Pattern 9a — ATTACK FORMS (extract INTO product, must BLOCK) ==="
probe "9a-A1 -x ... -C /prod/"             'tar -x -C /workspace/product/ -f /tmp/a.tar'         BLOCK
probe "9a-A2 -x ... -C /prod (no slash)"   'tar -x -C /workspace/product -f /tmp/a.tar'          BLOCK
probe "9a-A3 -xC bundled /prod/"           'tar -xC /workspace/product/ -f /tmp/a.tar'           BLOCK
probe "9a-A4 -xC bundled /prod"            'tar -xC /workspace/product -f /tmp/a.tar'            BLOCK
probe "9a-A5 -xf ... -C /prod/"            'tar -xf /tmp/a.tar -C /workspace/product/'           BLOCK
probe "9a-A6 -xf ... -C /prod"             'tar -xf /tmp/a.tar -C /workspace/product'            BLOCK
probe "9a-A7 -x --dir /prod"               'tar -x --directory /workspace/product -f /tmp/a.tar' BLOCK
probe "9a-A8 -x --dir=/prod"               'tar -x --directory=/workspace/product -f /tmp/a.tar' BLOCK
probe "9a-A9 -x --dir=/prod/"              'tar -x --directory=/workspace/product/ -f /tmp/a.tar' BLOCK
probe "9a-A10 -xf -C/prod/ no-space"       'tar -xf /tmp/a.tar -C/workspace/product/'            BLOCK
probe "9a-A11 -xf -C/prod no-space slash"  'tar -xf /tmp/a.tar -C/workspace/product'             BLOCK
probe "9a-A12 -vxC bundled multi"          'tar -vxC /workspace/product/ -f /tmp/a.tar'          BLOCK

echo ""
echo "=== Pattern 9a — KNOWN-FP READ-SOURCE FORMS (-c mode reads product, accepted FP) ==="
probe "9a-FP1 -c -C /prod/ + -f /tmp"      'tar -cf /tmp/a.tar -C /workspace/product/ .'         BLOCK
probe "9a-FP2 -c -C /prod + -f /tmp"       'tar -cf /tmp/a.tar -C /workspace/product .'          BLOCK

echo ""
echo "=== Pattern 9a — LEGITIMATE NON-PRODUCT FORMS (must ALLOW) ==="
probe "9a-L1 -xf -C /tmp/dest/"            'tar -xf /tmp/a.tar -C /tmp/dest/'                    ALLOW
probe "9a-L2 -xf -C /tmp/dest no-slash"    'tar -xf /tmp/a.tar -C /tmp/dest'                     ALLOW
probe "9a-L3 -xf no -C"                    'tar -xf /tmp/a.tar'                                  ALLOW
probe "9a-L4 -tf list"                     'tar -tf /tmp/a.tar'                                  ALLOW
probe "9a-L5 --version"                    'tar --version'                                       ALLOW
probe "9a-L6 -xf UPPER slug (not a slug)"   'tar -xf /tmp/a.tar -C /workspace/PROD/'              ALLOW

echo ""
echo "=== Pattern 9b — ATTACK FORMS (write archive TO product path, must BLOCK) ==="
probe "9b-A1 -cf /prod/x.tar"              'tar -cf /workspace/product/leak.tar /tmp/src'        BLOCK
probe "9b-A2 -cvf /prod/x.tar"             'tar -cvf /workspace/product/leak.tar /tmp/src'       BLOCK
probe "9b-A3 --file=/prod/x.tar"           'tar --file=/workspace/product/leak.tar -c /tmp/src'  BLOCK
probe "9b-A4 --file /prod/x.tar"           'tar --file /workspace/product/leak.tar -c /tmp/src'  BLOCK
probe "9b-A5 -cf/prod/x.tar no-space"      'tar -cf/workspace/product/leak.tar /tmp/src'         BLOCK
probe "9b-A6 -czf /prod/sub/x.tar deep"    'tar -czf /workspace/product/sub/leak.tar /tmp/src'   BLOCK
probe "9b-A7 -cf /prod no-slash"           'tar -cf /workspace/product /tmp/src'                 BLOCK

echo ""
echo "=== Pattern 9b — LEGITIMATE FORMS (must ALLOW) ==="
probe "9b-L1 -xf /tmp/a.tar"               'tar -xf /tmp/a.tar'                                  ALLOW
probe "9b-L2 -cf /tmp/safe.tar /tmp/src"   'tar -cf /tmp/safe.tar /tmp/src'                      ALLOW

echo ""
echo "=== Summary: PASS=$PASS  FAIL=$FAIL ==="
exit $FAIL
