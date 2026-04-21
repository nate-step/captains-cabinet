#!/usr/bin/env python3
# cabinet/scripts/cutover/delta-verify.py
# Spec 039 §5.9 Gate 4 Step 0 — delta verification against Gate 1 snapshot.
#
# Two modes:
#   (default)          manual CoS pre-check. Counts Δ; records baseline to Redis.
#   --strict           called by cutover-to-tasks.sh pre-step-1. Requires drift
#                      from baseline ≤ 5 rows (M-β atomic re-check).
#
# Addresses COO preemptive adversary:
#   H-β — filter is `updatedAt > T OR createdAt > T` (belt-and-suspenders on row
#         creation timestamps, even though Linear auto-updates updatedAt on create).
#   M-β — --strict mode ensures drift between manual §1 run and atomic §2 step 1
#         is bounded; aborts if source drifts materially between checks.
#
# Dependencies: requests, PyYAML. (psycopg2 NOT needed; no DB access.)
# Env:
#   LINEAR_API_KEY        any Cabinet service-account key (for GraphQL)
#   GITHUB_PAT            repo:read scope on nate-step/captains-cabinet
#   REDIS_HOST            redis (default)
#   REDIS_PORT            6379 (default)

from __future__ import annotations

import argparse
import logging
import os
import subprocess
import sys
from typing import List, Tuple

import requests

logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("delta-verify")

GATE_1_TS_KEY = "cabinet:migration:039:gate-1-completed-at"
BASELINE_KEY = "cabinet:migration:039:delta-pre-cutover:count"
DRIFT_TOLERANCE = 5  # rows
DELTA_ABORT_THRESHOLD = 20  # rows (per runbook decision matrix)

LINEAR_GRAPHQL = "https://api.linear.app/graphql"
GH_API = "https://api.github.com"
GH_REPO = "nate-step/captains-cabinet"


# ---------------------------------------------------------------------------
# Redis helpers (simple — redis-cli via subprocess, avoids redis-py dep)
# ---------------------------------------------------------------------------

def redis_cli(*args: str) -> str:
    host = os.environ.get("REDIS_HOST", "redis")
    port = os.environ.get("REDIS_PORT", "6379")
    result = subprocess.run(
        ["redis-cli", "-h", host, "-p", port, *args],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def redis_get(key: str) -> str:
    out = redis_cli("GET", key)
    return out if out and out != "(nil)" else ""


def redis_set(key: str, value: str) -> None:
    redis_cli("SET", key, value)


# ---------------------------------------------------------------------------
# Linear delta — H-β: updatedAt OR createdAt filter
# ---------------------------------------------------------------------------

def linear_delta_count(since_iso: str) -> Tuple[int, int]:
    """Return (updated_count, created_count) of Linear issues modified since
    since_iso. Uses `or` filter on updatedAt/createdAt per H-β.

    Returns tuple so caller can log breakdown; total = updated + created.
    Issues that were BOTH created+updated after the cutoff are counted once as
    updated (Linear sets updatedAt=createdAt at create, but we query with OR so
    the same issue matches both; de-dupe by id).
    """
    token = os.environ["LINEAR_API_KEY"]
    headers = {"Authorization": token, "Content-Type": "application/json"}

    # We use a single query with OR filter and de-dupe client-side. Linear's
    # GraphQL `or` filter on issues supports nested clauses.
    # B-3 fix: Linear's scalar is `DateTime` (ISO 8601 string).
    # The `filter.or` construct nests clauses, each a valid IssueFilter.
    query = """
    query DeltaQuery($after: String, $since: DateTime!) {
      issues(
        first: 100
        after: $after
        filter: { or: [ { updatedAt: { gt: $since } }, { createdAt: { gt: $since } } ] }
      ) {
        pageInfo { hasNextPage endCursor }
        nodes { id createdAt updatedAt state { name } identifier }
      }
    }
    """
    ids_updated: set = set()
    ids_created: set = set()
    blocked_new: List[dict] = []
    after = None
    while True:
        variables = {"after": after, "since": since_iso}
        resp = requests.post(
            LINEAR_GRAPHQL,
            headers=headers,
            json={"query": query, "variables": variables},
            timeout=30,
        )
        resp.raise_for_status()
        data = resp.json()
        if "errors" in data:
            raise RuntimeError(f"Linear GraphQL error: {data['errors']}")
        page = data["data"]["issues"]
        for node in page["nodes"]:
            created_at = node["createdAt"]
            updated_at = node["updatedAt"]
            iid = node["id"]
            if created_at > since_iso:
                ids_created.add(iid)
            elif updated_at > since_iso:
                ids_updated.add(iid)
            # H-β assertion — any NEW post-Gate-1 blocker must be flagged
            if (created_at > since_iso) and node["state"]["name"] == "Blocked":
                blocked_new.append(node)
        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]

    if blocked_new:
        # H-1 fix: new post-Gate-1 blocker = load-bearing context that may be lost in
        # cutover. Runbook §1 says "script exits non-zero." Raise here; caller in
        # main() converts to exit code 6.
        log.error(
            "[linear] %d new Blocked rows post-Gate-1 — verify blocked_reason captured pre-cutover:",
            len(blocked_new),
        )
        for b in blocked_new:
            log.error("  %s (%s): created %s", b["identifier"], b["id"], b["createdAt"])
        raise RuntimeError(
            f"{len(blocked_new)} new Blocked rows post-Gate-1; investigate before cutover"
        )

    return len(ids_updated), len(ids_created)


# ---------------------------------------------------------------------------
# GitHub delta — same OR semantics (GH REST has `since` param which is updatedAt)
# ---------------------------------------------------------------------------

def github_delta_count(since_iso: str) -> Tuple[int, int]:
    """Return (updated_count, created_count) of GH issues modified since
    since_iso on nate-step/captains-cabinet.

    GH REST `issues` endpoint's `since` param filters on updated_at. For created
    delta we still cover via the same endpoint since created issues always have
    updated_at >= created_at (GH sets them together at creation). So
    `since=gate_1_timestamp` catches both.
    However, to match H-β's explicit OR semantics, we also check created_at per
    row and split counts for reporting clarity.
    """
    token = os.environ["GITHUB_PAT"]
    headers = {"Authorization": f"token {token}", "Accept": "application/vnd.github+json"}
    url = f"{GH_API}/repos/{GH_REPO}/issues"
    ids_updated: set = set()
    ids_created: set = set()
    params = {"since": since_iso, "state": "all", "per_page": "100"}
    while url:
        resp = requests.get(url, headers=headers, params=params, timeout=30)
        resp.raise_for_status()
        for issue in resp.json():
            if "pull_request" in issue:
                continue  # GH conflates issues + PRs on this endpoint; skip PRs
            iid = issue["id"]
            if issue["created_at"] > since_iso:
                ids_created.add(iid)
            else:
                ids_updated.add(iid)
        # Pagination via Link header
        link = resp.headers.get("Link", "")
        next_url = None
        for part in link.split(","):
            if 'rel="next"' in part:
                next_url = part.split(";")[0].strip().strip("<>")
                break
        url = next_url
        params = None  # subsequent pages have all params in next_url
    return len(ids_updated), len(ids_created)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="Spec 039 Gate 4 Step 0 delta verification")
    ap.add_argument(
        "--strict",
        action="store_true",
        help="Compare against Redis baseline; fail if drift > 5 rows (cutover atomic pre-check)",
    )
    args = ap.parse_args()

    gate_1_iso = redis_get(GATE_1_TS_KEY)
    if not gate_1_iso:
        log.error(
            "Gate 1 timestamp missing from Redis (key %s). Run Gate 1 first (wet-run runbook).",
            GATE_1_TS_KEY,
        )
        return 2
    log.info("Gate 1 timestamp: %s", gate_1_iso)

    try:
        linear_u, linear_c = linear_delta_count(gate_1_iso)
        gh_u, gh_c = github_delta_count(gate_1_iso)
    except requests.RequestException as e:
        log.error("Source API error: %s", e)
        return 3
    except RuntimeError as e:
        # H-1: new-Blocked-row RuntimeError from linear_delta_count.
        log.error("New-blocker assertion failed: %s", e)
        return 6

    linear_total = linear_u + linear_c
    gh_total = gh_u + gh_c
    delta_total = linear_total + gh_total

    log.info("Linear delta: %d rows (updated=%d, created=%d)", linear_total, linear_u, linear_c)
    log.info("GH delta:     %d rows (updated=%d, created=%d)", gh_total, gh_u, gh_c)
    log.info("TOTAL Δ = %d", delta_total)

    # Strict mode (cutover atomic pre-step-1 re-check)
    if args.strict:
        baseline_str = redis_get(BASELINE_KEY)
        if not baseline_str:
            log.error(
                "Strict mode requires baseline at %s; run delta-verify.py without --strict first.",
                BASELINE_KEY,
            )
            return 4
        baseline = int(baseline_str)
        drift = abs(delta_total - baseline)
        log.info("Baseline delta: %d; current: %d; drift: %d", baseline, delta_total, drift)
        if drift > DRIFT_TOLERANCE:
            log.error(
                "Drift %d > tolerance %d — source drifted materially between manual check and cutover. ABORT.",
                drift, DRIFT_TOLERANCE,
            )
            return 5
        log.info("Drift %d ≤ %d — within tolerance, proceed.", drift, DRIFT_TOLERANCE)
        return 0

    # Default mode — apply decision matrix.
    # H-2 fix: baseline ONLY recorded on PROCEED/PAUSE outcomes. If we record on
    # ABORT, the next manual re-run would compare a fresh Δ against the poisoned
    # baseline and could pass --strict with a misleading "drift=0" signal.
    print()
    if delta_total <= DRIFT_TOLERANCE:
        redis_set(BASELINE_KEY, str(delta_total))
        log.info("Baseline recorded at %s: %d", BASELINE_KEY, delta_total)
        print(f"Decision: Δ = {delta_total} ≤ {DRIFT_TOLERANCE} → PROCEED to cutover-to-tasks.sh.")
        return 0
    if delta_total <= DELTA_ABORT_THRESHOLD:
        redis_set(BASELINE_KEY, str(delta_total))
        log.info("Baseline recorded at %s: %d", BASELINE_KEY, delta_total)
        print(
            f"Decision: {DRIFT_TOLERANCE} < Δ = {delta_total} ≤ {DELTA_ABORT_THRESHOLD} — "
            f"PAUSE. CoS triggers affected-officer spot-check, then re-run delta-verify.py."
        )
        return 1
    # ABORT path — do NOT record baseline. Re-run Gates 1-3 on fresh snapshot.
    log.warning(
        "Δ = %d exceeds abort threshold %d; baseline NOT recorded (H-2).",
        delta_total, DELTA_ABORT_THRESHOLD,
    )
    print(
        f"Decision: Δ = {delta_total} > {DELTA_ABORT_THRESHOLD} — ABORT. "
        f"Source drifted materially since Gate 1; re-run Gates 1-3 on fresh snapshot."
    )
    return 2


if __name__ == "__main__":
    sys.exit(main())
