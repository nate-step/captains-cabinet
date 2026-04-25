#!/bin/bash
# FW-040 hotfix-6 v2 harness: Pattern 8 -Ti/-Wi/-0777i variants + Pattern 9a/9b regression
# 30 probes: 3 Sonnet-pass-2 perl-uppercase + 5 -I FP-sanity + 12 Pattern-8-attack
# + 4 Pattern-8 FP control + 4 Pattern-9b regression + 2 Pattern-9a regression
HOOK=/opt/founders-cabinet/cabinet/scripts/hooks/pre-tool-use.sh
PASS=0; FAIL=0
probe() {
  local label="$1" cmd="$2" expected="$3"
  local json
  json=$(jq -cn --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}')
  CABINET_HOOK_TEST_MODE=1 OFFICER_NAME=cos bash "$HOOK" <<<"$json" >/dev/null 2>&1
  local code=$?
  local verdict
  if [ "$expected" = "BLOCK" ]; then
    [ "$code" = "2" ] && verdict="PASS" || verdict="FAIL"
  else
    [ "$code" = "0" ] && verdict="PASS" || verdict="FAIL"
  fi
  [ "$verdict" = "PASS" ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
  printf "%-6s [exit=%d expect=%s] %-40s %s\n" "$verdict" "$code" "$expected" "$label" "$cmd"
}

echo "=== Sonnet Pass-2 findings (must now BLOCK) ==="
probe "S2-F1a-uppercase-Ti"   "perl -Ti /workspace/product/f" BLOCK
probe "S2-F1b-uppercase-Wi"   "perl -Wi.bak -e 's/x/y/' /workspace/product/f" BLOCK
probe "S2-F2-digit-0777i"     "perl -0777i.bak -e 's/x/y/gs' /workspace/product/f" BLOCK

echo ""
echo "=== FP sanity: -I include paths (must ALLOW) ==="
probe "FP-I1-abs-path"        "perl -I/usr/local/lib -pe 's/' /workspace/product/f" ALLOW
probe "FP-I2-relative"        "perl -Iinclude_dir -pe 's/' /workspace/product/f" ALLOW
probe "FP-I3-dot-slash"       "perl -I./include -pe 's/' /workspace/product/f" ALLOW
probe "FP-I4-path-with-i"     "perl -I/usr/local/lib -pe 's/' /workspace/product/f" ALLOW
probe "FP-I5-ilib"            "perl -Ilib -pe 's/' /workspace/product/f" ALLOW

echo ""
echo "=== Pattern 8 regression (must still BLOCK) ==="
probe "P8-1-bare-i"            "perl -i /workspace/product/f" BLOCK
probe "P8-2-pi"                "perl -pi /workspace/product/f" BLOCK
probe "P8-3-i-bak"             "perl -i.bak -e 's/' /workspace/product/f" BLOCK
probe "P8-4-ipe"               "perl -ipe 's/' /workspace/product/f" BLOCK
probe "P8-5-ni"                "perl -ni /workspace/product/f" BLOCK
probe "P8-6-i0"                "perl -i0 -e 's/' /workspace/product/f" BLOCK
probe "P8-7-in-place-long"     "perl --in-place -pe 's/' /workspace/product/f" BLOCK
probe "P8-8-in-place-eq"       "perl --in-place=.bak -pe 's/' /workspace/product/f" BLOCK
probe "P8-9-li"                "perl -li -e 's/' /workspace/product/f" BLOCK
probe "P8-10-wi"               "perl -wi /workspace/product/f" BLOCK
probe "P8-11-si"               "perl -si /workspace/product/f" BLOCK
probe "P8-12-ai"               "perl -ai /workspace/product/f" BLOCK

echo ""
echo "=== Pattern 8 FP controls (must ALLOW) ==="
probe "P8-FP1-pe"              "perl -pe 's/' /workspace/product/f" ALLOW
probe "P8-FP2-ne"              "perl -ne 's/' /workspace/product/f" ALLOW
probe "P8-FP3-de1"             "perl -de1 /workspace/product/f" ALLOW
probe "P8-FP4-wn"              "perl -wn /workspace/product/f" ALLOW

echo ""
echo "=== Pattern 9b regression ==="
probe "P9b-1-cf"               "tar -cf /workspace/product/archive.tar /tmp/src" BLOCK
probe "P9b-2-czf"              "tar -czf /workspace/product/archive.tar /tmp/src" BLOCK
probe "P9b-3-file-long"        "tar --file=/workspace/product/archive.tar -c /tmp/src" BLOCK
probe "P9b-4-file-space"       "tar --file /workspace/product/archive.tar -c /tmp/src" BLOCK

echo ""
echo "=== Pattern 9a regression ==="
probe "P9a-1-C-space"          "tar -C /workspace/product -czf /tmp/a.tar ." BLOCK
probe "P9a-2-directory-long"   "tar --directory=/workspace/product -czf /tmp/a.tar ." BLOCK

echo ""
echo "=== Summary: PASS=$PASS  FAIL=$FAIL ==="
exit $FAIL
