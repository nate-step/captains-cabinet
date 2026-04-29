#!/bin/bash
# test-create-project.sh — Unit tests for create-project.sh (FW-078)
#
# Tests slug validation, URL validation, DRY_RUN mode, idempotency,
# failure recovery (state file persistence), and output file shape.
#
# Run: bash /opt/founders-cabinet/cabinet/scripts/test-create-project.sh
# Exit 0 on all PASS, 1 on any FAIL.
#
# Uses /tmp/test-cp-<timestamp> for filesystem isolation.
# Cleans up on EXIT.

set -uo pipefail

CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"
SCRIPT="$CABINET_ROOT/cabinet/scripts/test-create-project.sh"
# Resolve the script being tested — works whether run from main or worktree
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREATE_SCRIPT="$SCRIPT_DIR/create-project.sh"
TS=$(date +%s)
WORK_DIR="/tmp/test-cp-${TS}"

PASS=0
FAIL=0
FAILURES=()

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------
assert() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: expected='$expected' actual='$actual'")
    printf "  [FAIL] %s: expected='%s' actual='%s'\n" "$label" "$expected" "$actual"
  fi
}

assert_contains() {
  local label="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: '$needle' not found in output")
    printf "  [FAIL] %s: '%s' not in output\n" "$label" "$needle"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [ -f "$path" ]; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: file not found: $path")
    printf "  [FAIL] %s: file not found: %s\n" "$label" "$path"
  fi
}

assert_file_not_exists() {
  local label="$1" path="$2"
  if [ ! -f "$path" ]; then
    PASS=$((PASS+1))
    printf "  [PASS] %s\n" "$label"
  else
    FAIL=$((FAIL+1))
    FAILURES+=("$label: file should not exist: $path")
    printf "  [FAIL] %s: file should not exist: %s\n" "$label" "$path"
  fi
}

# Run a command and capture both output and exit code without `|| true` masking.
# Sets RUN_OUTPUT and RUN_EXIT.
run_capture() {
  RUN_OUTPUT=$("$@" 2>&1) && RUN_EXIT=0 || RUN_EXIT=$?
}

# ---------------------------------------------------------------------------
# Cleanup on exit
# ---------------------------------------------------------------------------
cleanup() {
  rm -rf "$WORK_DIR"
  rm -f /tmp/create-project.test-*.state
  rm -f /tmp/create-project.idem-*.state
  rm -f /tmp/create-project.fail-*.state
  rm -f /tmp/create-project.yaml-*.state
  rm -f /tmp/create-project.envt-*.state
}
trap cleanup EXIT

mkdir -p "$WORK_DIR"

# ---------------------------------------------------------------------------
# Sandbox factory — isolated CABINET_ROOT per test
# ---------------------------------------------------------------------------
setup_sandbox() {
  local slug="$1"
  local sandbox="$WORK_DIR/${slug}"
  mkdir -p "$sandbox/instance/config/projects"
  mkdir -p "$sandbox/cabinet/env"
  mkdir -p "$sandbox/cabinet/scripts"
  mkdir -p "$sandbox/cabinet/scripts/lib"

  # Minimal _template.yml
  cat > "$sandbox/instance/config/projects/_template.yml" <<'EOF'
product:
  name: ""
  description: ""
  repo: ""
  repo_branch: main
  mount_path: /workspace/product

notion:
  cabinet_hq_id: ""

linear:
  team_key: ""
  workspace_url: ""

neon:
  project: ""

telegram:
  officers:
    cos: ""
    cto: ""
EOF

  # Minimal _template.env
  cat > "$sandbox/cabinet/env/_template.env" <<'EOF'
TELEGRAM_HQ_CHAT_ID=
NEON_CONNECTION_STRING=
PRODUCT_REPO_PATH=/opt/<project-name>
CABINET_PREFIX=<project-slug>
EOF

  # Minimal .env (required by preflight)
  cat > "$sandbox/cabinet/.env" <<'EOF'
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
EOF

  # Stub notify-officer.sh
  cat > "$sandbox/cabinet/scripts/notify-officer.sh" <<'EOF'
#!/bin/bash
echo "[stub notify] $*"
EOF
  chmod +x "$sandbox/cabinet/scripts/notify-officer.sh"

  # Stub triggers.sh (required by notify-officer.sh)
  cat > "$sandbox/cabinet/scripts/lib/triggers.sh" <<'EOF'
trigger_send() { echo "[stub trigger_send] $*"; }
EOF

  echo "$sandbox"
}

# ---------------------------------------------------------------------------
# T1 — Bad slug (charset): uppercase/special chars rejected
# ---------------------------------------------------------------------------
echo ""
echo "=== T1: Bad slug (uppercase/special chars) rejected ==="
run_capture bash "$CREATE_SCRIPT" "Bad-Slug!" "https://github.com/org/repo"
assert "T1: uppercase slug exits non-zero" "$RUN_EXIT" "1"
assert_contains "T1: error message mentions slug constraint" "$RUN_OUTPUT" "slug must match"

# ---------------------------------------------------------------------------
# T2 — 33-char slug rejected (length cap)
# ---------------------------------------------------------------------------
echo ""
echo "=== T2: 33-char slug rejected ==="
LONG_SLUG="a$(printf 'b%.0s' {1..32})"  # 33 chars
run_capture bash "$CREATE_SCRIPT" "$LONG_SLUG" "https://github.com/org/repo"
assert "T2: long slug exits non-zero" "$RUN_EXIT" "1"
assert_contains "T2: error message mentions length" "$RUN_OUTPUT" "≤32 chars"

# ---------------------------------------------------------------------------
# T3 — Missing repo_url rejected
# ---------------------------------------------------------------------------
echo ""
echo "=== T3: Missing repo_url rejected ==="
run_capture bash "$CREATE_SCRIPT" "my-slug"
assert "T3: missing repo_url exits non-zero" "$RUN_EXIT" "1"

# ---------------------------------------------------------------------------
# T4 — DRY_RUN=1 prints steps without filesystem changes
# ---------------------------------------------------------------------------
echo ""
echo "=== T4: DRY_RUN=1 prints steps without creating files ==="
SANDBOX=$(setup_sandbox "dry-test")
run_capture env CABINET_ROOT="$SANDBOX" DRY_RUN=1 GITHUB_PAT="test-pat" \
  bash "$CREATE_SCRIPT" "my-new-proj" "https://github.com/org/repo" \
  --skip-notion --skip-linear --skip-library

assert_contains "T4: dry-run prints DRY RUN label"        "$RUN_OUTPUT" "DRY RUN"
assert_contains "T4: dry-run mentions project yml"         "$RUN_OUTPUT" "instance/config/projects"
assert_contains "T4: dry-run mentions env file"            "$RUN_OUTPUT" "cabinet/env"
assert_contains "T4: dry-run mentions clone"               "$RUN_OUTPUT" "clone"
assert_file_not_exists "T4: no project yml created in dry-run" \
  "$SANDBOX/instance/config/projects/my-new-proj.yml"
assert_file_not_exists "T4: no env file created in dry-run" \
  "$SANDBOX/cabinet/env/my-new-proj.env"

# ---------------------------------------------------------------------------
# T5 — Idempotent: re-run skips completed steps
# ---------------------------------------------------------------------------
echo ""
echo "=== T5: Idempotent — running twice skips completed steps ==="
SANDBOX=$(setup_sandbox "idempotent-test")
IDEM_SLUG="idem-$(echo "$TS" | cut -c7-)"
IDEM_SLUG="${IDEM_SLUG:0:32}"

# Pre-create project yml and env file to simulate first run already having run
cat > "$SANDBOX/instance/config/projects/${IDEM_SLUG}.yml" <<'EOF'
product:
  name: "Idem Test"
  repo: "https://github.com/org/test"
EOF
cat > "$SANDBOX/cabinet/env/${IDEM_SLUG}.env" <<'EOF'
CABINET_PREFIX=idem-test
EOF

# Write state file with all steps already done (dead PID so lock re-use works)
STATE_I="/tmp/create-project.${IDEM_SLUG}.state"
{
  echo "PID=99999"
  echo "preflight"
  echo "project-yml"
  echo "env-file"
  echo "clone-repo"
  echo "mount-path"
  echo "notion"
  echo "linear"
  echo "library"
  echo "notify-cos"
} > "$STATE_I"

run_capture env CABINET_ROOT="$SANDBOX" GITHUB_PAT="test-pat" \
  bash "$CREATE_SCRIPT" "$IDEM_SLUG" "https://github.com/org/test" \
  --skip-notion --skip-linear --skip-library

assert_contains "T5: second run finds steps already done" "$RUN_OUTPUT" "already completed"
assert_file_not_exists "T5: state file cleaned up after full completion" "$STATE_I"

# ---------------------------------------------------------------------------
# T6 — Failure mid-way leaves state file
# ---------------------------------------------------------------------------
echo ""
echo "=== T6: Failure mid-way leaves state file ==="
SANDBOX=$(setup_sandbox "fail-test")
FAIL_SLUG="fail-$(echo "$TS" | cut -c7-)"
FAIL_SLUG="${FAIL_SLUG:0:32}"
FAIL_STATE="/tmp/create-project.${FAIL_SLUG}.state"
rm -f "$FAIL_STATE"

# Pre-seed state through env-file step so script proceeds to clone step
{
  echo "PID=99999"
  echo "preflight"
  echo "project-yml"
  echo "env-file"
} > "$FAIL_STATE"

# Pre-create the yml + env files to match seeded steps
cat > "$SANDBOX/instance/config/projects/${FAIL_SLUG}.yml" <<'EOF'
product:
  name: "Fail Test"
  repo: "https://invalid.example.invalid/no/repo.git"
EOF
cat > "$SANDBOX/cabinet/env/${FAIL_SLUG}.env" <<'EOF'
CABINET_PREFIX=fail-test
EOF

# Clone will fail — invalid host, suppress git prompts
run_capture env CABINET_ROOT="$SANDBOX" GITHUB_PAT="test-pat" GIT_TERMINAL_PROMPT=0 \
  bash "$CREATE_SCRIPT" "$FAIL_SLUG" "https://invalid.example.invalid/no/repo.git" \
  --skip-notion --skip-linear --skip-library

assert "T6: failed run exits non-zero" "$RUN_EXIT" "1"
assert_file_exists "T6: state file persists after failure" "$FAIL_STATE"
assert_contains "T6: state file has project-yml recorded" \
  "$(cat "$FAIL_STATE" 2>/dev/null)" "project-yml"

rm -f "$FAIL_STATE"

# ---------------------------------------------------------------------------
# T7 — Output yml is structurally valid YAML with correct content
# ---------------------------------------------------------------------------
echo ""
echo "=== T7: instance/config/projects/<slug>.yml is valid YAML ==="
SANDBOX=$(setup_sandbox "yaml-test")
YAML_SLUG="yaml-$(echo "$TS" | cut -c7-)"
YAML_SLUG="${YAML_SLUG:0:32}"

# Pre-seed preflight as done; let project-yml step run, then fail at clone
STATE_Y="/tmp/create-project.${YAML_SLUG}.state"
{
  echo "PID=99999"
  echo "preflight"
} > "$STATE_Y"

run_capture env CABINET_ROOT="$SANDBOX" GITHUB_PAT="test-pat" GIT_TERMINAL_PROMPT=0 \
  bash "$CREATE_SCRIPT" "$YAML_SLUG" "https://invalid.example.invalid/no/repo.git" \
  --skip-notion --skip-linear --skip-library

rm -f "$STATE_Y"
yml_path="$SANDBOX/instance/config/projects/${YAML_SLUG}.yml"
if [ -f "$yml_path" ]; then
  # Structural YAML validity: no leading tabs (YAML forbids them),
  # product: section present. Avoids pyyaml dependency.
  has_tabs=$(grep -P '^\t' "$yml_path" 2>/dev/null && echo "YES" || echo "NO")
  has_product=$(grep -q '^product:' "$yml_path" 2>/dev/null && echo "YES" || echo "NO")
  assert "T7: yml has no leading tabs (YAML valid)"    "$has_tabs"      "NO"
  assert "T7: yml has product: section"                "$has_product"   "YES"
  assert_contains "T7: yml has correct mount_path"     "$(cat "$yml_path")" "/workspace/${YAML_SLUG}"
  assert_contains "T7: yml has repo URL"               "$(cat "$yml_path")" "invalid.example.invalid"
else
  FAIL=$((FAIL+1))
  FAILURES+=("T7: yml file not created at $yml_path")
  printf "  [FAIL] T7: yml file not created at %s\n" "$yml_path"
fi

# ---------------------------------------------------------------------------
# T8 — cabinet/env/<slug>.env has expected fields
# ---------------------------------------------------------------------------
echo ""
echo "=== T8: cabinet/env/<slug>.env has expected fields ==="
SANDBOX=$(setup_sandbox "env-test")
ENV_SLUG="envt-$(echo "$TS" | cut -c7-)"
ENV_SLUG="${ENV_SLUG:0:32}"

STATE_E="/tmp/create-project.${ENV_SLUG}.state"
{
  echo "PID=99999"
  echo "preflight"
  echo "project-yml"
} > "$STATE_E"

# Pre-create yml to match seeded steps
cat > "$SANDBOX/instance/config/projects/${ENV_SLUG}.yml" <<'EOF'
product:
  name: "Env Test"
  repo: "https://invalid.example.invalid/no/repo.git"
EOF

run_capture env CABINET_ROOT="$SANDBOX" GITHUB_PAT="test-pat" GIT_TERMINAL_PROMPT=0 \
  bash "$CREATE_SCRIPT" "$ENV_SLUG" "https://invalid.example.invalid/no/repo.git" \
  --skip-notion --skip-linear --skip-library

rm -f "$STATE_E"
env_path="$SANDBOX/cabinet/env/${ENV_SLUG}.env"
if [ -f "$env_path" ]; then
  env_content=$(cat "$env_path")
  assert_contains "T8: env has TELEGRAM_HQ_CHAT_ID"          "$env_content" "TELEGRAM_HQ_CHAT_ID"
  assert_contains "T8: env has NEON_CONNECTION_STRING"        "$env_content" "NEON_CONNECTION_STRING"
  # FW-082 hotfix-3: PRODUCT_REPO_PATH default now $CABINET_ROOT/projects/<slug>
  # (was /opt/<slug>). Assert the path field is set + ends with the slug — the
  # exact root is operator-overridable via PRODUCT_REPO_ROOT env var.
  assert_contains "T8: env has PRODUCT_REPO_PATH for slug"   "$env_content" "PRODUCT_REPO_PATH="
  assert_contains "T8: PRODUCT_REPO_PATH ends in /<slug>"    "$env_content" "/${ENV_SLUG}"
  assert_contains "T8: env has CABINET_PREFIX for slug"       "$env_content" "CABINET_PREFIX=${ENV_SLUG}"
  # Secret discipline: GITHUB_PAT must never appear in env file
  if grep -q "GITHUB_PAT=" "$env_path" 2>/dev/null; then
    FAIL=$((FAIL+1))
    FAILURES+=("T8: GITHUB_PAT must not appear in env file")
    printf "  [FAIL] T8: GITHUB_PAT must not appear in env file\n"
  else
    PASS=$((PASS+1))
    printf "  [PASS] T8: GITHUB_PAT not in env file\n"
  fi
else
  FAIL=$((FAIL+1))
  FAILURES+=("T8: env file not created at $env_path")
  printf "  [FAIL] T8: env file not created at %s\n" "$env_path"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================="
printf " Test Results: %d PASS / %d FAIL\n" "$PASS" "$FAIL"
echo "=============================="

if [ ${#FAILURES[@]} -gt 0 ]; then
  echo ""
  echo "FAILURES:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
fi

[ "$FAIL" -eq 0 ]
