#!/bin/bash
# FW-042 v3.7 adversary-finding validation harness.
# Validates fixes for 13 unique bug classes from v3.6 dual adversary pass:
#   BUG-01 — WRAPPER missing setsid/nice/doas/pkexec/strace (20+ wrappers)
#   BUG-05 — timeout with duration/flag-value args (30s, -k 5s 30s)
#   BUG-09/H2 — WRAPPER value absorber too restrictive ([/A-Z])
#   BUG-10 — SHELL_C short-flag no arg-slot (-O OPT -c)
#   BUG-11/H10 — SHELL_C trailing quote required (bash -c sudo unquoted)
#   BUG-12 — PATH_PREFIX tilde ~/bin/sudo
#   BUG-13/H5 — PATH_PREFIX // double-slash
#   BUG-15/H3 — nested brace {,{,sudo}}
#   H1/H6 — long-flag =VALUE (--rcfile=X)
#   H4 — {kw,X} non-empty alt brace (kw first)
#   H7 — RM_FLEX bare --
#   H8 — CMD_PREAMBLE reserved words (if|while|until|for|case|select|function)
#   H9 — EVAL_WRAPPER inner wrapper list (eval 'command sudo')
#   H11 — rm -rf "/" quote-strip removes target
#   H12 — brace+path {,/bin/sudo}
#   EVAL-compound — eval 'echo ok; sudo ls' (compound-statement before kw)
#   ENV-S — env -S'sudo ls' (glued short-flag-quote)
set -u
HOOK="${HOOK_OVERRIDE:-/opt/founders-cabinet/cabinet/scripts/hooks/pre-tool-use.sh}"
PASS=0; FAIL=0

redis-cli -h redis -p 6379 DEL "cabinet:killswitch" >/dev/null 2>&1

run() {
  local label="$1" expected="$2" cmd="$3"
  local json ec
  json=$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')
  echo "$json" | OFFICER_NAME=cto bash "$HOOK" >/dev/null 2>&1
  ec=$?
  if [ "$ec" = "$expected" ]; then
    printf "  [PASS] %s: exit=%d\n" "$label" "$ec"
    PASS=$((PASS + 1))
  else
    printf "  [FAIL] %s: exit=%d (expected %d)\n" "$label" "$ec" "$expected"
    printf "         cmd: %s\n" "$cmd"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== BUG-01: WRAPPER wrapper list extension ==="
run "setsid sudo"         2 "setsid sudo ls"
run "nice -n 10 sudo"     2 "nice -n 10 sudo ls"
run "ionice -c2 sudo"     2 "ionice -c2 sudo ls"
run "doas sudo"           2 "doas sudo ls"
run "pkexec sudo"         2 "pkexec sudo ls"
run "strace sudo"         2 "strace sudo ls"
run "ltrace sudo"         2 "ltrace sudo ls"
run "watch sudo"          2 "watch sudo ls"
run "chroot / sudo"       2 "chroot / sudo ls"
run "unbuffer sudo"       2 "unbuffer sudo ls"
run "stdbuf -oL sudo"     2 "stdbuf -oL sudo ls"
run "taskset 0x1 sudo"    2 "taskset 0x1 sudo ls"
run "numactl --phys sudo" 2 "numactl --physcpubind=0 sudo ls"
echo ""

echo "=== BUG-05: timeout duration/flag-value absorber ==="
run "timeout 30s sudo"    2 "timeout 30s sudo ls"
run "timeout -k 5s 30s"   2 "timeout -k 5s 30s sudo ls"
run "timeout 1m reboot"   2 "timeout 1m reboot"
run "timeout -s KILL 1h"  2 "timeout -s KILL 1h sudo ls"
run "timeout --kill-after=5 1m" 2 "timeout --kill-after=5 1m sudo ls"
echo ""

echo "=== BUG-11/H10: SHELL_C trailing quote optional ==="
run "bash -c sudo ls"     2 "bash -c sudo ls"
run "sh -c reboot"        2 "sh -c reboot"
run "zsh -c docker"       2 "zsh -c docker ps"
run "bash -c 'sudo ls'"   2 "bash -c 'sudo ls'"
run "bash -cx sudo"       2 "bash -cx sudo ls"
echo ""

echo "=== BUG-12: PATH_PREFIX tilde ==="
run "~/bin/sudo"          2 "~/bin/sudo ls"
run "~foo/sbin/reboot"    2 "~foo/sbin/reboot"
run "~/tools/docker"      2 "~/tools/docker ps"
echo ""

echo "=== BUG-13/H5: PATH_PREFIX // double-slash ==="
run "//usr/bin/sudo"      2 "//usr/bin/sudo ls"
run "//sbin/reboot"       2 "//sbin/reboot"
run "///bin/sudo"         2 "///bin/sudo ls"
echo ""

echo "=== BUG-15/H3: nested brace {,{,kw}} ==="
run "{,{,sudo}} ls"       2 "{,{,sudo}} ls"
run "{,{,docker}} ps"     2 "{,{,docker}} ps"
run "{,{,reboot}}"        2 "{,{,reboot}}"
run "{,{,{,sudo}}} ls"    2 "{,{,{,sudo}}} ls"
echo ""

echo "=== H1/H6: long-flag =VALUE ==="
run "bash --rcfile=F -c"  2 "bash --rcfile=/tmp/x -c 'sudo ls'"
run "bash --init-file=F"  2 "bash --init-file=/tmp/x -c 'sudo ls'"
run "rm --interactive=never" 2 "rm --interactive=never -rf /"
run "rm --one-file-system=1" 2 "rm --one-file-system=true -rf /"
echo ""

echo "=== H4: {kw,X} non-empty alt brace (kw first) ==="
run "{rm,X} -rf /"        2 "{rm,X} -rf /"
run "{sudo,X} ls"         2 "{sudo,X} ls"
run "{docker,Y} ps"       2 "{docker,Y} ps"
run "{reboot,X}"          2 "{reboot,X}"
run "{rm,A,B} -rf /"      2 "{rm,A,B} -rf /"
echo ""

echo "=== H7: RM_FLEX bare -- ==="
run "rm -rf -- /"         2 "rm -rf -- /"
run "rm -fr -- /"         2 "rm -fr -- /"
run "rm --recursive -- /" 2 "rm --recursive -- /"
echo ""

echo "=== H8: reserved words (if|while|until|for|case) ==="
run "if sudo; then"       2 "if sudo ls; then :; fi"
run "while sudo; do"      2 "while sudo ls; do :; done"
run "until reboot; do"    2 "until reboot; do :; done"
run "for x in; do sudo"   2 "for x in 1; do sudo ls; done"
echo ""

echo "=== H9: EVAL_WRAPPER inner list (command/setsid/timeout inside eval) ==="
run "eval 'command sudo'" 2 "eval 'command sudo ls'"
run "eval 'setsid sudo'"  2 "eval 'setsid sudo ls'"
run "eval 'timeout 30s docker'" 2 "eval 'timeout 30s docker ps'"
run "eval 'doas reboot'"  2 "eval 'doas reboot'"
echo ""

echo "=== H11: rm -rf \"/\" quote-strip ==="
run "rm -rf \"/\""        2 'rm -rf "/"'
run "rm -rf '/'"          2 "rm -rf '/'"
run "rm -fr \"/\""        2 'rm -fr "/"'
echo ""

echo "=== H12: brace+path {,/bin/sudo} ==="
run "{,/bin/sudo} ls"     2 "{,/bin/sudo} ls"
run "{,/usr/bin/docker}"  2 "{,/usr/bin/docker} ps"
run "{,/sbin/reboot}"     2 "{,/sbin/reboot}"
echo ""

echo "=== EVAL-compound: eval '...; kw' ==="
run "eval 'echo; sudo'"   2 "eval 'echo ok; sudo ls'"
run "eval 'ls && docker'" 2 "eval 'ls && docker ps'"
run "eval 'true | reboot'" 2 "eval 'true | reboot'"
echo ""

echo "=== ENV-S: env -S'kw ls' ==="
run "env -S'sudo ls'"     2 "env -S'sudo ls'"
run "env -S\"docker ps\"" 2 'env -S"docker ps"'
run "env VAR=1 -S'sudo'"  2 "env VAR=1 -S'sudo ls'"
echo ""

echo "=== FP controls v3.7 ==="
run "echo setsid running" 0 "echo setsid running now"
run "grep doas file"      0 "grep doas /etc/sudoers"
run "which //usr/bin/sudo" 0 "which //usr/bin/sudo"
run "echo ~/bin/sudo"     0 "echo ~/bin/sudo"
run "ls //usr/bin/sudo"   0 "ls //usr/bin/sudo"
run "echo {,docker}-comp" 0 "echo {,docker}-compose.yml"
run "echo {,{,docker}}"   0 "echo {,{,docker}}-comp"
run "grep -E timeout"     0 "grep -E 'timeout' /tmp/log"
run "timeout --help"      0 "timeout --help"
run "nice --help"         0 "nice --help"
run "env --help"          0 "env --help"
run "echo 'env -S hi'"    0 "echo 'env -S hi'"
run "bash -c 'echo hi'"   0 "bash -c 'echo hi'"
run "if true; then echo"  0 "if true; then echo hi; fi"
run "while true; do echo" 0 "while true; do echo hi; done"
run "rm file.txt"         0 "rm file.txt"
run "rm -rf /tmp/build"   0 "rm -rf /tmp/build"
run "rm -fr ./build"      0 "rm -fr ./build"
run "echo 'rm -rf \"/\"'"  0 "echo 'rm -rf \"/\"'"
run "eval 'echo hi'"      0 "eval 'echo hi'"
run "eval 'echo; ls'"     0 "eval 'echo hi; ls'"
echo ""

echo "=== SUMMARY ==="
printf "PASS: %d · FAIL: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
