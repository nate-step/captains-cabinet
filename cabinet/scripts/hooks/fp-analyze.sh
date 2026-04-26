#!/bin/bash
# cabinet/scripts/hooks/fp-analyze.sh — Spec 043 Phase 3 FP-rate review tool
#
# Aggregates fires from cabinet/logs/hook-fires/*.jsonl and reports per-hook
# fire counts, per-officer breakdown, top matched phrases, and daily fire-
# rate trend over a configurable window. Operational counterpart to the
# S4 hook-authoring-discipline meta-skill — feeds the data that decides
# whether a soft-warn earns hard-block status.
#
# Usage:
#   bash cabinet/scripts/hooks/fp-analyze.sh                                  # last 7 days, all hooks
#   bash cabinet/scripts/hooks/fp-analyze.sh --days 30
#   bash cabinet/scripts/hooks/fp-analyze.sh --hook captain-gate-language
#   bash cabinet/scripts/hooks/fp-analyze.sh --officer cto
#   bash cabinet/scripts/hooks/fp-analyze.sh --json                           # JSON output for scripting
#
# Native: bash entrypoint + Python stdlib parser.
# Reversibility: rm cabinet/scripts/hooks/fp-analyze.sh.

set -u

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
LOG_DIR="$REPO_ROOT/cabinet/logs/hook-fires"

DAYS=7
HOOK_FILTER=""
OFFICER_FILTER=""
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="$2"; shift 2 ;;
    --hook) HOOK_FILTER="$2"; shift 2 ;;
    --officer) OFFICER_FILTER="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help)
      head -16 "$0" | tail -15
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [ ! -d "$LOG_DIR" ]; then
  echo "[fp-analyze] no log dir at $LOG_DIR (no hooks have fired yet)" >&2
  exit 0
fi

shopt -s nullglob
LOGS=("$LOG_DIR"/*.jsonl)
shopt -u nullglob

if [ ${#LOGS[@]} -eq 0 ]; then
  echo "[fp-analyze] no JSONL logs in $LOG_DIR" >&2
  exit 0
fi

exec python3 - "$DAYS" "$HOOK_FILTER" "$OFFICER_FILTER" "$JSON" "${LOGS[@]}" <<'PYEOF'
import sys, os, json
from datetime import datetime, timedelta, timezone
from collections import Counter, defaultdict

days = int(sys.argv[1])
hook_filter = sys.argv[2]
officer_filter = sys.argv[3]
emit_json = sys.argv[4] == "1"
log_paths = sys.argv[5:]

cutoff = datetime.now(timezone.utc) - timedelta(days=days)

records = []
for path in log_paths:
    hook_name = os.path.basename(path).replace('.jsonl', '')
    if hook_filter and hook_name != hook_filter:
        continue
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts_raw = rec.get('ts', '')
                try:
                    ts = datetime.fromisoformat(ts_raw.replace('Z', '+00:00'))
                except ValueError:
                    continue
                if ts < cutoff:
                    continue
                if officer_filter and rec.get('officer') != officer_filter:
                    continue
                rec['_hook'] = hook_name
                rec['_ts_obj'] = ts
                records.append(rec)
    except FileNotFoundError:
        continue

if emit_json:
    out_records = []
    for r in records:
        r2 = {k: v for k, v in r.items() if not k.startswith('_')}
        r2['hook'] = r['_hook']
        out_records.append(r2)
    print(json.dumps({
        'window_days': days,
        'total_fires': len(out_records),
        'records': out_records,
    }, indent=2))
    sys.exit(0)

# Markdown report.
print(f"# Hook FP-rate report — last {days} days")
print(f"\nTotal fires: **{len(records)}**\n")

if not records:
    print("_No fires in window._")
    sys.exit(0)

# Per-hook counts.
print("## Fires per hook\n")
print("| Hook | Fires |")
print("|------|------:|")
hook_counts = Counter(r['_hook'] for r in records)
for hook, count in hook_counts.most_common():
    print(f"| {hook} | {count} |")
print()

# Per-officer counts.
print("## Fires per officer\n")
print("| Officer | Fires |")
print("|---------|------:|")
officer_counts = Counter(r.get('officer', 'unknown') for r in records)
for officer, count in officer_counts.most_common():
    print(f"| {officer} | {count} |")
print()

# Top matched phrases per hook (only for hooks that have a matched_phrase field).
print("## Top matched phrases per hook\n")
phrase_by_hook = defaultdict(Counter)
for r in records:
    phrase = r.get('matched_phrase')
    if phrase:
        phrase_by_hook[r['_hook']][phrase] += 1

if phrase_by_hook:
    for hook, counter in phrase_by_hook.items():
        print(f"### {hook}\n")
        print("| Phrase | Hits |")
        print("|--------|-----:|")
        for phrase, count in counter.most_common(10):
            phrase_clean = phrase.replace('|', '\\|')
            print(f"| {phrase_clean} | {count} |")
        print()
else:
    print("_(none — no hooks in this window track matched_phrase)_\n")

# Violations breakdown for captain-posture-compliance (different schema).
posture_records = [r for r in records if r['_hook'] == 'captain-posture-compliance']
if posture_records:
    print("## captain-posture-compliance violation classes\n")
    class_counts = Counter()
    for r in posture_records:
        violations = r.get('violations', {})
        for cls, items in violations.items():
            for item in items:
                class_counts[f"{cls}:{item}"] += 1
    print("| Violation | Hits |")
    print("|-----------|-----:|")
    for v, count in class_counts.most_common(20):
        print(f"| {v} | {count} |")
    print()

# Daily trend.
print("## Daily fire-rate trend\n")
daily = defaultdict(int)
for r in records:
    day = r['_ts_obj'].date().isoformat()
    daily[day] += 1
print("| Day | Fires |")
print("|-----|------:|")
for day in sorted(daily.keys()):
    print(f"| {day} | {daily[day]} |")
print()

# Harden-or-not signals (pure heuristic, not ground truth).
print("## Harden-or-not signals\n")
print("These are heuristic — final decision per the S4 hook-authoring-discipline skill requires labeled FP-rate data.\n")
for hook, count in hook_counts.most_common():
    rate_per_day = count / max(days, 1)
    if rate_per_day < 0.5:
        signal = "low fire rate — possibly under-triggering or rule too narrow"
    elif rate_per_day < 5:
        signal = "moderate fire rate — typical soft-warn"
    elif rate_per_day < 20:
        signal = "high fire rate — review trigger specificity"
    else:
        signal = "very high fire rate — likely too broad, expect FP noise"
    print(f"- **{hook}**: {count} fires / {days}d = {rate_per_day:.1f}/day → {signal}")
PYEOF
