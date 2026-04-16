#!/bin/bash
# Sprint A golden evals for The Library
# Runs through every CP1-5 critical behavior. Exit 0 = all pass, non-zero = failure.
# Usage: bash memory/golden-evals/library/sprint-a.sh

set -uo pipefail
set -a
source /opt/founders-cabinet/cabinet/.env 2>/dev/null
set +a
source /opt/founders-cabinet/cabinet/scripts/lib/library.sh

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== Sprint A Golden Evals — The Library ==="

# Cleanup from any prior run
psql "$NEON_CONNECTION_STRING" -q -c "DELETE FROM library_records WHERE space_id IN (SELECT id FROM library_spaces WHERE name LIKE 'eval-%'); DELETE FROM library_spaces WHERE name LIKE 'eval-%';" > /dev/null 2>&1

# ============================================================
# CP1 — Schema
# ============================================================
echo ""
echo "--- CP1: Schema ---"

# Idempotency
OUT=$(psql "$NEON_CONNECTION_STRING" -f /opt/founders-cabinet/cabinet/sql/library.sql 2>&1)
if echo "$OUT" | grep -qi "error"; then
  fail "schema apply"
else
  pass "schema applies cleanly"
fi

# All 5 indexes present
IDX_COUNT=$(psql "$NEON_CONNECTION_STRING" -t -A -c "SELECT count(*) FROM pg_indexes WHERE tablename = 'library_records';")
if [ "$IDX_COUNT" -ge 5 ]; then
  pass "all library_records indexes present (found $IDX_COUNT)"
else
  fail "missing indexes on library_records (found $IDX_COUNT, expected >=5)"
fi

# ============================================================
# CP2 — library.sh
# ============================================================
echo ""
echo "--- CP2: library.sh ---"

# Create space
SID=$(library_create_space "eval-space-1" "Golden eval space" "{}" "blank" "cos")
[ -n "$SID" ] && [ "$SID" -gt 0 ] 2>/dev/null && pass "create_space returns id" || fail "create_space"

# Create record
RID=$(library_create_record "$SID" "Eval record v1" "First version of content" "{}" "eval,v1")
[ -n "$RID" ] && [ "$RID" -gt 0 ] 2>/dev/null && pass "create_record returns id" || fail "create_record"

# Semantic search
SEARCH=$(library_search "first version content" "$SID" "" 3 2>&1)
if echo "$SEARCH" | grep -q "Eval record v1"; then
  pass "search returns semantic match"
else
  fail "search missed obvious match"
fi

# Empty content rejected
if library_create_record "$SID" "" "" > /dev/null 2>&1; then
  fail "empty title accepted (should reject)"
else
  pass "empty title rejected"
fi

# SQL injection in space_filter does not break scope
INJ=$(library_search "anything" "1 OR true" "" 3 2>&1 | wc -l)
[ "$INJ" -le 1 ] && pass "SQL injection returns no rows" || fail "SQL injection broke scope ($INJ rows)"

# Update bumps version
NEW_RID=$(library_update_record "$RID" "Eval record v2" "Second version" "{}" "eval,v2")
[ -n "$NEW_RID" ] && [ "$NEW_RID" != "$RID" ] && pass "update returns new record id" || fail "update"

# Version = 2 on new record
VER=$(psql "$NEON_CONNECTION_STRING" -t -A -c "SELECT version FROM library_records WHERE id = $NEW_RID;")
[ "$VER" = "2" ] && pass "new version is 2" || fail "version did not bump (got $VER)"

# Old record superseded
SUP=$(psql "$NEON_CONNECTION_STRING" -t -A -c "SELECT superseded_by FROM library_records WHERE id = $RID;")
[ "$SUP" = "$NEW_RID" ] && pass "old record pointer set correctly" || fail "superseded_by not set (got $SUP)"

# Active list shows only v2
ACTIVE_COUNT=$(library_list_records "$SID" 10 | grep -c "Eval record")
[ "$ACTIVE_COUNT" = "1" ] && pass "list_records excludes superseded" || fail "list_records count ($ACTIVE_COUNT, expected 1)"

# Soft delete
DEL_RID=$(library_create_record "$SID" "to-delete" "x" "{}" "")
library_delete_record "$DEL_RID" > /dev/null
POST_DEL_COUNT=$(library_list_records "$SID" 10 | grep -c "to-delete")
[ "$POST_DEL_COUNT" = "0" ] && pass "soft delete hides record" || fail "soft delete"

# ============================================================
# CP3 — MCP server (structural check only, full integration in cabinet)
# ============================================================
echo ""
echo "--- CP3: MCP server ---"

[ -f /opt/founders-cabinet/cabinet/channels/library-mcp/index.ts ] && pass "MCP server file exists" || fail "MCP server missing"
[ -f /opt/founders-cabinet/cabinet/channels/library-mcp/package.json ] && pass "MCP package.json exists" || fail "package.json missing"
[ -d /opt/founders-cabinet/cabinet/channels/library-mcp/node_modules ] && pass "MCP deps installed" || fail "deps not installed"
grep -q '"library"' /opt/founders-cabinet/.mcp.json && pass "MCP registered in .mcp.json" || fail ".mcp.json missing library entry"

# ============================================================
# CP4 — Dashboard (structural check)
# ============================================================
echo ""
echo "--- CP4: Dashboard ---"

if [ -f "/opt/founders-cabinet/cabinet/dashboard/src/app/(authenticated)/library/page.tsx" ]; then
  pass "dashboard /library route exists"
else
  fail "dashboard /library route missing"
fi
# API routes
for route in spaces "spaces/[spaceId]/records" "records/[recordId]" "records/[recordId]/history" search; do
  if [ -f "/opt/founders-cabinet/cabinet/dashboard/src/app/api/library/$route/route.ts" ]; then
    pass "API route /api/library/$route exists"
  else
    fail "API route /api/library/$route missing"
  fi
done

# ============================================================
# CP5 — Starter template + install
# ============================================================
echo ""
echo "--- CP5: Starter ---"

[ -f /opt/founders-cabinet/cabinet/starter-spaces/blank.json ] && pass "blank starter exists" || fail "blank starter missing"
[ -x /opt/founders-cabinet/cabinet/scripts/install-starter-space.sh ] && pass "install script executable" || fail "install script missing/not-executable"

# Verify Blank Space installed
BLANK_ID=$(library_space_id "Blank")
[ -n "$BLANK_ID" ] && [ "$BLANK_ID" -gt 0 ] 2>/dev/null && pass "Blank Space present in Neon" || fail "Blank Space not found"

# ============================================================
# Cleanup eval spaces
# ============================================================
psql "$NEON_CONNECTION_STRING" -q -c "DELETE FROM library_records WHERE space_id IN (SELECT id FROM library_spaces WHERE name LIKE 'eval-%'); DELETE FROM library_spaces WHERE name LIKE 'eval-%';" > /dev/null 2>&1

# ============================================================
# Summary
# ============================================================
echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
