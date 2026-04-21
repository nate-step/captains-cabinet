#!/usr/bin/env python3
# cabinet/scripts/cutover/linear-freeze.py
# Spec 039 §5.9 Gate 4 Step 2 — Linear write-freeze.
#
# Two phases, IN STRICT ORDER:
#   Phase 2a — demote ALL service-account members to Viewer on every team.
#   Phase 2b — revoke ALL service-account API keys.
#
# Addresses COO preemptive adversary:
#   H-α — Phase 2a completes for ALL members BEFORE Phase 2b starts. If the
#         API key used to call teamMembershipUpdate is one of the keys being
#         revoked, revoking it mid-loop would break subsequent demotes. Explicit
#         pre-revoke assertion `all_svc_members_demoted == True`.
#   H-γ — service-account enumeration derived from officer-emails.yml at runtime
#         (not hardcoded); Captain explicitly excluded via assert_captain_excluded.
#   M-δ — 429 rate-limit handling: honor Retry-After header, 2s floor, 60s cap,
#         max 3 retries per call before raising.
#
# Addresses COO post-impl adversary + self-spawned Sonnet review:
#   N-M-γ / B-2 — teamMembershipUpdate mutation shape is NOT stable across Linear
#         API versions. verify_mutation_shape() introspects Team/TeamMembership/
#         TeamMembershipUpdateInput and fails fast if required fields missing.
#         Runs in both normal mode AND `--verify-schema` mode.
#   B-2 — team.members returns User (no membership.id); switched to
#         team.memberships so we carry TeamMembership ids for the mutation.
#
# Dependencies: requests.
# Env:
#   LINEAR_API_KEY                     key used to call teamMembershipUpdate
#                                      (MUST correspond to a workspace-admin
#                                      account; MUST be among the revoked keys
#                                      but revoked LAST — see Phase 2b)
#   LINEAR_API_KEYS_TO_REVOKE          space-separated list of env-var names
#                                      holding keys to revoke (e.g.
#                                      "LINEAR_API_KEY_COS LINEAR_API_KEY_CTO ...")

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from pathlib import Path
from typing import List, Optional

import requests

# Reuse enumeration + assertion helpers
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from service_accounts import (  # noqa: E402
    assert_captain_excluded,
    enumerate_linear_demotion_targets,
)

logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("linear-freeze")

LINEAR_GRAPHQL = "https://api.linear.app/graphql"
RETRY_FLOOR_SEC = 2
RETRY_CAP_SEC = 60
MAX_RETRIES = 3


def _post_with_429(query: str, variables: dict, headers: dict) -> dict:
    """POST to Linear with M-δ 429 backoff. Honor Retry-After."""
    for attempt in range(MAX_RETRIES + 1):
        resp = requests.post(
            LINEAR_GRAPHQL,
            headers=headers,
            json={"query": query, "variables": variables},
            timeout=30,
        )
        if resp.status_code != 429:
            resp.raise_for_status()
            data = resp.json()
            if "errors" in data:
                raise RuntimeError(f"Linear error: {data['errors']}")
            return data
        if attempt == MAX_RETRIES:
            resp.raise_for_status()
        retry_after = resp.headers.get("Retry-After")
        wait = RETRY_FLOOR_SEC
        if retry_after:
            try:
                wait = max(RETRY_FLOOR_SEC, min(int(retry_after), RETRY_CAP_SEC))
            except ValueError:
                pass  # non-int Retry-After (rare); use floor
        log.warning("[linear] 429 rate-limited (attempt %d/%d); sleeping %ds", attempt + 1, MAX_RETRIES, wait)
        time.sleep(wait)
    raise RuntimeError("unreachable")


# ---------------------------------------------------------------------------
# Schema introspection (N-M-γ / B-2 fix).
# Linear's teamMembershipUpdate + TeamMembershipUpdateInput shape is NOT stable
# across API versions; COO adversary + self-spawned Sonnet flagged it as
# unverified. Before any mutation call we introspect the schema and fail fast
# if the expected fields don't exist. `--verify-schema` runs introspection then
# exits without mutating — operator runs it pre-cutover to validate.
# ---------------------------------------------------------------------------

VIEWER_ROLE = "Viewer"  # Linear role enum — tentative; verified via introspection.


def _introspect_type(type_name: str, headers: dict) -> Optional[dict]:
    """Fetch the GraphQL type definition for `type_name`, or None if missing."""
    query = """
    query Introspect($name: String!) {
      __type(name: $name) {
        name
        kind
        fields { name type { name kind ofType { name kind } } }
        inputFields { name type { name kind ofType { name kind } } }
        enumValues { name }
      }
    }
    """
    data = _post_with_429(query, {"name": type_name}, headers)
    return data.get("data", {}).get("__type")


def verify_mutation_shape(headers: dict, *, verbose: bool = False) -> dict:
    """Introspect + verify the Linear types we depend on. Returns a report dict.

    Aborts (raises RuntimeError) if any required field is missing. Called from
    both `--verify-schema` mode AND at the top of main() before any mutation.
    """
    report: dict = {"verified": [], "warnings": [], "errors": []}

    # 1. Team type must expose `memberships` (NOT just `members` — `members` is
    #    a User connection, which doesn't give us the membership.id needed for
    #    teamMembershipUpdate's positional `id` arg. B-2 / Sonnet finding.)
    team_type = _introspect_type("Team", headers)
    if not team_type:
        report["errors"].append("Team type not found in schema")
    else:
        field_names = {f["name"] for f in (team_type.get("fields") or [])}
        if "memberships" not in field_names:
            report["errors"].append(
                "Team.memberships field missing — cannot enumerate TeamMembership IDs"
            )
        else:
            report["verified"].append("Team.memberships exists")
        if "members" in field_names and verbose:
            report["warnings"].append(
                "Team.members also exists (returns User, NOT TeamMembership — do not use)"
            )

    # 2. TeamMembership must have `id` and `user { email }` so we can filter.
    tm_type = _introspect_type("TeamMembership", headers)
    if not tm_type:
        report["errors"].append("TeamMembership type not found in schema")
    else:
        field_names = {f["name"] for f in (tm_type.get("fields") or [])}
        for req in ("id", "user"):
            if req not in field_names:
                report["errors"].append(f"TeamMembership.{req} missing")
            else:
                report["verified"].append(f"TeamMembership.{req} exists")

    # 3. TeamMembershipUpdateInput must expose a role (or equivalent) field.
    #    If it does not, the demote-to-Viewer approach is wrong at this scope
    #    and we need workspace-level userUpdateAdmin (or similar). Fail fast.
    input_type = _introspect_type("TeamMembershipUpdateInput", headers)
    if not input_type:
        report["errors"].append(
            "TeamMembershipUpdateInput type not found — mutation path invalid"
        )
    else:
        input_field_names = {f["name"] for f in (input_type.get("inputFields") or [])}
        report["verified"].append(
            f"TeamMembershipUpdateInput fields: {sorted(input_field_names)}"
        )
        if "role" not in input_field_names:
            # Most likely cause: role lives at workspace scope, not team scope.
            report["errors"].append(
                "TeamMembershipUpdateInput.role MISSING — demote-to-Viewer cannot be "
                "done via teamMembershipUpdate. Likely need workspace-level mutation "
                "(e.g. organizationUpdate member role). ABORT before Phase 2a."
            )
        else:
            report["verified"].append("TeamMembershipUpdateInput.role exists")

    if verbose:
        print(json.dumps(report, indent=2))

    if report["errors"]:
        msg = "Schema verification FAILED:\n  " + "\n  ".join(report["errors"])
        raise RuntimeError(msg)
    return report


# ---------------------------------------------------------------------------
# Phase 2a — Demote all service-account members to Viewer on every team.
# ---------------------------------------------------------------------------

def _list_teams(headers: dict) -> List[dict]:
    query = """query { teams(first: 50) { nodes { id name key } } }"""
    data = _post_with_429(query, {}, headers)
    return data["data"]["teams"]["nodes"]


def _list_team_memberships(team_id: str, headers: dict) -> List[dict]:
    """Return TeamMembership nodes (NOT User nodes) for the team.

    B-2 fix: `team.members` returns User (no membership.id), but
    `teamMembershipUpdate(id: ...)` wants the TeamMembership id — so we query
    `team.memberships` and carry user.email alongside membership.id.
    """
    query = """
    query TM($teamId: String!, $after: String) {
      team(id: $teamId) {
        memberships(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id
            user { id email name }
          }
        }
      }
    }
    """
    memberships = []
    after = None
    while True:
        data = _post_with_429(query, {"teamId": team_id, "after": after}, headers)
        page = data["data"]["team"]["memberships"]
        memberships.extend(page["nodes"])
        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]
    return memberships


def _demote_member(membership_id: str, headers: dict) -> bool:
    """Demote one TeamMembership to Viewer. Returns True on success.

    Idempotent — already-Viewer returns success=true per §5.9 M-4.
    """
    query = """
    mutation Demote($id: String!) {
      teamMembershipUpdate(id: $id, input: { role: Viewer })
      { success }
    }
    """
    data = _post_with_429(query, {"id": membership_id}, headers)
    return bool(data["data"]["teamMembershipUpdate"]["success"])


def phase_2a_demote_members(headers: dict, service_accounts: List[str]) -> bool:
    """Phase 2a — demote every service-account membership on every team.

    Returns True if ALL demotes succeeded; raises on any failure so H-α's
    pre-revoke assertion `all_svc_members_demoted == True` is enforceable.
    """
    log.info("[2a] Enumerating teams + service-account memberships...")
    teams = _list_teams(headers)
    log.info("[2a] Found %d teams: %s", len(teams), [t["key"] for t in teams])

    total_demotes = 0
    for team in teams:
        memberships = _list_team_memberships(team["id"], headers)
        # Filter by user.email (carried from the nested user selection)
        team_svc_memberships = [
            m for m in memberships
            if m.get("user", {}).get("email") in service_accounts
        ]
        log.info(
            "[2a] Team %s: %d service-account memberships to demote",
            team["key"],
            len(team_svc_memberships),
        )
        for m in team_svc_memberships:
            email = m["user"]["email"]
            membership_id = m["id"]
            ok = _demote_member(membership_id, headers)
            if not ok:
                raise RuntimeError(
                    f"[2a] teamMembershipUpdate returned success=False for "
                    f"{email} on {team['key']} — abort before Phase 2b."
                )
            log.info("[2a] ✓ %s demoted on %s (Viewer)", email, team["key"])
            total_demotes += 1
    log.info("[2a] DONE — %d demote calls across %d teams.", total_demotes, len(teams))
    return True


# ---------------------------------------------------------------------------
# Phase 2b — Revoke all service-account API keys.
# Linear has no direct API-key-revoke mutation in the public GraphQL; revocation
# happens via Settings → API → click Revoke. This step is SEMI-MANUAL:
#   - The script surfaces the list of keys that must be revoked.
#   - Operator revokes via Linear UI.
#   - Script pauses for operator confirmation, then verifies revocation by
#     making a trivial call with each key and asserting 401.
# H-α ordering: operator-key (LINEAR_API_KEY used by this script) is
# intentionally the last key marked for revocation so the script can complete
# Phase 2a without self-lockout.
# ---------------------------------------------------------------------------

def _verify_key_revoked(key: str) -> bool:
    """Return True iff the key has been revoked (401/403 response)."""
    headers = {"Authorization": key, "Content-Type": "application/json"}
    resp = requests.post(
        LINEAR_GRAPHQL,
        headers=headers,
        json={"query": "query { viewer { id } }"},
        timeout=15,
    )
    if resp.status_code in (401, 403):
        return True
    # 200 with valid viewer means still live
    try:
        data = resp.json()
        if "data" in data and data["data"].get("viewer", {}).get("id"):
            return False
    except Exception:
        pass
    # Conservative — non-200 non-auth-error → treat as unknown, fail closed
    return False


def phase_2b_revoke_keys(operator_key_env_name: str) -> None:
    """Phase 2b — operator-driven key revocation via Linear UI.

    Prints the list of keys to revoke. Operator revokes via UI. Script pauses
    and then verifies each key returns 401 on a trivial API call.

    H-α: operator's key (LINEAR_API_KEY) is listed LAST in the to-revoke set
    so the operator completes Phase 2a first, then revokes non-operator keys,
    then revokes the operator key as the final step.
    """
    keys_env = os.environ.get("LINEAR_API_KEYS_TO_REVOKE", "").split()
    if not keys_env:
        log.error("[2b] LINEAR_API_KEYS_TO_REVOKE env var empty — specify env-var names to revoke.")
        raise RuntimeError("no keys to revoke")

    # Sort: operator key LAST
    keys_env_sorted = [k for k in keys_env if k != operator_key_env_name] + (
        [operator_key_env_name] if operator_key_env_name in keys_env else []
    )

    print()
    print("=" * 60)
    print("[2b] MANUAL STEP — revoke these Linear API keys via Settings > API:")
    print("=" * 60)
    for i, env_name in enumerate(keys_env_sorted, 1):
        val = os.environ.get(env_name, "")
        suffix = val[-4:] if val else "(not set)"
        marker = " ← OPERATOR KEY (revoke LAST)" if env_name == operator_key_env_name else ""
        print(f"  {i}. {env_name} (...{suffix}){marker}")
    print("=" * 60)
    print()
    input("Press ENTER after all keys above have been revoked in Linear UI...")

    # Post-revocation verification
    log.info("[2b] Verifying revocations...")
    failures = []
    for env_name in keys_env_sorted:
        val = os.environ.get(env_name, "")
        if not val:
            # COO LOW polish: fail-closed. A typo'd env name in LINEAR_API_KEYS_TO_REVOKE
            # would otherwise silently skip revocation — named key stays LIVE post-freeze
            # while cutover reports clean. Treat unset env as a verification failure so
            # the operator must fix the config before proceeding.
            log.error("[2b] ✗ %s not set in env — cannot verify; treating as unrevoked (fail-closed)", env_name)
            failures.append(env_name)
            continue
        if _verify_key_revoked(val):
            log.info("[2b] ✓ %s revoked (confirmed 401/403)", env_name)
        else:
            log.error("[2b] ✗ %s still LIVE — revoke in Linear UI before continuing", env_name)
            failures.append(env_name)
    if failures:
        raise RuntimeError(f"keys still live after operator-claimed revocation: {failures}")
    log.info("[2b] DONE — all %d keys verified revoked.", len(keys_env_sorted))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="Spec 039 Gate 4 Step 2 — Linear write-freeze")
    ap.add_argument(
        "--verify-schema",
        action="store_true",
        help="N-M-γ/B-2: introspect Linear schema + verify teamMembershipUpdate mutation "
             "shape, then exit WITHOUT mutating. The same verification also runs unconditionally "
             "at the top of normal-mode main() — this flag just short-circuits before mutations "
             "so the operator can check the schema pre-cutover without risk.",
    )
    args = ap.parse_args()

    log.info("=" * 50)
    log.info("Spec 039 Gate 4 Step 2 — Linear write-freeze%s",
             " (SCHEMA VERIFY ONLY)" if args.verify_schema else "")
    log.info("=" * 50)

    operator_key = os.environ.get("LINEAR_API_KEY")
    if not operator_key:
        log.error("LINEAR_API_KEY env var not set — cannot make Linear calls.")
        return 2
    headers = {"Authorization": operator_key, "Content-Type": "application/json"}

    # Mandatory schema verification — runs in BOTH modes. Cheap (3 introspection
    # calls) and fails fast if the mutation shape has drifted since impl.
    try:
        verify_mutation_shape(headers, verbose=args.verify_schema)
    except RuntimeError as e:
        log.error("[N-M-γ] %s", e)
        return 4
    log.info("[N-M-γ] Schema verified ✓")

    if args.verify_schema:
        log.info("Schema-verify mode: not mutating. Exiting 0.")
        return 0

    # H-γ enumeration + Captain-exclusion assertion
    service_accounts, captain_emails = enumerate_linear_demotion_targets()
    log.info("Service-account emails: %s", service_accounts)
    log.info("Captain emails (EXCLUDED): %s", captain_emails)
    assert_captain_excluded(service_accounts, captain_emails, "linear")

    # Phase 2a
    all_svc_members_demoted = phase_2a_demote_members(headers, service_accounts)

    # H-α assertion — belt-and-suspenders on the phase_2a contract
    if not all_svc_members_demoted:
        log.error("[H-α] all_svc_members_demoted == False — abort before Phase 2b.")
        return 3
    log.info("[H-α] all_svc_members_demoted == True ✓")

    # Phase 2b
    operator_key_env_name = os.environ.get("LINEAR_OPERATOR_KEY_ENV", "LINEAR_API_KEY_CTO")
    phase_2b_revoke_keys(operator_key_env_name)

    log.info("Step 2 (Linear write-freeze) complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
