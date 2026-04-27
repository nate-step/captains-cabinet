#!/bin/bash
# FW-057 regression harness: notify-officer.sh argv keyword pass-through.
#
# FW-057 was filed 2026-04-25 reporting that command-name tokens (chown, sudo,
# docker, etc.) inside notify-officer.sh's quoted body argv triggered
# pre-tool-use.sh's BLOCKED: System-level command not permitted gate. Survey
# 2026-04-27 found the issue had been incidentally fixed by FW-042 v3.7.1's
# CMD_STRIPPED preprocessing — quoted spans are stripped before the keyword
# scanner runs, so data-position keywords pass through.
#
# This harness PINS that behavior as a regression guard. If a future change to
# CMD_STRIPPED or the system-command block re-introduces the over-block, these
# probes catch it before officers hit it in production.
#
# Coverage:
#   ALLOW: notify-officer.sh / send-to-group.sh / record-experience.sh argv
#          containing sudo, docker, systemctl, chown, chmod, chgrp, usermod,
#          shutdown, reboot, halt, git push — single + double quotes,
#          absolute + relative paths.
#   BLOCK: actual cmd-position sudo / docker / systemctl invocations remain
#          gated (regression guard for non-whitelist case).
#   ALLOW: same keywords inside other quoted-body shapes (echo, grep) — proves
#          the data-position pass-through is the general FW-042 v3.7.1
#          contract, not a notify-officer-specific carve-out.

HOOK=/opt/founders-cabinet/cabinet/scripts/hooks/pre-tool-use.sh
PASS=0
FAIL=0

probe() {
  local label="$1" cmd="$2" expected="$3"
  local result exit_code verdict
  result=$(echo "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$cmd" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}}" \
    | CABINET_HOOK_TEST_MODE=1 OFFICER_NAME=cos bash "$HOOK" 2>/dev/null
    echo "EXIT:$?")
  exit_code="${result##*EXIT:}"
  if [ "$expected" = "BLOCK" ]; then
    if [ "$exit_code" = "2" ]; then verdict="PASS"; PASS=$((PASS+1)); else verdict="FAIL"; FAIL=$((FAIL+1)); fi
  else
    if [ "$exit_code" = "0" ]; then verdict="PASS"; PASS=$((PASS+1)); else verdict="FAIL"; FAIL=$((FAIL+1)); fi
  fi
  printf "%-6s | %-58s | exit=%s\n" "$verdict" "$label" "$exit_code"
}

echo "=== ALLOW: notify-officer.sh argv with system-command keywords ==="
probe "notify abs sudo (double-quote)"       'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "please run sudo apt update"' ALLOW
probe "notify abs sudo (single-quote)"       "bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos 'please run sudo apt update'" ALLOW
probe "notify abs docker (double-quote)"     'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "docker ps shows hung container"' ALLOW
probe "notify abs systemctl (double-quote)"  'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "systemctl restart redis"' ALLOW
probe "notify abs chown (double-quote)"      'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "fix the chown bug"' ALLOW
probe "notify abs chmod (double-quote)"      'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "chmod +x the script"' ALLOW
probe "notify abs chgrp (double-quote)"      'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "chgrp on tier2 dir"' ALLOW
probe "notify abs usermod (double-quote)"    'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "usermod the cabinet user"' ALLOW
probe "notify abs shutdown (double-quote)"   'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "shutdown the planner cleanly"' ALLOW
probe "notify abs reboot (double-quote)"     'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "reboot to apply kernel"' ALLOW
probe "notify abs halt (double-quote)"       'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "halt the spending overrun"' ALLOW
probe "notify abs git push (double-quote)"   'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "git push needed on branch X"' ALLOW
probe "notify abs multi-keyword body"        'bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cos "sudo chmod chown chgrp usermod"' ALLOW
probe "notify rel path sudo body"            'bash cabinet/scripts/notify-officer.sh cos "need sudo to fix"' ALLOW
probe "notify rel-dot path docker body"      'bash ./cabinet/scripts/notify-officer.sh cos "docker compose down might fix it"' ALLOW

echo ""
echo "=== ALLOW: send-to-group.sh + record-experience.sh argv with keywords ==="
probe "group docker body"                    'bash /opt/founders-cabinet/cabinet/scripts/send-to-group.sh "docker rebuilt + redeployed"' ALLOW
probe "group sudo body"                      'bash /opt/founders-cabinet/cabinet/scripts/send-to-group.sh "sudo apt install required"' ALLOW
probe "experience chown body"                'bash /opt/founders-cabinet/cabinet/scripts/record-experience.sh "Used chown to fix tier2 perms"' ALLOW

echo ""
echo "=== ALLOW: data-position keywords in echo / grep / printf bodies ==="
probe "echo sudo (data-position)"            'echo "we need sudo for this fix"' ALLOW
probe "echo docker (single-quote)"           "echo 'docker ps output'" ALLOW
probe "grep sudo against file"               'grep -E "sudo" /tmp/log.txt' ALLOW
probe "printf chown body"                    'printf "%s\n" "the chown call ran"' ALLOW

echo ""
echo "=== BLOCK: actual cmd-position invocations (regression guard) ==="
probe "raw sudo cmd"                         'sudo apt update'                                   BLOCK
probe "raw docker cmd"                       'docker ps'                                         BLOCK
probe "raw systemctl cmd"                    'systemctl restart redis'                           BLOCK
probe "raw shutdown cmd"                     'shutdown -h now'                                   BLOCK
probe "sudo after semicolon"                 'echo hi; sudo apt update'                          BLOCK
probe "docker after &&"                      'true && docker ps'                                 BLOCK
probe "sudo via env preamble"                'PATH=/bin sudo apt update'                         BLOCK
probe "sudo at script start (no quotes)"     'bash -c "sudo apt update"'                         BLOCK

echo ""
echo "=== Summary ==="
TOTAL=$((PASS+FAIL))
printf "PASS: %d / %d\n" "$PASS" "$TOTAL"
[ "$FAIL" -eq 0 ] && echo "OK" || { echo "FAIL"; exit 1; }
