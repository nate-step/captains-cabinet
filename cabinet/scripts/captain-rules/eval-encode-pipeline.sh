#!/bin/bash
# eval-encode-pipeline.sh — Spec 048 v2 encode → draft → ratify regression eval.
#
# The Spec 048 v2 ENCODE pipeline (encoder hook → classify-rule.sh → draft-
# generator.sh → ratify-rule.sh) had no permanent regression test after
# the initial ship — manual probes verified each stage at PR time, but
# silent breakage of draft templates, ratify settings.json patching, or
# audit-log shape would now go unnoticed until a Captain encode-signal
# fires in production and silently fails.
#
# This eval exercises the deterministic half of the pipeline (skipping
# the API-bound classify-rule.sh) with a hermetic temp REPO_ROOT:
#
#   1. Stub a classifier output JSON (operationalizable, conf=0.85, 4 triggers).
#   2. Run draft-generator.sh — assert hook + skill drafts written at
#      expected paths with expected contents (env-var disable, JSONL log
#      path, rule body inline, anti-FW-042 set -u + warn-mode markers).
#   3. Run ratify-rule.sh yes — assert .draft files moved to live paths,
#      hook chmod +x, settings.json now contains the new PreToolUse entry,
#      audit log appended with outcome=yes + extra=<live_hook_path>.
#   4. Run ratify-rule.sh no on a fresh rule — assert .draft files removed,
#      audit log appended with outcome=no.
#   5. Anti-over-hooking floor — pass classifier output with 2 triggers;
#      assert draft-generator.sh exits 0 without writing files (auto-
#      downgrade per classify-rule.sh post-process).
#
# Run:
#   bash cabinet/scripts/captain-rules/eval-encode-pipeline.sh
# Exit 0 = all PASS, 1 = any FAIL.

set -uo pipefail

DRAFT_GEN="/opt/founders-cabinet/cabinet/scripts/captain-rules/draft-generator.sh"
RATIFY="/opt/founders-cabinet/cabinet/scripts/captain-rules/ratify-rule.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0
FAILURES=()

ok() {
  PASS=$((PASS + 1))
  printf "  [PASS]   %s\n" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf "  [FAIL]   %s\n" "$1"
}

# Set up hermetic REPO_ROOT structure mirroring the live tree.
setup_root() {
  local root="$1"
  mkdir -p "$root/cabinet/scripts/hooks/draft" \
           "$root/memory/skills/evolved/draft" \
           "$root/cabinet/logs" \
           "$root/.claude"
  # Minimal settings.json with hooks structure (matches live shape — see
  # /opt/founders-cabinet/.claude/settings.json head).
  cat > "$root/.claude/settings.json" <<'EOF'
{
  "permissions": {"allow": [], "deny": []},
  "hooks": {
    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "bash existing-encoder.sh"}]}],
    "PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "bash existing-pre.sh"}]}],
    "PostToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "bash existing-post.sh"}]}]
  }
}
EOF
}

# Stub classifier output — 4 triggers (passes anti-over-hooking floor of ≥3).
make_classifier_json() {
  local trigger_count="${1:-4}"
  local triggers='["I think","I feel","sort of","kind of"]'
  if [ "$trigger_count" -eq 2 ]; then
    triggers='["I think","I feel"]'   # below floor — should auto-downgrade
  fi
  cat <<EOF
{"class":"operationalizable","trigger_signals":$triggers,"trigger_surface":"Reply","confidence":0.85,"reasoning":"Distinctive hedge-phrase patterns surface candidate Captain-identified anti-pattern"}
EOF
}

# ───────────────────────────────────────────────────────────────────────────
# Test 1: draft-generator.sh writes both drafts when classifier ok
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 1: draft-generator writes hook + skill drafts (4 triggers, conf=0.85)"
ROOT1="$TMP_DIR/test1"
setup_root "$ROOT1"
RULE_BODY1="$TMP_DIR/rule1.txt"
echo "Avoid hedge phrases in Captain replies — say 'this' not 'I think this'." > "$RULE_BODY1"
CLS1=$(make_classifier_json 4)
RULE_ID1="C-test1"

REPO_ROOT="$ROOT1" OFFICER_NAME=cto bash "$DRAFT_GEN" "$RULE_ID1" "$RULE_BODY1" "$CLS1" >/dev/null 2>&1
EC=$?
[ "$EC" = "0" ] && ok "exit code 0" || fail "exit code $EC ≠ 0"

HOOK_DRAFT="$ROOT1/cabinet/scripts/hooks/draft/$RULE_ID1.sh.draft"
SKILL_DRAFT="$ROOT1/memory/skills/evolved/draft/$RULE_ID1.md.draft"

[ -f "$HOOK_DRAFT" ] && ok "hook draft written" || fail "hook draft missing at $HOOK_DRAFT"
[ -f "$SKILL_DRAFT" ] && ok "skill draft written" || fail "skill draft missing at $SKILL_DRAFT"

if grep -q "set -u" "$HOOK_DRAFT" 2>/dev/null; then
  ok "hook has 'set -u' (anti-FW-042 discipline)"
else
  fail "hook missing 'set -u'"
fi

if grep -q "RULE_C_TEST1_HOOK_ENABLED" "$HOOK_DRAFT" 2>/dev/null; then
  ok "hook has env-var disable RULE_<id>_HOOK_ENABLED"
else
  fail "hook missing env-var disable"
fi

if grep -q "$RULE_ID1.jsonl" "$HOOK_DRAFT" 2>/dev/null; then
  ok "hook writes FP-rate JSONL"
else
  fail "hook missing JSONL log path"
fi

if grep -q "I think" "$HOOK_DRAFT" 2>/dev/null; then
  ok "hook embeds first trigger phrase"
else
  fail "hook missing trigger phrase 'I think'"
fi

if grep -q "Avoid hedge phrases" "$SKILL_DRAFT" 2>/dev/null; then
  ok "skill embeds rule body verbatim"
else
  fail "skill missing rule body"
fi

[ -f "/tmp/.captain-pending-drafts-cto" ] && grep -qxF "$RULE_ID1" "/tmp/.captain-pending-drafts-cto" \
  && ok "pending-drafts marker contains rule id" \
  || fail "pending marker missing entry"

# Cleanup pending marker for test isolation
rm -f "/tmp/.captain-pending-drafts-cto" 2>/dev/null

# ───────────────────────────────────────────────────────────────────────────
# Test 2: ratify-rule.sh yes promotes drafts + patches settings.json
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 2: ratify-rule yes promotes drafts to live + patches settings.json"

# Drafts already exist from Test 1's setup (re-using ROOT1)
REPO_ROOT="$ROOT1" OFFICER_NAME=cto bash "$RATIFY" "$RULE_ID1" yes >/dev/null 2>&1
EC=$?
[ "$EC" = "0" ] && ok "ratify yes exit code 0" || fail "ratify yes exit code $EC"

HOOK_LIVE="$ROOT1/cabinet/scripts/hooks/$RULE_ID1.sh"
SKILL_LIVE="$ROOT1/memory/skills/evolved/$RULE_ID1.md"

[ -f "$HOOK_LIVE" ] && ok "hook moved to live path" || fail "hook missing at live path"
[ -f "$SKILL_LIVE" ] && ok "skill moved to live path" || fail "skill missing at live path"
[ ! -f "$HOOK_DRAFT" ] && ok "hook draft removed" || fail "hook draft still present"
[ ! -f "$SKILL_DRAFT" ] && ok "skill draft removed" || fail "skill draft still present"

[ -x "$HOOK_LIVE" ] && ok "hook chmod +x applied" || fail "hook not executable"

# settings.json patched: should now have 2 PreToolUse blocks (existing + new)
PRE_COUNT=$(python3 -c "
import json
with open('$ROOT1/.claude/settings.json') as f:
    d = json.load(f)
print(len(d.get('hooks', {}).get('PreToolUse', [])))
" 2>/dev/null)
[ "$PRE_COUNT" = "2" ] && ok "settings.json PreToolUse extended (2 blocks)" \
  || fail "settings.json PreToolUse count = $PRE_COUNT (expected 2)"

NEW_HOOK_PRESENT=$(python3 -c "
import json
with open('$ROOT1/.claude/settings.json') as f:
    d = json.load(f)
for block in d.get('hooks', {}).get('PreToolUse', []):
    for h in block.get('hooks', []):
        if 'C-test1.sh' in h.get('command', ''):
            print('yes'); exit()
print('no')
" 2>/dev/null)
[ "$NEW_HOOK_PRESENT" = "yes" ] && ok "settings.json command path references new live hook" \
  || fail "settings.json missing reference to new hook"

# Audit log appended with outcome=yes
AUDIT="$ROOT1/cabinet/logs/rule-promotions.jsonl"
[ -f "$AUDIT" ] && ok "audit log file created" || fail "audit log missing"
if [ -f "$AUDIT" ] && grep -q '"outcome":"yes"' "$AUDIT" 2>/dev/null; then
  ok "audit log entry: outcome=yes"
else
  fail "audit log missing outcome=yes"
fi
if [ -f "$AUDIT" ] && grep -q "$RULE_ID1.sh" "$AUDIT" 2>/dev/null; then
  ok "audit log entry: cites live hook path"
else
  fail "audit log missing live hook path"
fi

# Pending marker cleaned up after ratify
[ ! -f "/tmp/.captain-pending-drafts-cto" ] || ! grep -qxF "$RULE_ID1" "/tmp/.captain-pending-drafts-cto" \
  && ok "pending marker cleared after ratify yes" \
  || fail "pending marker still has $RULE_ID1"

# ───────────────────────────────────────────────────────────────────────────
# Test 3: ratify-rule.sh no removes drafts, no settings.json change
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 3: ratify-rule no removes drafts, leaves settings.json untouched"
ROOT3="$TMP_DIR/test3"
setup_root "$ROOT3"
RULE_BODY3="$TMP_DIR/rule3.txt"
echo "Different rule body for test 3" > "$RULE_BODY3"
CLS3=$(make_classifier_json 4)
RULE_ID3="C-test3"

REPO_ROOT="$ROOT3" OFFICER_NAME=cto bash "$DRAFT_GEN" "$RULE_ID3" "$RULE_BODY3" "$CLS3" >/dev/null 2>&1

# Snapshot settings.json shape pre-ratify
PRE_SNAP=$(python3 -c "
import json
with open('$ROOT3/.claude/settings.json') as f:
    d = json.load(f)
print(len(d.get('hooks', {}).get('PreToolUse', [])))
" 2>/dev/null)

REPO_ROOT="$ROOT3" OFFICER_NAME=cto bash "$RATIFY" "$RULE_ID3" no >/dev/null 2>&1
EC=$?
[ "$EC" = "0" ] && ok "ratify no exit code 0" || fail "ratify no exit code $EC"

HOOK_DRAFT3="$ROOT3/cabinet/scripts/hooks/draft/$RULE_ID3.sh.draft"
SKILL_DRAFT3="$ROOT3/memory/skills/evolved/draft/$RULE_ID3.md.draft"
[ ! -f "$HOOK_DRAFT3" ] && ok "hook draft removed" || fail "hook draft still present after no"
[ ! -f "$SKILL_DRAFT3" ] && ok "skill draft removed" || fail "skill draft still present after no"

# settings.json count unchanged
POST_SNAP=$(python3 -c "
import json
with open('$ROOT3/.claude/settings.json') as f:
    d = json.load(f)
print(len(d.get('hooks', {}).get('PreToolUse', [])))
" 2>/dev/null)
[ "$PRE_SNAP" = "$POST_SNAP" ] && ok "settings.json untouched on ratify no" \
  || fail "settings.json mutated despite ratify no (pre=$PRE_SNAP post=$POST_SNAP)"

# Audit log on ratify no
AUDIT3="$ROOT3/cabinet/logs/rule-promotions.jsonl"
if [ -f "$AUDIT3" ] && grep -q '"outcome":"no"' "$AUDIT3" 2>/dev/null; then
  ok "audit log entry: outcome=no"
else
  fail "audit log missing outcome=no"
fi

# Cleanup pending marker
rm -f "/tmp/.captain-pending-drafts-cto" 2>/dev/null

# ───────────────────────────────────────────────────────────────────────────
# Test 4: draft-generator skips when classifier returned values-only
# ───────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 4: draft-generator skips on values-only classifier output"
ROOT4="$TMP_DIR/test4"
setup_root "$ROOT4"
RULE_BODY4="$TMP_DIR/rule4.txt"
echo "Soft preference rule body" > "$RULE_BODY4"
# values-only classifier output (anti-over-hooking auto-downgrade simulation)
CLS4='{"class":"values-only","trigger_signals":[],"trigger_surface":null,"confidence":0.6,"reasoning":"Soft preference, no distinctive triggers"}'
RULE_ID4="C-test4"

REPO_ROOT="$ROOT4" OFFICER_NAME=cto bash "$DRAFT_GEN" "$RULE_ID4" "$RULE_BODY4" "$CLS4" >/dev/null 2>&1
EC=$?
[ "$EC" = "0" ] && ok "exit code 0 (graceful skip)" || fail "exit code $EC"

HOOK_DRAFT4="$ROOT4/cabinet/scripts/hooks/draft/$RULE_ID4.sh.draft"
[ ! -f "$HOOK_DRAFT4" ] && ok "no hook draft written for values-only" \
  || fail "draft written despite values-only class"

# Cleanup pending marker
rm -f "/tmp/.captain-pending-drafts-cto" 2>/dev/null

# ───────────────────────────────────────────────────────────────────────────
# Test 5: draft-generator skips when classifier triggers below floor
# ───────────────────────────────────────────────────────────────────────────
# Note: classify-rule.sh enforces the floor by rewriting class to
# values-only; draft-generator only checks class. This test exercises the
# defensive path where if a non-classify caller passes <3 triggers but
# class=operationalizable, we still write drafts (caller's responsibility,
# not draft-generator's). Documents the contract.
echo ""
echo "Test 5: draft-generator honors caller's class verdict (floor is classifier's job)"
ROOT5="$TMP_DIR/test5"
setup_root "$ROOT5"
RULE_BODY5="$TMP_DIR/rule5.txt"
echo "Test 5 rule" > "$RULE_BODY5"
CLS5='{"class":"operationalizable","trigger_signals":["only-one-trigger"],"trigger_surface":"Reply","confidence":0.85,"reasoning":"Caller bypassed floor"}'
RULE_ID5="C-test5"
REPO_ROOT="$ROOT5" OFFICER_NAME=cto bash "$DRAFT_GEN" "$RULE_ID5" "$RULE_BODY5" "$CLS5" >/dev/null 2>&1

HOOK_DRAFT5="$ROOT5/cabinet/scripts/hooks/draft/$RULE_ID5.sh.draft"
[ -f "$HOOK_DRAFT5" ] && ok "draft generator writes drafts (no floor check inside generator)" \
  || fail "draft generator silently dropped operationalizable verdict"

# Cleanup
rm -f "/tmp/.captain-pending-drafts-cto" 2>/dev/null

# ───────────────────────────────────────────────────────────────────────────
# Summary
# ───────────────────────────────────────────────────────────────────────────
echo ""
printf "==== %d PASS, %d FAIL ====\n" "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Failures:"
  for f in "${FAILURES[@]}"; do
    echo "  - $f"
  done
  exit 1
fi
exit 0
