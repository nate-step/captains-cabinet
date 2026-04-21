# cabinet/scripts/cutover/lib/service_accounts.py
# Spec 039 §5.9 Gate 4 Step 2/3 — derive Cabinet service-account enumeration
# from instance/config/officer-emails.yml. Addresses COO preemptive adversary
# H-γ: Captain MUST be excluded from any demotion/revoke target list.

from __future__ import annotations

import sys
from pathlib import Path
from typing import Dict, List, Tuple

# Reuse etl-common loader — single source of truth for officer-emails.yml parsing.
# etl-common.py has a hyphen → can't plain-import; use importlib.
_THIS = Path(__file__).resolve()
_ETL_COMMON = _THIS.parents[2] / "lib" / "etl-common.py"  # cabinet/scripts/lib/etl-common.py
import importlib.util as _ilu  # noqa: E402
_spec = _ilu.spec_from_file_location("etl_common_cutover", _ETL_COMMON)
_etl = _ilu.module_from_spec(_spec)  # type: ignore[arg-type]
_spec.loader.exec_module(_etl)  # type: ignore[union-attr]
load_officer_emails = _etl.load_officer_emails


def enumerate_linear_demotion_targets() -> Tuple[List[str], List[str]]:
    """Return (service_account_emails, captain_emails) from officer-emails.yml.

    Linear member-demotion loop targets service_account_emails.
    captain_emails MUST NOT appear in the demotion list — Captain retains
    workspace admin post-cutover for archival access.
    """
    mapping = load_officer_emails()
    emails = mapping["emails"]
    service_accounts = sorted(e for e, slug in emails.items() if slug != "captain")
    captain_emails = sorted(e for e, slug in emails.items() if slug == "captain")
    return service_accounts, captain_emails


def enumerate_gh_demotion_targets() -> Tuple[List[str], List[str]]:
    """Return (bot_logins, captain_logins) from officer-emails.yml.

    GH Issues write-disable step demotes bot_logins to 'read' permission.
    captain_logins retain 'admin' for archival access.
    """
    mapping = load_officer_emails()
    logins = mapping["github_logins"]
    bots = sorted(login for login, slug in logins.items() if slug != "captain")
    captains = sorted(login for login, slug in logins.items() if slug == "captain")
    return bots, captains


def assert_captain_excluded(
    demotion_targets: List[str],
    captain_identities: List[str],
    context: str,
) -> None:
    """Raises AssertionError if any Captain identifier appears in the target list."""
    for ci in captain_identities:
        if ci in demotion_targets:
            raise AssertionError(
                f"[service-accounts] Captain identity {ci!r} in {context} demotion list — abort."
            )


if __name__ == "__main__":
    # Manual verification — prints the current enumeration so operator can eyeball pre-cutover.
    linear_svc, linear_cap = enumerate_linear_demotion_targets()
    gh_bots, gh_cap = enumerate_gh_demotion_targets()
    print("Linear service-account emails (demotion targets):")
    for e in linear_svc:
        print(f"  {e}")
    print(f"Linear Captain emails (EXCLUDED): {linear_cap}")
    print()
    print("GitHub bot logins (demotion targets):")
    for login in gh_bots:
        print(f"  {login}")
    print(f"GitHub Captain logins (EXCLUDED): {gh_cap}")
    print()
    assert_captain_excluded(linear_svc, linear_cap, "linear")
    assert_captain_excluded(gh_bots, gh_cap, "gh")
    print("OK — Captain excluded from both Linear + GH demotion lists.")
