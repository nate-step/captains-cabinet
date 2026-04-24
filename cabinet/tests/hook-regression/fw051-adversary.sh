#!/bin/bash
HOOK=/opt/founders-cabinet/cabinet/scripts/hooks/pre-tool-use.sh
probe() {
  local label="$1"; local cmd="$2"; local expect="$3"
  local json=$(jq -cn --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}')
  # Both Layer 1 keys: reviewed gates Section 6 (refs/heads/main class),
  # ci-green gates Section 7 (pulls/N/merge). ADV-4 + COO-E10 hit Section 7 —
  # leaked ci-green from an operator push (EX 300) silently consumes the key
  # and returns exit=0 → false FAIL(bypass). DEL both to keep harness hermetic.
  redis-cli -h redis -p 6379 DEL cabinet:layer1:cto:reviewed cabinet:layer1:cto:ci-green >/dev/null 2>&1
  CABINET_HOOK_TEST_MODE=1 OFFICER_NAME=cto bash "$HOOK" <<<"$json" >/dev/null 2>&1
  local ec=$?
  local result="?"
  if [ "$expect" = "BLOCK" ]; then [ "$ec" = "2" ] && result="PASS" || result="FAIL(bypass)"
  elif [ "$expect" = "PASS" ]; then [ "$ec" = "0" ] && result="PASS" || result="FAIL(FP)"; fi
  printf "  [exit=%d %s] %-32s %s\n" "$ec" "$result" "$label" "$cmd"
}
echo "=== FW-051 Sonnet Pass A Adversary findings — MUST BLOCK ==="
probe "ADV-1 env-path-prefix"     '/usr/bin/env bash -c "git push origin main"' BLOCK
probe "ADV-2 backtick-splice-gh"  '`gh` api -X DELETE refs/heads/main' BLOCK
probe "ADV-3 env-short-path"      '/bin/env bash -c "gh api -X DELETE refs/heads/main"' BLOCK
probe "ADV-4 backtick-S7"         '`gh` api pulls/42/merge' BLOCK
probe "ADV-5 env-plain"           'env bash -c "git push origin main"' BLOCK

echo ""
echo "=== Regression guards for new prongs — MUST PASS ==="
probe "ADV-R1 echo-env-path"      'echo "/usr/bin/env bash -c pushing"' PASS
probe "ADV-R2 echo-backtick"      'echo "using \`gh\` api"' PASS
probe "ADV-R3 grep-env"           'grep "/usr/bin/env bash" script.sh' PASS

echo ""
# COO Pass-1 adversary (2026-04-24, SHIP-CLEAN verdict on 9368f46).
# 60-probe pass surfaced 1 LOW finding (AC-15 E3 DQ-wrapped backtick,
# V1 inert + V2-V9 AC-3 subclass, deferred to FW-040 Phase B).
# The other 9 novel adversary probes all block correctly — promoted here
# as permanent regression guards. E3 itself is skipped (deferred class).
echo "=== COO Pass-1 novel adversary — MUST BLOCK ==="
probe "COO-E1 multi-splice"       '"gh" ap"i" -X DELETE repos/a/b/git/refs/heads/main' BLOCK
probe "COO-E2 nested-backticks"   '``gh`` api -X DELETE repos/a/b/git/refs/heads/main' BLOCK
probe "COO-E4 backtick-empty-DQ"  '`g""h` api -X DELETE repos/a/b/git/refs/heads/main' BLOCK
probe "COO-E5 mixed-sep-refs"     'gh api -X DELETE repos/a/b/git/refs/heads%2Fmain' BLOCK
probe "COO-E6 path-parent-env"    '../../bin/env bash -c "git push origin main"' BLOCK
probe "COO-E7 path-relative-env"  './env bash -c "git push origin main"' BLOCK
probe "COO-E8 fused-cap-Ec"       "bash -Ec 'gh api -X DELETE repos/a/b/git/refs/heads/main'" BLOCK
probe "COO-E9 fused-xvc"          "bash -xvc 'gh api -X DELETE repos/a/b/git/refs/heads/main'" BLOCK
probe "COO-E10 S7-pulls-merge"    'gh api -X PATCH repos/a/b/pulls/42/merge' BLOCK

echo ""
echo "=== COO Pass-1 preprocessing FP guards — MUST PASS ==="
probe "COO-F1 commit-empty-msg"   "git commit -m ''" PASS
probe "COO-F2 grep-empty-pattern" "grep '' /tmp/file" PASS
probe "COO-F3 config-empty-dq"    'git config user.email ""' PASS
probe "COO-F4 echo-backtick-user" 'echo "current user: `whoami`"' PASS
probe "COO-F5 notify-backtick"    'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cpo "ci output: `date`"' PASS

echo ""
# FW-038 wrapper forms — regression guards for coverage shipped in FW-045/FW-041/
# FW-043/FW-051 chain. The original FW-038 entry named these as "fail-OPEN for
# Layer 1 + CI Green"; all 9 empirically BLOCK today (2026-04-24 CTO verified).
# Pin them here so a future hook edit can't silently regress the close.
echo "=== FW-038 wrapper-class forms — MUST BLOCK (regression guard) ==="
probe "FW038-W1 nohup-L1"         'nohup git push origin main' BLOCK
probe "FW038-W2 exec-L1"          'exec git push origin main' BLOCK
probe "FW038-W3 stdbuf-L1"        'stdbuf -oL git push origin main' BLOCK
probe "FW038-W4 nohup-S7-pulls"   'nohup gh api pulls/42/merge' BLOCK
probe "FW038-W5 exec-S7-pulls"    'exec gh api pulls/42/merge' BLOCK
probe "FW038-W6 nohup-XDELETE"    'nohup gh api -X DELETE repos/O/R/git/refs/heads/main' BLOCK
probe "FW038-W7 subshell-L1"      '(git push origin main)' BLOCK
probe "FW038-W8 brace-L1"         '{ git push origin main; }' BLOCK
probe "FW038-W9 pipe-first-L1"    'true | git push origin main' BLOCK
