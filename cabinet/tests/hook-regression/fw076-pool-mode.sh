#!/bin/bash
# FW-076 pool-mode harness: generalized /workspace/<slug>/ write-gate coverage
# Exercises 3 representative slugs (sensed, step-network, a1) across 9 attack
# classes + 12 ALLOW probes (false-positive guards).
#
# 27 BLOCK probes (3 slugs × 9 attack classes: redirect, sed-i, tee, cp-last,
# cp-t, cp-target-dir, patch, perl-i, tar) + 12 ALLOW probes = 39 total.
#
# Pool-mode mirror of fw040-hotfix5.sh + fw056-baseline.sh for non-product slugs.
# CABINET_HOOK_TEST_MODE=1 must be set inline per every probe (no global export)
# per feedback_test_harness_production_sinks.md.
# Resolve HOOK relative to this script's repo root (works in main repo or any worktree)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HOOK="$REPO_ROOT/cabinet/scripts/hooks/pre-tool-use.sh"
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
  printf "%-6s | %-56s | exit=%s\n" "$verdict" "$label" "$exit_code"
}

# ------------------------------------------------------------------
# SLUG: sensed
# ------------------------------------------------------------------
echo "=== BLOCK: slug=sensed (must BLOCK for non-CTO) ==="
probe "sensed P1 redirect"           'echo x > /workspace/sensed/README.md'                         BLOCK
probe "sensed P2 sed -i"             'sed -i "s/x/y/" /workspace/sensed/src/app.ts'                 BLOCK
probe "sensed P3 tee"                'tee /workspace/sensed/log.md'                                 BLOCK
probe "sensed P4 cp last-arg"        'cp /tmp/x /workspace/sensed/dst'                              BLOCK
probe "sensed P5 cp -t"              'cp -t /workspace/sensed/ /tmp/src'                            BLOCK
probe "sensed P6 cp --target-dir"    'cp --target-directory=/workspace/sensed/ /tmp/src'            BLOCK
probe "sensed P7 patch"              'patch /workspace/sensed/foo < fix.patch'                      BLOCK
probe "sensed P8 perl -i"            'perl -i -pe "s/x/y/" /workspace/sensed/file.ts'              BLOCK
probe "sensed P9 tar -C"             'tar -xf archive.tar -C /workspace/sensed/'                   BLOCK

# ------------------------------------------------------------------
# SLUG: step-network (hyphenated slug — validates [a-z0-9-]* accepts hyphens)
# ------------------------------------------------------------------
echo ""
echo "=== BLOCK: slug=step-network (must BLOCK for non-CTO) ==="
probe "step-net P1 redirect"         'echo x > /workspace/step-network/README.md'                  BLOCK
probe "step-net P2 sed -i"           'sed -i "s/x/y/" /workspace/step-network/src/app.ts'          BLOCK
probe "step-net P3 tee"              'tee /workspace/step-network/log.md'                           BLOCK
probe "step-net P4 cp last-arg"      'cp /tmp/x /workspace/step-network/dst'                       BLOCK
probe "step-net P5 cp -t"            'cp -t /workspace/step-network/ /tmp/src'                     BLOCK
probe "step-net P6 cp --target-dir"  'cp --target-directory=/workspace/step-network/ /tmp/src'     BLOCK
probe "step-net P7 patch"            'patch /workspace/step-network/foo < fix.patch'               BLOCK
probe "step-net P8 perl -i"          'perl -i -pe "s/x/y/" /workspace/step-network/file.ts'       BLOCK
probe "step-net P9 tar -C"           'tar -xf archive.tar -C /workspace/step-network/'            BLOCK

# ------------------------------------------------------------------
# SLUG: a1 (minimal valid slug — single char + digit, validates [a-z0-9] first-char)
# ------------------------------------------------------------------
echo ""
echo "=== BLOCK: slug=a1 (must BLOCK for non-CTO) ==="
probe "a1 P1 redirect"               'echo x > /workspace/a1/README.md'                            BLOCK
probe "a1 P2 sed -i"                 'sed -i "s/x/y/" /workspace/a1/src/app.ts'                    BLOCK
probe "a1 P3 tee"                    'tee /workspace/a1/log.md'                                    BLOCK
probe "a1 P4 cp last-arg"            'cp /tmp/x /workspace/a1/dst'                                 BLOCK
probe "a1 P5 cp -t"                  'cp -t /workspace/a1/ /tmp/src'                               BLOCK
probe "a1 P6 cp --target-dir"        'cp --target-directory=/workspace/a1/ /tmp/src'               BLOCK
probe "a1 P7 patch"                  'patch /workspace/a1/foo < fix.patch'                         BLOCK
probe "a1 P8 perl -i"                'perl -i -pe "s/x/y/" /workspace/a1/file.ts'                 BLOCK
probe "a1 P9 tar -C"                 'tar -xf archive.tar -C /workspace/a1/'                      BLOCK

# ------------------------------------------------------------------
# ALLOW probes — false-positive guards
# ------------------------------------------------------------------
echo ""
echo "=== ALLOW: slug-guard rejection (must NOT block — invalid slugs) ==="
# UPPER: uppercase slug — fails [a-z0-9] first-char test → no match
probe "FP1 UPPER slug redirect"      'echo x > /workspace/PROD/README.md'                          ALLOW
# Leading hyphen: fails [a-z0-9] first-char test → no match
probe "FP2 leading-hyphen slug"      'echo x > /workspace/-bad/README.md'                          ALLOW
# Dot prefix: not matched by [a-z0-9] → no match
probe "FP3 dot-prefix slug"          'echo x > /workspace/.hidden/README.md'                       ALLOW
# Space in path: does not form valid slug path → no match
probe "FP4 space-in-slug"            'echo x > "/workspace/foo bar/README.md"'                     ALLOW

echo ""
echo "=== ALLOW: legitimate read ops on pool slugs (must NOT block) ==="
# cat is a read — no write-target in product path → ALLOW
probe "FP5 cat sensed read"          'cat /workspace/sensed/src/app.ts'                             ALLOW
# grep is read-only → ALLOW
probe "FP6 grep sensed read"         'grep "foo" /workspace/sensed/src/app.ts'                     ALLOW
# cd + ls: no write op → ALLOW
probe "FP7 cd sensed + ls"           'cd /workspace/sensed && ls'                                  ALLOW
# tee writing to /tmp, reading from sensed → ALLOW
probe "FP8 cat sensed | tee /tmp"    'cat /workspace/sensed/x | tee /tmp/y'                        ALLOW
# cp reading FROM sensed, writing to /tmp → ALLOW
probe "FP9 cp sensed -> /tmp"        'cp /workspace/sensed/x /tmp/y'                               ALLOW
# git log in sensed: read-only git op → ALLOW
probe "FP10 git log sensed"          'git -C /workspace/sensed log --oneline'                      ALLOW
# rsync reading FROM sensed to /tmp → ALLOW (rsync -t = --times, not --target)
probe "FP11 rsync sensed -> /tmp"    'rsync -rt /workspace/sensed/ /tmp/dst'                       ALLOW

# CTO bypass: same command that would block non-CTO must pass for CTO
# (tested inline with OFFICER_NAME=cto)
echo ""
echo "=== ALLOW: CTO bypass on pool slugs (CTO must not be blocked) ==="
cto_result=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo x > /workspace/sensed/README.md"}}' | CABINET_HOOK_TEST_MODE=1 OFFICER_NAME=cto bash "$HOOK" 2>/dev/null; echo "EXIT:$?")
cto_exit="${cto_result##*EXIT:}"
if [ "$cto_exit" = "0" ]; then
  verdict="PASS"; PASS=$((PASS+1))
else
  verdict="FAIL"; FAIL=$((FAIL+1))
fi
printf "%-6s | %-56s | exit=%s\n" "$verdict" "FP12 CTO bypass sensed redirect" "$cto_exit"

echo ""
echo "=== Summary: PASS=$PASS  FAIL=$FAIL ==="
exit $FAIL
