#!/usr/bin/env bash
# cabinet/scripts/cutover/cutover-to-tasks.sh
# Spec 039 §5.9 Gate 4 Steps 1-5 — atomic cutover orchestration.
#
# Runs as a single chain, no interactive pauses between steps (except Phase 2b
# which requires operator to revoke keys in Linear UI). Each step's recovery
# policy is defined in §5.9 M-4 (summary in runbook §2).
#
# Addresses COO preemptive adversary:
#   M-β — internal pre-step-1 delta re-check via delta-verify.py --strict;
#         aborts if drift > 5 rows from manual §1 baseline.
#   M-γ — per-attempt warroom guard keyed by cutover-at timestamp so re-runs
#         after partial failure can re-post without collision.
#
# Prereqs: see runbook §0. This script fails closed on any missing env var.
#
# Operator: CoS (per §5.9 Gate-gating protocol).

set -euo pipefail

CUTOVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAMEWORK_ROOT="$(cd "$CUTOVER_DIR/../../.." && pwd)"
LOG_PREFIX="[cutover]"

log() { echo "$LOG_PREFIX $*" >&2; }
die() { echo "$LOG_PREFIX ERROR: $*" >&2; exit 1; }

REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"
redis() { redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "$@"; }

# ---------------------------------------------------------------------------
# Prereq gating (fail closed)
# ---------------------------------------------------------------------------

log "Prereq check..."
# N-M-α fix: canonicalize on NEON_CONNECTION_STRING (used repo-wide: bootstrap-host.sh,
# gate-3-idempotency.*, etl-common.py). PROD_DATABASE_URL was non-canonical.
for var in NEON_CONNECTION_STRING LINEAR_API_KEY GITHUB_PAT WARROOM_CHAT_ID TELEGRAM_BOT_TOKEN; do
  if [ -z "${!var:-}" ]; then die "$var not set"; fi
done
command -v python3 >/dev/null || die "python3 not in PATH"
python3 -c "import requests, yaml" 2>/dev/null || die "Python deps missing (requests, PyYAML)"
# psycopg2 required for Step 1 (prod ETL upsert); lazy-imported in etl-common.
python3 -c "import psycopg2" 2>/dev/null || die "psycopg2 missing — required for Step 1 prod ETL"

GATE_1_TS=$(redis GET cabinet:migration:039:gate-1-completed-at)
[ -n "$GATE_1_TS" ] || die "cabinet:migration:039:gate-1-completed-at empty — Gate 1 not run"
log "Gate 1 timestamp: $GATE_1_TS"

# ---------------------------------------------------------------------------
# Step 0 — Pre-step-1 delta re-check (M-β atomic drift guard)
# ---------------------------------------------------------------------------

log "0. Pre-flight delta re-check (strict mode — drift tolerance 5 rows)..."
if ! python3 "$CUTOVER_DIR/delta-verify.py" --strict; then
  die "delta-verify --strict failed — source drifted materially since manual §1 check. ABORT."
fi

# ---------------------------------------------------------------------------
# Step 1 — Prod ETL run
# ---------------------------------------------------------------------------

log "1. Prod ETL run..."
ETL_SCRIPT="$FRAMEWORK_ROOT/cabinet/scripts/migrate-sources-to-officer-tasks.sh"
[ -x "$ETL_SCRIPT" ] || die "migrate-sources-to-officer-tasks.sh not executable at $ETL_SCRIPT"
bash "$ETL_SCRIPT" || die "Step 1 prod ETL failed"
log "1. Prod ETL complete."

# ---------------------------------------------------------------------------
# Step 2 — Linear write-freeze (demote-all-then-revoke-all per H-α)
# ---------------------------------------------------------------------------

log "2. Linear write-freeze..."
python3 "$CUTOVER_DIR/linear-freeze.py" || die "Step 2 Linear freeze failed"
log "2. Linear write-freeze complete."

# ---------------------------------------------------------------------------
# Step 3 — GH Issues write-disable (demote bots to read per M-α)
# ---------------------------------------------------------------------------

log "3. GH Issues write-disable..."
python3 "$CUTOVER_DIR/gh-freeze.py" || die "Step 3 GH freeze failed"
log "3. GH Issues write-disable complete."

# ---------------------------------------------------------------------------
# Step 4 — Redis stamp (cutover-at)
# ---------------------------------------------------------------------------

# N-L-α fix: first successful step-4 claims the cutover-at timestamp (SET NX). Re-runs
# re-use the same timestamp → same Step 5 guard key → orphan-guard risk vanishes.
CUTOVER_AT_CANDIDATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
redis SET cabinet:migration:039:cutover-at "$CUTOVER_AT_CANDIDATE" NX >/dev/null
CUTOVER_AT=$(redis GET cabinet:migration:039:cutover-at)
[ -n "$CUTOVER_AT" ] && [ "$CUTOVER_AT" != "(nil)" ] || die "cutover-at not set after SET NX"
log "4. Redis stamp: cabinet:migration:039:cutover-at = $CUTOVER_AT (first-claim wins; re-runs reuse)"

# ---------------------------------------------------------------------------
# Step 5 — Warroom post (per-attempt + cumulative guards, M-γ + N-M-δ)
# ---------------------------------------------------------------------------

# Two guards enforced in series:
#   1. CUMULATIVE (N-M-δ fix): cabinet:migration:039:warroom-posted-any — set
#      the FIRST time warroom post succeeds, never unset. Protects against
#      full-re-run-after-full-success scenarios where someone manually wipes
#      cutover-at (intentional fresh run) — we still must not double-post.
#   2. PER-ATTEMPT (M-γ): cabinet:migration:039:warroom-posted:$CUTOVER_AT —
#      keyed by the current cutover-at so legitimate re-runs after partial
#      failure (where warroom step never fired) still post once.
WARROOM_CUMULATIVE_KEY="cabinet:migration:039:warroom-posted-any"
WARROOM_ATTEMPT_KEY="cabinet:migration:039:warroom-posted:$CUTOVER_AT"

CUMULATIVE_EXISTING=$(redis GET "$WARROOM_CUMULATIVE_KEY")
ATTEMPT_EXISTING=$(redis GET "$WARROOM_ATTEMPT_KEY")

if [ -n "$CUMULATIVE_EXISTING" ] && [ "$CUMULATIVE_EXISTING" != "(nil)" ]; then
  log "5. Cumulative warroom guard already set ($WARROOM_CUMULATIVE_KEY = $CUMULATIVE_EXISTING) — skipping (N-M-δ: prevents double-post on forced re-run)."
elif [ -n "$ATTEMPT_EXISTING" ] && [ "$ATTEMPT_EXISTING" != "(nil)" ]; then
  log "5. Per-attempt warroom guard already set ($WARROOM_ATTEMPT_KEY = $ATTEMPT_EXISTING) — skipping (M-γ)."
else
  log "5. Warroom post (guards: cumulative + attempt on $CUTOVER_AT)"
  MSG="Spec 039 Phase A cutover complete at ${CUTOVER_AT}. Linear + GH Issues now read-only for Cabinet service accounts. /tasks is the single source of truth. Officers: resume on /tasks; Captain: retains admin on both surfaces for archival access."
  bash "$FRAMEWORK_ROOT/cabinet/scripts/send-to-group.sh" "$MSG" \
    || { log "WARNING: warroom send failed — re-post manually (guards NOT set)"; exit 1; }
  redis SET "$WARROOM_ATTEMPT_KEY" "$CUTOVER_AT" >/dev/null
  redis SET "$WARROOM_CUMULATIVE_KEY" "$CUTOVER_AT" >/dev/null
  log "5. Warroom guards set ($WARROOM_CUMULATIVE_KEY + $WARROOM_ATTEMPT_KEY)."
fi

log "DONE. Cutover completed at $CUTOVER_AT."
echo "$CUTOVER_AT"  # stdout — capturable for downstream scripts
