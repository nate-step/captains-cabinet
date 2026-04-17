#!/bin/bash
# Phase 1 pre-Captain test suite. Exits 0 if every Phase 1 CP deliverable
# is present and functional. Non-zero until all CPs land.
#
# Expected state: initially RED across all sections (each CP failing until
# built). Each CP commit turns its section green. All green = Phase 1 ready
# for Captain review.

cd /opt/founders-cabinet
set -a
source cabinet/.env 2>/dev/null
set +a

PASS=0
FAIL=0
SKIP=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1 ($2)"; SKIP=$((SKIP+1)); }

echo "=== Phase 1 Pre-Captain Test Suite ==="
echo "Locked CDs (2026-04-16): CD1 Contexts / CD2 Library-inbox / CD3 warroom-auto-migrate"
echo "                         CD4 scaffold-only / CD5 stdio-MCP / CD6 backfill"
echo "                         CD7 hire-time naming / CD8 Opus-4.7 reviewer"
echo ""

NEON_URL="${NEON_CONNECTION_STRING:-$NEON_DATABASE_URL}"
PSQL() { psql "$NEON_URL" -tAc "$1" 2>/dev/null; }

echo "--- CP1: Context slug columns + yaml source-of-truth ---"
# Design (Captain 2026-04-16): NO contexts DB table. YAML files at
# instance/config/contexts/*.yml are source of truth. Target tables carry
# a context_slug TEXT column. Validation happens in pre-tool-use hook (CP2).
#
# Expect after CP1:
# - cabinet postgres: experience_records.context_slug (nullable TEXT + index)
# - product Neon: cabinet_memory.context_slug (nullable TEXT + index)
# - product Neon: library_records.context_slug (nullable TEXT + index)
# - instance/config/contexts/*.yml: per-context config (slug, name, capacity, etc.)
# - load-preset.sh applies the two new migrations to both DBs

CAB_PSQL() { [ -n "${DATABASE_URL:-}" ] && psql "$DATABASE_URL" -tAc "$1" 2>/dev/null; }
PROD_PSQL() { [ -n "${NEON_CONNECTION_STRING:-}" ] && psql "$NEON_CONNECTION_STRING" -tAc "$1" 2>/dev/null; }

# Cabinet postgres: experience_records.context_slug
if CAB_PSQL "SELECT 1 FROM information_schema.columns WHERE table_name='experience_records' AND column_name='context_slug'" | grep -q 1; then
  pass "cabinet.experience_records.context_slug exists"
else
  fail "cabinet.experience_records.context_slug missing"
fi

# Product Neon: cabinet_memory.context_slug + library_records.context_slug
if PROD_PSQL "SELECT 1 FROM information_schema.columns WHERE table_name='cabinet_memory' AND column_name='context_slug'" | grep -q 1; then
  pass "product.cabinet_memory.context_slug exists"
else
  fail "product.cabinet_memory.context_slug missing"
fi
if PROD_PSQL "SELECT 1 FROM information_schema.columns WHERE table_name='library_records' AND column_name='context_slug'" | grep -q 1; then
  pass "product.library_records.context_slug exists"
else
  fail "product.library_records.context_slug missing"
fi

# Yaml source-of-truth
[ -d instance/config/contexts ] && pass "instance/config/contexts/ exists" || fail "instance/config/contexts/ missing"
[ -f instance/config/contexts/sensed.yml ] && pass "sensed.yml context definition exists" || fail "sensed.yml missing"
[ -f instance/config/contexts/adhoc.yml ] && pass "adhoc.yml context definition exists" || fail "adhoc.yml missing"

# Loader integration
grep -q 'contexts-cabinet-phase1.sql\|contexts-neon-phase1.sql' cabinet/scripts/load-preset.sh 2>/dev/null && pass "load-preset.sh applies Phase 1 migrations" || fail "load-preset.sh missing Phase 1 migration refs"

echo ""
echo "--- CP2: Capacity tagging + slug validation (pre-tool-use enforcement) ---"
# Expect: pre-tool-use.sh loads context slug list from instance/config/contexts/*.yml at session start
# Expect: pre-tool-use.sh rejects writes that use an unknown context_slug
# Expect: pre-tool-use.sh enforces no cross-capacity data coupling (work agent can't write personal row)
# Expect: backfill script for legacy rows (assigns context_slug = active-project default)
grep -q 'context_slug\|instance/config/contexts' cabinet/scripts/hooks/pre-tool-use.sh 2>/dev/null && pass "pre-tool-use references contexts" || fail "pre-tool-use context validation missing"
grep -q 'cross-capacity\|capacity_check\|capacity_enforce' cabinet/scripts/hooks/pre-tool-use.sh 2>/dev/null && pass "pre-tool-use enforces cross-capacity rule" || fail "pre-tool-use cross-capacity enforcement missing"
[ -f cabinet/scripts/backfill-context-slug.sh ] && pass "backfill script exists" || fail "backfill script missing"

echo ""
echo "--- CP3: CoS context routing ---"
# Expect: memory/skills/context-routing.md skill defined
# Expect: inbound work routed to correct context agent set
[ -f memory/skills/context-routing.md ] || [ -f memory/skills/evolved/context-routing.md ] && pass "context-routing skill exists" || fail "context-routing skill missing"

echo ""
echo "--- CP4: New agent archetypes (scaffolded, not hired) ---"
# Expect: presets/work/agents/operations-officer.md, compliance-officer.md, executive-assistant.md
# Expect: preset.yml has naming_style metadata
# Expect: hire-time skill: CoS proposes 3 names, Captain picks
for a in operations-officer compliance-officer executive-assistant; do
  [ -f "presets/work/agents/$a.md" ] && pass "presets/work/agents/$a.md scaffolded" || fail "presets/work/agents/$a.md missing"
done
grep -q 'naming_style:' presets/work/preset.yml 2>/dev/null && pass "work preset has naming_style" || fail "work preset naming_style missing"
[ -f memory/skills/hire-agent.md ] || [ -f memory/skills/evolved/hire-agent.md ] && pass "hire-agent skill exists" || fail "hire-agent skill missing"

echo ""
echo "--- CP5: MCP scope system ---"
# Expect: cabinet/mcp-scope.yml defines per-agent MCPs, structure supports per-Cabinet filter
# Expect: pre-tool-use enforces scope on MCP tool calls
[ -f cabinet/mcp-scope.yml ] && pass "mcp-scope.yml exists" || fail "mcp-scope.yml missing"
grep -q 'mcp.*scope\|scope.*check' cabinet/scripts/hooks/pre-tool-use.sh 2>/dev/null && pass "pre-tool-use enforces MCP scope" || fail "MCP scope enforcement missing"

echo ""
echo "--- CP6: Ad-hoc task inbox (Library space 'Inbox') ---"
# Expect: Library space 'Inbox' exists with schema (title, owner, state, context_slug, captured_at, due)
inbox_id=$(PROD_PSQL "SELECT id FROM library_spaces WHERE name='Inbox' LIMIT 1")
[ -n "$inbox_id" ] && pass "Library space 'Inbox' exists (id=$inbox_id)" || fail "Library space 'Inbox' missing"

echo ""
echo "--- CP7: Multi-warroom routing ---"
# Expect: send-to-warroom.sh (new) accepts context param, legacy send-to-group.sh auto-maps to sensed-warroom
[ -f cabinet/scripts/send-to-warroom.sh ] && pass "send-to-warroom.sh exists" || fail "send-to-warroom.sh missing"
grep -q 'sensed-warroom' cabinet/scripts/send-to-group.sh 2>/dev/null && pass "legacy send-to-group auto-maps" || fail "legacy send-to-group auto-map missing"

echo ""
echo "--- CP8: Cabinet MCP prototype ---"
# Expect: Cabinet MCP stdio server with single tool cabinet:identify() → {cabinet_id, captain_id, available_agents}
[ -d cabinet/mcp-server ] && pass "cabinet/mcp-server/ exists" || fail "Cabinet MCP server not yet scaffolded"

echo ""
echo "--- CP9: Cabinet identity in structured logs ---"
# Expect: post-tool-use.sh writes cabinet_id to JSONL + experience_records
grep -q 'cabinet_id' cabinet/scripts/hooks/post-tool-use.sh 2>/dev/null && pass "post-tool-use logs cabinet_id" || fail "cabinet_id not in structured log"
grep -q 'cabinet_id' cabinet/scripts/record-experience.sh 2>/dev/null && pass "experience records carry cabinet_id" || fail "experience records missing cabinet_id"

echo ""
echo "--- CP10: Phase 1 golden eval harness ---"
[ -f memory/golden-evals/phase-1/pre-captain-test.sh ] && pass "phase-1 eval harness exists" || fail "phase-1 eval harness missing"

echo ""
echo "========================="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "SKIP: $SKIP"
echo "========================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
