#!/bin/bash
# cabinet/scripts/captain-rules/eval.sh — Spec 042 Phase 3 golden eval
#
# Runs each fixture in eval-fixtures/ through query.sh and asserts the
# expected anchor + pattern + intent IDs surface in the retrieval block.
# Reports PASS/FAIL per fixture; exits 0 if all pass, 1 otherwise.
#
# Spec 042 AC #8 (golden eval runs the gate-on-reversibles primary fixture
# and passes) + AC #13 (Phase 3 includes pre-/post-comparison; this run is
# the deterministic "rule retrieved" half — LLM-eval comparison is a Phase
# 3.5 follow-up).
#
# Usage:
#   bash cabinet/scripts/captain-rules/eval.sh
#   bash cabinet/scripts/captain-rules/eval.sh path/to/single-fixture.yaml
#   VERBOSE=1 bash cabinet/scripts/captain-rules/eval.sh    # full block dumps
#
# Native (no PyYAML, no deps). Reversibility: rm cabinet/scripts/captain-rules/eval*.

set -u

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(git -C "$SELF_DIR" rev-parse --show-toplevel 2>/dev/null || echo /opt/founders-cabinet)}"
QUERY_SH="$SELF_DIR/query.sh"
FIXTURES_DIR="$SELF_DIR/eval-fixtures"
VERBOSE="${VERBOSE:-0}"

if [ ! -x "$QUERY_SH" ]; then
  echo "[eval] query.sh missing or not executable at $QUERY_SH" >&2
  exit 1
fi

if [ "$#" -gt 0 ]; then
  FIXTURES=("$@")
else
  FIXTURES=("$FIXTURES_DIR"/*.yaml)
fi

if [ ${#FIXTURES[@]} -eq 0 ] || [ ! -f "${FIXTURES[0]}" ]; then
  echo "[eval] no fixtures found in $FIXTURES_DIR" >&2
  exit 1
fi

# parse_fixture <path> — emit shell-eval-able VAR= assignments to stdout.
# Hand-rolled minimal YAML reader; only supports the fixture schema.
parse_fixture() {
  python3 - "$1" <<'PYEOF'
import sys, re, json

path = sys.argv[1]
fields = {
    'name': '',
    'description': '',
    'officer': 'cto',
    'dm_text': '',
    'expected_anchors': [],
    'expected_patterns': [],
    'expected_intents': [],
    'expected_min_block_length': 100,
}

with open(path) as f:
    lines = f.readlines()

i = 0
while i < len(lines):
    line = lines[i].rstrip('\n')
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        i += 1
        continue

    m = re.match(r'^(\w+):\s*(.*)$', stripped)
    if not m:
        i += 1
        continue

    key, val = m.group(1), m.group(2)

    # Block scalar (| or |-)
    if val.startswith('|'):
        i += 1
        body = []
        while i < len(lines):
            nl = lines[i]
            if nl.strip() == '' and (i + 1 >= len(lines) or lines[i+1].startswith(' ')):
                body.append('')
                i += 1
                continue
            if nl.startswith('  ') or nl.startswith('\t'):
                body.append(nl[2:].rstrip('\n') if nl.startswith('  ') else nl[1:].rstrip('\n'))
                i += 1
            else:
                break
        fields[key] = '\n'.join(body).rstrip('\n')
        continue

    # Flow list `[a, b, c]`
    if val.startswith('[') and val.endswith(']'):
        inner = val[1:-1].strip()
        items = [x.strip().strip('"').strip("'") for x in inner.split(',') if x.strip()]
        fields[key] = items
        i += 1
        continue

    # Scalar
    if val.startswith('"') and val.endswith('"'):
        val = val[1:-1]
    if key == 'expected_min_block_length':
        try:
            fields[key] = int(val)
        except ValueError:
            pass
    else:
        fields[key] = val
    i += 1

# Emit as JSON for the bash side to consume.
sys.stdout.write(json.dumps(fields))
PYEOF
}

run_fixture() {
  local path="$1"
  local fixture_json
  fixture_json="$(parse_fixture "$path")"
  if [ -z "$fixture_json" ]; then
    echo "FAIL  $(basename "$path")  parse_failed"
    return 1
  fi

  local name officer dm_text expected_anchors expected_patterns expected_intents expected_min_block_length
  name="$(echo "$fixture_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
  officer="$(echo "$fixture_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["officer"])')"
  dm_text="$(echo "$fixture_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["dm_text"])')"
  expected_anchors="$(echo "$fixture_json" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["expected_anchors"]))')"
  expected_patterns="$(echo "$fixture_json" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["expected_patterns"]))')"
  expected_intents="$(echo "$fixture_json" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)["expected_intents"]))')"
  expected_min_block_length="$(echo "$fixture_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["expected_min_block_length"])')"

  local block
  block="$(bash "$QUERY_SH" "$officer" "$dm_text" 2>/dev/null)"
  local block_len="${#block}"

  if [ "$VERBOSE" = "1" ]; then
    echo "--- fixture $name --- DM: $(echo "$dm_text" | tr '\n' ' ' | head -c 100)"
    echo "$block"
    echo "--- end ---"
  fi

  local missing=()

  if [ -n "$expected_anchors" ]; then
    IFS=',' read -ra ids <<< "$expected_anchors"
    for id in "${ids[@]}"; do
      if ! echo "$block" | grep -qE "^[[:space:]]+${id}[[:space:]]"; then
        missing+=("anchor:$id")
      fi
    done
  fi

  if [ -n "$expected_patterns" ]; then
    IFS=',' read -ra ids <<< "$expected_patterns"
    for id in "${ids[@]}"; do
      if ! echo "$block" | grep -qE "^[[:space:]]+${id}[[:space:]]"; then
        missing+=("pattern:$id")
      fi
    done
  fi

  if [ -n "$expected_intents" ]; then
    IFS=',' read -ra ids <<< "$expected_intents"
    for id in "${ids[@]}"; do
      if ! echo "$block" | grep -qE "^[[:space:]]+${id}[[:space:]]"; then
        missing+=("intent:$id")
      fi
    done
  fi

  if [ "$block_len" -lt "$expected_min_block_length" ]; then
    missing+=("block-len:$block_len<$expected_min_block_length")
  fi

  if [ ${#missing[@]} -eq 0 ]; then
    echo "PASS  $name"
    return 0
  else
    echo "FAIL  $name  missing: ${missing[*]}"
    return 1
  fi
}

PASS=0
FAIL=0
for fixture in "${FIXTURES[@]}"; do
  if run_fixture "$fixture"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
  fi
done

echo ""
echo "[eval] pass=$PASS fail=$FAIL total=$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
