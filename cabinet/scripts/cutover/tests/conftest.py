"""pytest config for cutover/ tests (Spec 039 §5.9 Gate 4).

Mirrors cabinet/scripts/lib/tests/conftest.py: stubs optional deps so
pure-function tests import regardless of venv state, and puts cutover/lib
on sys.path so the hyphen-free package layout resolves.
"""
from __future__ import annotations

import sys
import types
from pathlib import Path

for _mod in ("requests", "yaml"):
    if _mod not in sys.modules:
        sys.modules[_mod] = types.ModuleType(_mod)

_CUTOVER_DIR = Path(__file__).parent.parent.resolve()
if str(_CUTOVER_DIR) not in sys.path:
    sys.path.insert(0, str(_CUTOVER_DIR))
