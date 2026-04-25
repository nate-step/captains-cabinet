#!/bin/bash
# FW-040 Hotfix 5 harness: perl -i inplace-edit + tar -xf -C write-gate scope-gaps
# 48 probes: 11 perl-attack + 7 perl-legit + 13 tar-attack + 7 tar-legit
# + 5 cross-pattern regression + 5 data-position FP
HOOK=/opt/founders-cabinet/cabinet/scripts/hooks/pre-tool-use.sh
PASS=0; FAIL=0

probe() {
  local label="$1" cmd="$2" expected="$3"
  local result
  result=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$cmd" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}}" | CABINET_HOOK_TEST_MODE=1 OFFICER_NAME=cpo bash "$HOOK" 2>/dev/null; echo "EXIT:$?")
  local exit_code="${result##*EXIT:}"
  local verdict
  if [ "$expected" = "BLOCK" ]; then
    if [ "$exit_code" = "2" ]; then verdict="PASS"; PASS=$((PASS+1)); else verdict="FAIL"; FAIL=$((FAIL+1)); fi
  else
    if [ "$exit_code" = "0" ]; then verdict="PASS"; PASS=$((PASS+1)); else verdict="FAIL"; FAIL=$((FAIL+1)); fi
  fi
  printf "%-6s | %-62s | exit=%s\n" "$verdict" "$label" "$exit_code"
}

echo "=== PERL -i ATTACK FORMS (must BLOCK) ==="
probe 'P1 perl -i basic'         'perl -i -pe "s/x/y/" /workspace/product/file.ts'                BLOCK
probe 'P2 perl -i.bak suffix'    'perl -i.bak -pe "s/x/y/" /workspace/product/file.ts'            BLOCK
probe 'P3 perl -pi reversed'     'perl -pi -e "s/x/y/" /workspace/product/file.ts'                BLOCK
probe 'P4 perl -ipe bundled'     'perl -ipe "s/x/y/" /workspace/product/file.ts'                  BLOCK
probe 'P5 perl -i.bak extra-w'   'perl -i.bak -pe "s/x/y/" -w /workspace/product/file.ts'         BLOCK
probe 'P6 perl -i.bak no-space'  'perl -i.bak -p -e "s/x/y/" /workspace/product/src/app.ts'       BLOCK
probe 'P7 perl -i deep path'     'perl -i -pe "s/foo/bar/" /workspace/product/src/components/ui/button.tsx' BLOCK
probe 'P8 perl -i quoted path'   "perl -i -pe 's/x/y/' '/workspace/product/file.ts'"              BLOCK
probe 'P9 perl -pi.bak bundled'  'perl -pi.bak -e "s/a/b/" /workspace/product/x.js'               BLOCK
probe 'P10 perl -i0 inplace'     'perl -i0 -pe "s/x/y/" /workspace/product/file.ts'               BLOCK
probe 'P11 perl -ni inplace'     'perl -ni -e "print if /match/" /workspace/product/file.ts'      BLOCK

echo ""
echo "=== PERL LEGITIMATE FORMS (must ALLOW) ==="
probe 'PL1 perl --version'       'perl --version'                                                 ALLOW
probe 'PL2 perl -e no product'   'perl -e "print \"Hello\""'                                      ALLOW
probe 'PL3 perl -ne no inplace'  'perl -ne "print if /regex/" /tmp/log'                           ALLOW
probe 'PL4 perl -pi /tmp/ only'  'perl -pi -e "s/x/y/" /tmp/file'                                 ALLOW
probe 'PL5 perl -pe stdout'      'perl -pe "s/x/y/" /workspace/product/file.ts'                   ALLOW
probe 'PL6 perl -n read product' 'perl -n -e "print if /pattern/" /workspace/product/file.ts'     ALLOW
probe 'PL7 perl no -i flag'      'perl -e "open(F,\"/workspace/product/x\"); print <F>"'          ALLOW

echo ""
echo "=== TAR ATTACK FORMS (must BLOCK) ==="
probe 'T1 tar -xf -C product'   'tar -xf archive.tar -C /workspace/product/'                      BLOCK
probe 'T2 tar -xvf -C product'  'tar -xvf archive.tar -C /workspace/product/'                     BLOCK
probe 'T3 tar -xf --directory'  'tar -xf archive.tar --directory /workspace/product/'             BLOCK
probe 'T4 tar -xf --directory=' 'tar -xf archive.tar --directory=/workspace/product/'             BLOCK
probe 'T5 tar -C first -xf'     'tar -C /workspace/product/ -xf archive.tar'                      BLOCK
probe 'T6 tar --extract --dir'  'tar --extract --directory=/workspace/product/ -f archive.tar'    BLOCK
probe 'T7 tar -cf at product'   'tar -cf /workspace/product/archive.tar /some/src'                BLOCK
probe 'T8 tar -xvzf -C product' 'tar -xvzf archive.tar.gz -C /workspace/product/'                 BLOCK
probe 'T9 tar -x --dir eq'      'tar -x --directory=/workspace/product/ -f archive.tar'           BLOCK
probe 'T10 tar --create file'   'tar --create -f /workspace/product/backup.tar /data'             BLOCK
probe 'T11 tar -xf deep dir'    'tar -xf app.tar -C /workspace/product/src/components/'           BLOCK
probe 'T12 tar -C -x reorder'   'tar -C /workspace/product/src/ -xzvf bundle.tar.gz'              BLOCK
probe 'T13 tar -C/prod nospace' 'tar -C/workspace/product/ -xf archive.tar'                       BLOCK

echo ""
echo "=== TAR LEGITIMATE FORMS (must ALLOW) ==="
probe 'TL1 tar -xf no -C'       'tar -xf archive.tar'                                             ALLOW
probe 'TL2 tar -xf /tmp/'       'tar -xf archive.tar -C /tmp/'                                    ALLOW
probe 'TL3 tar -tf list only'   'tar -tf archive.tar'                                             ALLOW
probe 'TL4 tar -tvf verbose'    'tar -tvf archive.tar'                                            ALLOW
probe 'TL5 tar -cf no product'  'tar -cf /tmp/backup.tar /home/user'                              ALLOW
probe 'TL6 tar -xf /var/'       'tar -xf archive.tar -C /var/tmp/'                                ALLOW
probe 'TL7 tar --list archive'  'tar --list -f archive.tar'                                       ALLOW

echo ""
echo "=== REGRESSION — EXISTING PATTERNS (must ALLOW) ==="
probe 'R1 redirect /tmp'        'echo "hello" > /tmp/output.txt'                                  ALLOW
probe 'R2 cat product'          'cat /workspace/product/file.ts'                                  ALLOW
probe 'R3 sed /tmp target'      'sed -i "s/x/y/" /tmp/file.txt'                                   ALLOW
probe 'R4 cp product src'       'cp /workspace/product/file.ts /tmp/'                             ALLOW
probe 'R5 git log product'      'git -C /workspace/product log --oneline -10'                     ALLOW

echo ""
echo "=== DATA-POSITION FP TESTS ==="
# D1/D2: echo with quoted attack string inside — fail-closed BLOCK accepted per FW-045 FP-1
# (pattern lacks statement-boundary anchor; officer workaround: omit /workspace/product/ from echo body)
probe 'D1 echo perl str(FP-ok)' 'echo "perl -i /workspace/product/x"'                             BLOCK
probe 'D2 echo tar str (FP-ok)' 'echo "tar -xf a.tar -C /workspace/product/"'                     BLOCK
probe 'D3 grep perl string'     'grep "perl -i" /tmp/log.txt'                                     ALLOW
probe 'D4 git commit mentions'  'git commit -m "fixed perl -i issue in workspace"'                ALLOW
probe 'D5 cat log with paths'   'cat /tmp/tar-extract-log.txt'                                    ALLOW

echo ""
echo "=== Summary: PASS=$PASS  FAIL=$FAIL ==="
exit $FAIL
