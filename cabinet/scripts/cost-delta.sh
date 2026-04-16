#!/bin/bash
# cost-delta.sh — Compare per-officer token costs between two dates
# Used for post-Opus-4.7 tokenizer variance monitoring (Apr 16+).
# Usage: bash cost-delta.sh [baseline-date] [compare-date]
# Default: compares yesterday vs today.

BASELINE="${1:-$(date -u -d '1 day ago' +%Y-%m-%d)}"
COMPARE="${2:-$(date -u +%Y-%m-%d)}"

REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"

echo "=== Cost Delta: $BASELINE → $COMPARE ==="
echo ""
printf "%-7s %-12s %-12s %-10s %-12s %-12s %-10s\n" "Officer" "In (base)" "In (cmp)" "In %" "Cost (base)" "Cost (cmp)" "Cost %"
printf "%-7s %-12s %-12s %-10s %-12s %-12s %-10s\n" "-------" "---------" "--------" "-----" "-----------" "----------" "------"

for officer in cos cto cpo cro coo; do
  # Baseline values
  in_base=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "cabinet:cost:tokens:daily:$BASELINE" "${officer}_input" 2>/dev/null)
  cost_base=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "cabinet:cost:tokens:daily:$BASELINE" "${officer}_cost_micro" 2>/dev/null)
  in_base="${in_base:-0}"
  cost_base="${cost_base:-0}"

  # Compare values
  in_cmp=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "cabinet:cost:tokens:daily:$COMPARE" "${officer}_input" 2>/dev/null)
  cost_cmp=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" HGET "cabinet:cost:tokens:daily:$COMPARE" "${officer}_cost_micro" 2>/dev/null)
  in_cmp="${in_cmp:-0}"
  cost_cmp="${cost_cmp:-0}"

  # Percentage deltas (awk for precision)
  if [ "$in_base" -gt 0 ] 2>/dev/null; then
    in_pct=$(awk -v a="$in_cmp" -v b="$in_base" 'BEGIN{printf "%.1f%%", (a/b - 1) * 100}')
  else
    in_pct="n/a"
  fi
  if [ "$cost_base" -gt 0 ] 2>/dev/null; then
    cost_pct=$(awk -v a="$cost_cmp" -v b="$cost_base" 'BEGIN{printf "%.1f%%", (a/b - 1) * 100}')
  else
    cost_pct="n/a"
  fi

  cost_base_d=$(awk -v m="$cost_base" 'BEGIN{printf "$%.2f", m/1000000}')
  cost_cmp_d=$(awk -v m="$cost_cmp" 'BEGIN{printf "$%.2f", m/1000000}')

  printf "%-7s %-12s %-12s %-10s %-12s %-12s %-10s\n" \
    "$officer" "$in_base" "$in_cmp" "$in_pct" "$cost_base_d" "$cost_cmp_d" "$cost_pct"
done

echo ""
echo "Watch: Opus 4.7 tokenizer-v2 is projected to add +1.0-1.35x input tokens per prompt."
echo "Alert threshold: >1.5x input tokens vs pre-rollout baseline = investigate."
