#!/usr/bin/env python3
# cabinet/scripts/gates/tests/test_gate_3_hash.py — FW-021
#
# Drift-proof fixture for Spec 039 §5.9 M-5 Gate 3 idempotency hash.
#
# Adversary review of PR-3 caught an earlier draft of _HASH_COLS with missing
# cols + wrong algorithm. No test asserted that Python's hash output matched
# the spec. This test pins three invariants:
#   1. _HASH_COLS contains exactly the 15 spec-listed columns in spec order.
#   2. The Python hash of a canned fully-spec'd row equals a golden hexdigest.
#   3. None values are skipped (concat_ws parity), not stringified as 'None'.
#
# Any drift in _HASH_COLS, the str-conversion, the join char, or the md5 of
# the encoded body will flip at least one assertion. The golden hex may be
# regenerated ONLY after amending Spec 039 §5.9 M-5; the two must move in
# lockstep (both guarded by this test's docstrings).
#
# SCOPE — what this test does NOT cover:
#   * Python ↔ Postgres type-coercion parity. The canned row's booleans use
#     Python's `str(False)` → `"False"` convention. Postgres `concat_ws` on
#     a bool column produces `"t"`/`"f"` or `"true"`/`"false"` (cast-path
#     dependent) — DIFFERENT strings, different md5. Gate 3 today is Python-
#     side only (see _fetch_row_hashes), so this divergence is latent. If
#     future work adds a Postgres-side hash (e.g. an integrity CTE that
#     recomputes hashes in SQL), this test does NOT guard the parity — both
#     paths would need explicit coercion shims AND a cross-language golden
#     fixture. See _fetch_row_hashes docstring in gate-3-idempotency.py for
#     the full list of divergence points (booleans, dates, integers).
#   * psycopg2 adapter-specific behavior. The stub in this file (see below)
#     means we never exercise real row fetching.
#
# Run modes:
#   python3 cabinet/scripts/gates/tests/test_gate_3_hash.py
#   python3 -m pytest cabinet/scripts/gates/tests/test_gate_3_hash.py
#
# psycopg2 is stubbed via sys.modules — gate-3-idempotency.py imports it at
# module level, but this test never exercises the DB path. The stub becomes
# dead weight once FW-024 ships real psycopg2-binary; that's cheap and fine.

from __future__ import annotations

import hashlib
import importlib.util
import os
import sys
import types
from pathlib import Path

# --- Stub heavy deps BEFORE importing the gate module ---
# CAUTION: sys.modules is process-global. If pytest runs this test in the
# same session as another test that imports real psycopg2 AFTER this line,
# setdefault is a no-op and our stub is shadowed (harmless). But if a
# DIFFERENT test runs FIRST and stubs psycopg2 differently, ours becomes
# the no-op and we may load a mismatched stub. Run this file standalone
# (or first in the pytest order) if stub-collision ever surfaces.
# Clean alternative when FW-024 ships psycopg2-binary: delete the stub
# entirely and let the real import win.
sys.modules.setdefault("psycopg2", types.ModuleType("psycopg2"))

# --- Load gate-3-idempotency.py (hyphenated filename → importlib) ---
_GATES_DIR = Path(__file__).resolve().parent.parent
_GATE_PATH = _GATES_DIR / "gate-3-idempotency.py"
_spec = importlib.util.spec_from_file_location("gate_3_idempotency", str(_GATE_PATH))
if _spec is None or _spec.loader is None:  # pragma: no cover
    raise RuntimeError(f"could not load {_GATE_PATH}")
gate_3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gate_3)


# Spec 039 §5.9 M-5 frozen column list — DO NOT EDIT without spec amendment.
SPEC_HASH_COLS = [
    "id", "external_ref", "title", "description", "status", "blocked",
    "blocked_reason", "priority", "type", "parent_epic_ref",
    "founder_action", "due_date", "captain_decision", "decision_ref",
    "pr_url",
]

# Canned row covering every _HASH_COLS field. Two fields (blocked_reason,
# decision_ref) are None to exercise the concat_ws NULL-skip path.
CANNED_ROW_WITH_NULLS = {
    "id": "0f3a1c4e-7b21-4c8a-9f3c-2b1d9e5c8a11",
    "external_ref": "SEN-101",
    "title": "Test canonical row",
    "description": "Canned row for Gate 3 idempotency drift detection.",
    "status": "queue",
    "blocked": False,
    "blocked_reason": None,
    "priority": 2,
    "type": "task",
    "parent_epic_ref": "SEN-100",
    "founder_action": False,
    "due_date": "2026-04-30",
    "captain_decision": False,
    "decision_ref": None,
    "pr_url": "https://github.com/org/repo/pull/42",
}

# Golden hexdigest — regenerate ONLY after Spec 039 §5.9 M-5 amendment.
# md5('|'.join(str(v) for non-None v in _HASH_COLS order).encode('utf-8'))
GOLDEN_HEX_WITH_NULLS = "4131f221173010942e19edebc63a7e9e"
GOLDEN_HEX_ALL_POPULATED = "e4e3de02987a900484c3e58a4df55404"


def _python_hash(row):
    parts = [str(row[c]) for c in gate_3._HASH_COLS if row.get(c) is not None]
    body = "|".join(parts).encode("utf-8")
    return hashlib.md5(body).hexdigest()


def test_hash_cols_match_spec_exactly():
    """_HASH_COLS must match Spec 039 §5.9 M-5 verbatim — order matters."""
    assert gate_3._HASH_COLS == SPEC_HASH_COLS, (
        f"_HASH_COLS drift detected.\n"
        f"  Expected (spec): {SPEC_HASH_COLS}\n"
        f"  Got (code):      {gate_3._HASH_COLS}\n"
        f"Any change to the hash basis requires a Spec 039 §5.9 M-5 amendment "
        f"AND an update to this test's SPEC_HASH_COLS constant AND a refresh "
        f"of the golden hexdigests below."
    )


def test_hash_cols_has_exactly_15_entries():
    """Sentinel — guards against silent insertion of a 16th col."""
    assert len(gate_3._HASH_COLS) == 15, (
        f"_HASH_COLS has {len(gate_3._HASH_COLS)} entries; spec says 15."
    )


def test_golden_hash_with_nulls():
    """Canned row with 2 NULLs must produce the golden hexdigest."""
    actual = _python_hash(CANNED_ROW_WITH_NULLS)
    assert actual == GOLDEN_HEX_WITH_NULLS, (
        f"Hash drift on canned row with NULLs.\n"
        f"  Expected: {GOLDEN_HEX_WITH_NULLS}\n"
        f"  Got:      {actual}\n"
        f"If this flipped because you amended Spec 039 §5.9 M-5: recompute the "
        f"golden constants in this file. If you did NOT amend the spec, the "
        f"hash basis has drifted — revert your change."
    )


def test_golden_hash_all_populated():
    """No-NULL variant must produce a distinct, stable golden hexdigest."""
    row = dict(CANNED_ROW_WITH_NULLS)
    row["blocked_reason"] = "waiting on founder"
    row["decision_ref"] = "DECISION-042"
    actual = _python_hash(row)
    assert actual == GOLDEN_HEX_ALL_POPULATED, (
        f"Hash drift on all-populated canned row.\n"
        f"  Expected: {GOLDEN_HEX_ALL_POPULATED}\n"
        f"  Got:      {actual}"
    )


def test_none_values_are_skipped_not_stringified():
    """Setting a previously-None col to a value MUST change the hash.

    Protects against a subtle bug: if _fetch_row_hashes accidentally used
    `[str(rec[c]) for c in _HASH_COLS]` (no None guard), Python would join
    literal 'None' strings, which Postgres concat_ws would not do. The two
    paths would then disagree on any row with NULLs.
    """
    with_null = _python_hash(CANNED_ROW_WITH_NULLS)
    row = dict(CANNED_ROW_WITH_NULLS)
    row["blocked_reason"] = "flipped"
    without_null = _python_hash(row)
    assert with_null != without_null, (
        "Flipping a NULL col to a value must change the hash. If equal, the "
        "None-skip logic in _fetch_row_hashes is broken."
    )


def test_order_sensitivity_catches_reorder():
    """Swapping two col positions in the hash basis must change the output."""
    row = CANNED_ROW_WITH_NULLS
    parts_original = [str(row[c]) for c in gate_3._HASH_COLS if row.get(c) is not None]
    original = hashlib.md5("|".join(parts_original).encode("utf-8")).hexdigest()
    # Simulate col-order drift by swapping two adjacent cols in a local copy.
    swapped_cols = list(gate_3._HASH_COLS)
    i = swapped_cols.index("status")
    j = swapped_cols.index("blocked")
    swapped_cols[i], swapped_cols[j] = swapped_cols[j], swapped_cols[i]
    parts_swapped = [str(row[c]) for c in swapped_cols if row.get(c) is not None]
    swapped = hashlib.md5("|".join(parts_swapped).encode("utf-8")).hexdigest()
    assert original != swapped, (
        "Reordering _HASH_COLS should change the hash — this test's premise "
        "is broken or md5 is not behaving like md5."
    )


def main():
    tests = [
        test_hash_cols_match_spec_exactly,
        test_hash_cols_has_exactly_15_entries,
        test_golden_hash_with_nulls,
        test_golden_hash_all_populated,
        test_none_values_are_skipped_not_stringified,
        test_order_sensitivity_catches_reorder,
    ]
    passed = failed = 0
    for t in tests:
        try:
            t()
            print(f"  PASS  {t.__name__}")
            passed += 1
        except AssertionError as e:
            print(f"  FAIL  {t.__name__}")
            print(f"        {e}")
            failed += 1
    print(f"\n{passed}/{len(tests)} passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
