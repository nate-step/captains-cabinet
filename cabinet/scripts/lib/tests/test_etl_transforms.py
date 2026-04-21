"""FW-023 — ETL pure-transform tests.

Covers:
  * etl-linear `_map_state` — all 5 Linear fixtures (queue / wip+blocked /
    done / cancelled / captain-decision).
  * etl-github `_map_status` — AC #52 mapping grid: open / closed+completed /
    closed+not_planned (cancelled) / closed+None (default → done).
  * etl-github `_extract_fw_marker` — positive, trailing-content (H1 regression),
    absent, empty-body.
  * etl-github `_extract_priority` — positive, absent, case-insensitive.
  * Label parity — captain-decision label presence on both Linear + GH fixtures.

Runs two ways:
    python3 -m pytest cabinet/scripts/lib/tests/       # FW-024 path
    python3 cabinet/scripts/lib/tests/test_etl_transforms.py   # works today
"""
from __future__ import annotations

import sys
import types
from pathlib import Path

for _mod in ("requests", "yaml"):
    if _mod not in sys.modules:
        sys.modules[_mod] = types.ModuleType(_mod)

_LIB_DIR = Path(__file__).parent.parent.resolve()
if str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))

import importlib.util as _ilu


def _load(modname: str, relpath: str):
    spec = _ilu.spec_from_file_location(modname, _LIB_DIR / relpath)
    mod = _ilu.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(mod)  # type: ignore[union-attr]
    return mod


etl_linear = _load("etl_linear", "etl-linear.py")
etl_github = _load("etl_github", "etl-github.py")

import test_etl_fixtures as fx  # no hyphens, importable directly


# ---------------------------------------------------------------------------
# Linear _map_state
# ---------------------------------------------------------------------------

def test_map_state_queue_backlog():
    status, blocked, reason = etl_linear._map_state(fx.LINEAR_ISSUE_QUEUE["state"])
    assert status == "queue"
    assert blocked is False
    assert reason is None


def test_map_state_wip_blocked():
    status, blocked, reason = etl_linear._map_state(fx.LINEAR_ISSUE_WIP_BLOCKED["state"])
    assert status == "wip"
    assert blocked is True
    assert reason == "Blocked"


def test_map_state_done():
    status, blocked, reason = etl_linear._map_state(fx.LINEAR_ISSUE_DONE["state"])
    assert status == "done"
    assert blocked is False
    assert reason is None


def test_map_state_cancelled():
    status, blocked, reason = etl_linear._map_state(fx.LINEAR_ISSUE_CANCELLED["state"])
    assert status == "cancelled"
    assert blocked is False
    assert reason is None


def test_map_state_captain_decision_in_progress():
    # CAPTAIN_DECISION fixture: state.name="In Progress", type="started"
    # → wip (via _STATE_TYPE_MAP["started"]), blocked=False.
    status, blocked, reason = etl_linear._map_state(
        fx.LINEAR_ISSUE_CAPTAIN_DECISION["state"]
    )
    assert status == "wip"
    assert blocked is False
    assert reason is None


def test_map_state_started_non_in_progress_routes_to_queue():
    # Regression: Spec 038 §4.5 — type=started with name != "In Progress"
    # and not blocked → queue (intermediate workflow bucket like "Review").
    state = {"name": "In Review", "type": "started"}
    status, blocked, reason = etl_linear._map_state(state)
    assert status == "queue"
    assert blocked is False
    assert reason is None


def test_map_state_on_hold_wip_blocked():
    # "On Hold" is the other _BLOCKED_NAMES entry alongside "Blocked".
    state = {"name": "On Hold", "type": "started"}
    status, blocked, reason = etl_linear._map_state(state)
    assert status == "wip"
    assert blocked is True
    assert reason == "On Hold"


# ---------------------------------------------------------------------------
# GH _map_status — AC #52 grid
# ---------------------------------------------------------------------------

def test_map_status_open():
    assert etl_github._map_status("open", None) == ("queue", None)


def test_map_status_closed_completed():
    assert etl_github._map_status("closed", "completed") == ("done", "closed_at")


def test_map_status_closed_not_planned():
    # AC #52: not_planned → cancelled with cancelled_at sourced from closed_at.
    assert etl_github._map_status("closed", "not_planned") == ("cancelled", "closed_at")


def test_map_status_closed_none_defaults_to_done():
    assert etl_github._map_status("closed", None) == ("done", "closed_at")


# ---------------------------------------------------------------------------
# GH _extract_fw_marker — H1 regression + happy-paths
# ---------------------------------------------------------------------------

def test_extract_fw_marker_positive():
    assert etl_github._extract_fw_marker(fx.GH_ISSUE_FW_MARKED["body"]) == "FW-024"


def test_extract_fw_marker_trailing_content():
    # Adversarial H1: pre-fix regex was full-line anchored and dropped
    # 'FW-039: title'; post-fix uses `\b` so trailing content is fine.
    assert etl_github._extract_fw_marker("FW-039: ship it\n\ndetails") == "FW-039"


def test_extract_fw_marker_absent_body():
    assert etl_github._extract_fw_marker(fx.GH_ISSUE_NO_FW_MARKER["body"]) is None


def test_extract_fw_marker_empty_and_none():
    assert etl_github._extract_fw_marker(None) is None
    assert etl_github._extract_fw_marker("") is None


def test_extract_fw_marker_mid_line_rejected():
    # Regex is `(?m)^(FW-\d+)\b` — markers MUST start at line beginning.
    # Guards against someone loosening the `^` anchor thinking it's a bug.
    assert etl_github._extract_fw_marker("See FW-024 for details") is None
    assert etl_github._extract_fw_marker("preamble\n  FW-024 indented") is None


def test_extract_fw_marker_closed_not_planned_fixture():
    # The new AC-#52 fixture carries a valid FW-013 marker.
    assert etl_github._extract_fw_marker(fx.GH_ISSUE_CLOSED_NOT_PLANNED["body"]) == "FW-013"


# ---------------------------------------------------------------------------
# GH _extract_priority
# ---------------------------------------------------------------------------

def test_extract_priority_positive():
    assert etl_github._extract_priority(["priority-p0"]) == "P0"
    assert etl_github._extract_priority(["other", "priority-p2"]) == "P2"


def test_extract_priority_absent():
    assert etl_github._extract_priority(["bug", "framework"]) is None


def test_extract_priority_case_insensitive():
    assert etl_github._extract_priority(["Priority-P1"]) == "P1"


# ---------------------------------------------------------------------------
# Captain-decision label parity (fixture-gap b, both sources)
# ---------------------------------------------------------------------------

def test_linear_captain_decision_label_on_fixture():
    names = [n["name"] for n in fx.LINEAR_ISSUE_CAPTAIN_DECISION["labels"]["nodes"]]
    assert "captain-decision" in names


def test_gh_captain_decision_label_on_fixture():
    names = [l["name"] for l in fx.GH_ISSUE_CAPTAIN_DECISION["labels"]]
    assert "captain-decision" in names


def test_linear_queue_fixture_no_captain_decision():
    names = [n["name"] for n in fx.LINEAR_ISSUE_QUEUE["labels"]["nodes"]]
    assert "captain-decision" not in names


def test_gh_fw_marked_fixture_no_captain_decision():
    names = [l["name"] for l in fx.GH_ISSUE_FW_MARKED["labels"]]
    assert "captain-decision" not in names


# ---------------------------------------------------------------------------
# Standalone runner (no pytest required)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import traceback

    tests = [
        (name, fn)
        for name, fn in globals().items()
        if name.startswith("test_") and callable(fn)
    ]
    passed = 0
    failed = 0
    for name, fn in tests:
        try:
            fn()
            passed += 1
            print(f"  ok   {name}")
        except AssertionError as e:
            failed += 1
            print(f"  FAIL {name}: {e!r}")
            traceback.print_exc()
        except Exception as e:
            failed += 1
            print(f"  ERR  {name}: {e!r}")
            traceback.print_exc()
    print(f"\n{passed} passed, {failed} failed (total {len(tests)})")
    sys.exit(1 if failed else 0)
