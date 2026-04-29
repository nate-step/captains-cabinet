#!/bin/bash
# FW-076 pool-mode harness: generalized write-gate covers /workspace/<slug>/ slugs
# 39 probes total:
#   27 BLOCK probes  — 9 attack classes × 3 representative slugs (sensed, step-network, a1)
#   12 ALLOW probes  — FP guards for invalid slugs + read-only ops
#
# Pool-mode slug guard: [a-z0-9][a-z0-9-]* (matches FW-073 start-officer.sh:29)
# Validates the FW-076 regex generalization from /workspace/product/ literal.
# See: cabinet/tests/hook-regression/fw040-hotfix5.sh for the product-slug mirror.
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
  printf "%-6s | %-66s | exit=%s\n" "$verdict" "$label" "$exit_code"
}

# ============================================================
# BLOCK PROBES — 9 attack classes × 3 slugs
# ============================================================

echo "=== SLUG: sensed — ATTACK FORMS (must BLOCK) ==="
probe 'sensed redirect >'           'echo hello > /workspace/sensed/x'                              BLOCK
probe 'sensed append >>'            'echo x >> /workspace/sensed/x'                                 BLOCK
probe 'sensed force-overwrite >|'   'echo x >| /workspace/sensed/x'                                 BLOCK
probe 'sensed sed -i'               "sed -i 's/x/y/' /workspace/sensed/x"                          BLOCK
probe 'sensed tee'                  'tee /workspace/sensed/x'                                        BLOCK
probe 'sensed cp last-arg'          'cp /tmp/x /workspace/sensed/y'                                  BLOCK
probe 'sensed cp -t'                'cp -t /workspace/sensed/ /tmp/x'                                BLOCK
probe 'sensed cp --target-dir='     'cp --target-directory=/workspace/sensed/ /tmp/x'                BLOCK
probe 'sensed perl -i'              "perl -i -pe 's/x/y/' /workspace/sensed/x"                     BLOCK
probe 'sensed tar -cf to slug'      'tar -cf /workspace/sensed/archive.tar /tmp/src'                 BLOCK
probe 'sensed tar -xf -C slug'      'tar -xf /tmp/a.tar -C /workspace/sensed/'                      BLOCK
probe 'sensed patch'                'patch /workspace/sensed/foo < fix.patch'                        BLOCK

echo ""
echo "=== SLUG: step-network — ATTACK FORMS (must BLOCK) ==="
probe 'step-network redirect >'     'echo hello > /workspace/step-network/x'                        BLOCK
probe 'step-network append >>'      'echo x >> /workspace/step-network/x'                           BLOCK
probe 'step-network force-write >|' 'echo x >| /workspace/step-network/x'                           BLOCK
probe 'step-network sed -i'         "sed -i 's/x/y/' /workspace/step-network/x"                    BLOCK
probe 'step-network tee'            'tee /workspace/step-network/x'                                  BLOCK
probe 'step-network cp last-arg'    'cp /tmp/x /workspace/step-network/y'                            BLOCK
probe 'step-network cp -t'          'cp -t /workspace/step-network/ /tmp/x'                          BLOCK
probe 'step-network cp --target='   'cp --target-directory=/workspace/step-network/ /tmp/x'          BLOCK
probe 'step-network perl -i'        "perl -i -pe 's/x/y/' /workspace/step-network/x"               BLOCK
probe 'step-network tar -cf'        'tar -cf /workspace/step-network/archive.tar /tmp/src'           BLOCK
probe 'step-network tar -xf -C'     'tar -xf /tmp/a.tar -C /workspace/step-network/'                BLOCK
probe 'step-network patch'          'patch /workspace/step-network/foo < fix.patch'                  BLOCK

echo ""
echo "=== SLUG: a1 (short slug, digits) — ATTACK FORMS (must BLOCK) ==="
probe 'a1 redirect >'               'echo hello > /workspace/a1/x'                                  BLOCK
probe 'a1 append >>'                'echo x >> /workspace/a1/x'                                     BLOCK
probe 'a1 force-write >|'           'echo x >| /workspace/a1/x'                                     BLOCK
probe 'a1 sed -i'                   "sed -i 's/x/y/' /workspace/a1/x"                              BLOCK
probe 'a1 tee'                      'tee /workspace/a1/x'                                            BLOCK
probe 'a1 cp last-arg'              'cp /tmp/x /workspace/a1/y'                                      BLOCK
probe 'a1 cp -t'                    'cp -t /workspace/a1/ /tmp/x'                                    BLOCK
probe 'a1 cp --target-dir='         'cp --target-directory=/workspace/a1/ /tmp/x'                    BLOCK
probe 'a1 perl -i'                  "perl -i -pe 's/x/y/' /workspace/a1/x"                         BLOCK
probe 'a1 tar -cf'                  'tar -cf /workspace/a1/archive.tar /tmp/src'                     BLOCK
probe 'a1 tar -xf -C'               'tar -xf /tmp/a.tar -C /workspace/a1/'                          BLOCK
probe 'a1 patch'                    'patch /workspace/a1/foo < fix.patch'                            BLOCK

# ============================================================
# ALLOW PROBES — FP guards
# ============================================================

echo ""
echo "=== ALLOW PROBES — invalid slugs + read-only ops (must ALLOW) ==="

# Invalid slug forms — slug guard [a-z0-9][a-z0-9-]* rejects these:
probe 'FP: /workspace/PROD/ uppercase'      "echo x > /workspace/PROD/file"                         ALLOW
probe 'FP: /workspace/-bad/ lead-hyphen'    "echo x > /workspace/-bad/file"                         ALLOW
probe 'FP: /workspace/.git/ lead-dot'       "echo x > /workspace/.git/file"                         ALLOW
# Note: /workspace/products/ — the slug class [a-z0-9][a-z0-9-]* IS greedy and
# WILL match "products" as a valid slug (all lowercase alpha). This is documented
# behavior: the generalized regex deliberately protects ANY valid pool slug, so
# "products" is a protectable slug name (just not one in use today).
# The test below documents that it BLOCKS, which is the correct fail-closed posture.
probe 'NOTE: /workspace/products/ (valid slug greedy match, correctly BLOCKS)' \
                                            "echo x > /workspace/products/file"                      BLOCK

# Read-only and non-write ops on valid slugs — must all ALLOW:
probe 'cat /workspace/sensed/x read-only'   'cat /workspace/sensed/x'                               ALLOW
probe 'grep foo /workspace/sensed/src/'     'grep foo /workspace/sensed/src/'                       ALLOW
probe 'cd /workspace/sensed && ls'          'cd /workspace/sensed && ls'                             ALLOW
probe 'cat /workspace/sensed/x | tee /tmp' 'cat /workspace/sensed/x | tee /tmp/y'                  ALLOW
probe 'cp /workspace/sensed/x /tmp/y'      'cp /workspace/sensed/x /tmp/y'                         ALLOW
probe 'git -C /workspace/sensed log'        'git -C /workspace/sensed log --oneline'                 ALLOW
probe 'rsync -rt /workspace/sensed/ /tmp'   'rsync -rt /workspace/sensed/ /tmp/dst'                  ALLOW
probe 'FP: /workspace/foo bar/ space'       "echo x > \"/workspace/foo bar/file\""                   ALLOW

echo ""
echo "=== Summary: PASS=$PASS  FAIL=$FAIL ==="
exit $FAIL
