"""pytest config for ETL transform tests (FW-023).

Stubs `requests` + `yaml` in sys.modules so pure-function tests (_map_state,
_map_status, _extract_fw_marker) can import etl-linear / etl-github / etl-common
in containers lacking those packages. FW-024 unblocks the real deps; this
harness stays useful regardless.

Also inserts the parent `lib/` dir onto sys.path so `test_etl_fixtures` +
the hyphenated ETL modules resolve.
"""
from __future__ import annotations

import sys
import types
from pathlib import Path

for _mod in ("requests", "yaml"):
    if _mod not in sys.modules:
        sys.modules[_mod] = types.ModuleType(_mod)
# NOTE: the stubs persist for the full pytest session. Once FW-024 lands
# real `requests` + `yaml` deps, drop this stub block — or the idempotent
# guard will leave whichever module was imported first (stub vs real) in
# place for every downstream test file in the same run.

_LIB_DIR = Path(__file__).parent.parent.resolve()
if str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))
