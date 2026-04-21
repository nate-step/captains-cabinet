#!/usr/bin/env python3
# cabinet/scripts/cutover/gh-freeze.py
# Spec 039 §5.9 Gate 4 Step 3 — GitHub Issues write-disable on
# nate-step/captains-cabinet.
#
# Mechanism decision (per COO adversary M-α):
#   Option 3 — PATCH /repos/{owner}/{repo}/collaborators/{username} with
#              {"permission":"read"} to demote Cabinet bots from write → read.
#
#   Options rejected:
#     - has_issues: false    → disables Issues for ALL users; kills archival
#                              access; returns 404 not 403 (violates AC #37a).
#     - team-role revocation → bot accounts may hold PATs with independent perms;
#                              repo-level collaborator perms are authoritative.
#
# Addresses COO preemptive adversary:
#   H-γ — bot-login enumeration derived from officer-emails.yml (same source of
#         truth as Linear side); Captain login excluded via assert_captain_excluded.
#
# Dependencies: requests.
# Env:
#   GITHUB_PAT_ADMIN    PAT with repo-admin scope on nate-step/captains-cabinet
#                       (Captain's PAT — script is run with admin context).
#                       Bot PATs cannot demote themselves.

from __future__ import annotations

import logging
import os
import sys
from pathlib import Path
from typing import List

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from service_accounts import (  # noqa: E402
    assert_captain_excluded,
    enumerate_gh_demotion_targets,
)

logging.basicConfig(
    stream=sys.stderr,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("gh-freeze")

GH_API = "https://api.github.com"
GH_REPO = "nate-step/captains-cabinet"  # owner/name


def _demote_collaborator(username: str, token: str) -> None:
    """PATCH collaborator to read permission. Idempotent — same permission is no-op."""
    url = f"{GH_API}/repos/{GH_REPO}/collaborators/{username}"
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    resp = requests.put(  # GitHub uses PUT for add/update collaborator
        url,
        headers=headers,
        json={"permission": "read"},
        timeout=30,
    )
    # 204 = updated (no content) — HAPPY PATH for an existing collaborator being demoted.
    # 201 = invitation created (user was NOT a collaborator; this call invited them).
    #       M-2 fix: we expect all Cabinet bots to already be collaborators — a 201
    #       means enumeration drifted (bot listed in officer-emails.yml but not
    #       added to repo) or a prior manual removal. Do NOT claim success:
    #         - log a loud warning
    #         - require operator re-verify via /collaborators/{user}/permission
    #         - the main loop's post-demote verify will fail this row (invite
    #           pending != permission=read), aborting cutover.
    # 404 = user not a collaborator AND the PUT did not create an invite — log + continue.
    if resp.status_code == 404:
        log.warning("[gh] %s not a collaborator on %s — skipping", username, GH_REPO)
        return
    if resp.status_code == 201:
        log.warning(
            "[gh] %s returned 201 — invitation created (was NOT a pre-existing collaborator). "
            "Enumeration drift or manual removal upstream. Post-demote verify will catch this "
            "and abort; investigate officer-emails.yml vs. actual repo collaborators.",
            username,
        )
        return  # fall through to post-demote verify; caller will see non-'read' permission
    if resp.status_code != 204:
        log.error(
            "[gh] demote %s failed: HTTP %d — %s",
            username, resp.status_code, resp.text[:200],
        )
        resp.raise_for_status()


def _verify_collaborator_permission(username: str, token: str) -> str:
    """Return the collaborator's permission string ('read'|'triage'|'write'|'maintain'|'admin')."""
    url = f"{GH_API}/repos/{GH_REPO}/collaborators/{username}/permission"
    headers = {
        "Authorization": f"token {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    resp = requests.get(url, headers=headers, timeout=15)
    if resp.status_code != 200:
        return f"error-{resp.status_code}"
    return resp.json().get("permission", "unknown")


def main() -> int:
    log.info("=" * 50)
    log.info("Spec 039 Gate 4 Step 3 — GH Issues write-disable")
    log.info("=" * 50)

    admin_token = os.environ.get("GITHUB_PAT_ADMIN") or os.environ.get("GITHUB_PAT")
    if not admin_token:
        log.error("Neither GITHUB_PAT_ADMIN nor GITHUB_PAT set — cannot PATCH collaborators.")
        return 2

    # H-γ enumeration + Captain-exclusion
    bots, captain_logins = enumerate_gh_demotion_targets()
    log.info("Bot logins to demote: %s", bots)
    log.info("Captain logins (EXCLUDED — retain admin): %s", captain_logins)
    assert_captain_excluded(bots, captain_logins, "gh")

    # Demote
    for bot in bots:
        log.info("[gh] Demoting %s to read on %s", bot, GH_REPO)
        _demote_collaborator(bot, admin_token)
        # Post-demote verify
        perm = _verify_collaborator_permission(bot, admin_token)
        if perm == "read":
            log.info("[gh] ✓ %s now at permission=read", bot)
        else:
            log.error("[gh] ✗ %s permission=%s (expected read) — investigate", bot, perm)
            return 3

    # Capture Captain's permission post-step-3 for audit trail (should still be admin)
    for cap in captain_logins:
        perm = _verify_collaborator_permission(cap, admin_token)
        log.info("[gh] Captain %s permission=%s (expected admin — retained for archival)", cap, perm)

    log.info("Step 3 (GH Issues write-disable) complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
