#!/bin/bash
# audit-framework-backlog-drift.sh — surface stale Proposed/Paused entries.
#
# Why: the FW-series framework backlog (shared/cabinet-framework-backlog.md)
# captures infrastructure/governance work. Captain-directed Proposed entries
# sometimes SHIP empirically (bundled into adjacent hotfixes) without anyone
# flipping the Status line. FW-002 stayed "Proposed" for 7 days despite
# commit 8898ef5 landing all 4 fixes same-day as the filing. An auditor
# catches that drift class by flagging any Proposed/Paused entry whose
# embedded filing date is older than a threshold.
#
# This tool does NOT decide whether an entry has shipped — it only surfaces
# candidates for human review. Empirical verification (grep the hook
# source, run eval suite, check commit log) stays with the auditor.
#
# Exit 0 always (advisory, not blocking). Prints punch-list to stdout.
#
# Usage:
#   bash cabinet/scripts/audit-framework-backlog-drift.sh          # default thresholds
#   PROPOSED_STALE_DAYS=3 bash audit-framework-backlog-drift.sh    # tighter
#
# Date sources it recognizes (tries each regex per Status line):
#   - "Proposed 2026-04-21 (..." → 2026-04-21
#   - "Proposed (Captain-directed 2026-04-17 ...)" → 2026-04-17
#   - "Paused (... 2026-04-17 ...)" → 2026-04-17
# First YYYY-MM-DD after the Status marker wins. If none found, skip.

set -u

BACKLOG="${BACKLOG:-/opt/founders-cabinet/shared/cabinet-framework-backlog.md}"
PROPOSED_STALE_DAYS="${PROPOSED_STALE_DAYS:-7}"
PAUSED_STALE_DAYS="${PAUSED_STALE_DAYS:-14}"

if [ ! -f "$BACKLOG" ]; then
  echo "audit: $BACKLOG not found" >&2
  exit 0
fi

TODAY_EPOCH=$(date -u +%s)
FLAGGED=0

awk -v today="$TODAY_EPOCH" \
    -v prop_thresh="$PROPOSED_STALE_DAYS" \
    -v paus_thresh="$PAUSED_STALE_DAYS" '
  function age_days(dstr,    cmd, epoch) {
    cmd = "date -u -d \"" dstr "\" +%s 2>/dev/null"
    cmd | getline epoch
    close(cmd)
    if (epoch == "" || epoch == 0) return -1
    return int((today - epoch) / 86400)
  }
  /^### FW-/ { heading = $0; next }
  /^- \*\*Status:\*\*/ {
    status_line = $0
    kind = ""
    if (match(status_line, /Status:\*\* Proposed/)) kind = "Proposed"
    else if (match(status_line, /Status:\*\* Paused/)) kind = "Paused"
    if (kind == "") next

    # First YYYY-MM-DD after the Status marker wins.
    tmp = status_line
    if (match(tmp, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
      dstr = substr(tmp, RSTART, RLENGTH)
    } else {
      next
    }

    days = age_days(dstr)
    if (days < 0) next

    thresh = (kind == "Proposed") ? prop_thresh : paus_thresh
    if (days < thresh) next

    # Extract FW-N short-id from heading for compact output.
    fw_id = heading
    sub(/^### /, "", fw_id)
    # Keep first ~80 chars for compactness.
    if (length(fw_id) > 80) fw_id = substr(fw_id, 1, 77) "…"

    printf "  %-8s age=%3dd  filed=%s  %s\n", kind, days, dstr, fw_id
    flagged++
  }
  END { exit (flagged == 0) ? 0 : 10 }
' "$BACKLOG"
rc=$?

if [ "$rc" = "0" ]; then
  echo "framework-backlog-drift: no stale Proposed/Paused entries (thresholds: Proposed≥${PROPOSED_STALE_DAYS}d, Paused≥${PAUSED_STALE_DAYS}d)"
else
  echo ""
  echo "framework-backlog-drift: review candidates above — verify Status line still accurate against hook source / commit log / eval suite. Flip to SHIPPED/SUPERSEDED/DONE with commit ref if empirically landed."
fi

# ============================================================
# Numbering hygiene — duplicate FW-N headings + gaps in FW-N sequence.
# ============================================================
# A second drift class: human-edited headings can collide on FW-N (two
# entries claiming the same number) or skip a number (gap from FW-066 →
# FW-068 with no FW-067). Either makes "what is FW-067?" ambiguous and
# corrupts cross-references in commit messages and trigger payloads.
# Advisory only — exit code unchanged.

DUP_OUT=$(grep -E '^### FW-[0-9]+ — ' "$BACKLOG" \
  | awk '{print $2}' \
  | sort | uniq -c | awk '$1 > 1 {print $2}')

if [ -n "$DUP_OUT" ]; then
  echo ""
  echo "framework-backlog-drift: DUPLICATE FW-N headings detected:"
  while read -r fw_id; do
    [ -z "$fw_id" ] && continue
    grep -nE "^### ${fw_id} — " "$BACKLOG" | sed 's/^/  /'
  done <<< "$DUP_OUT"
  echo "  → resolve by merging the entries or renumbering one to the next free FW-N."
fi

GAP_OUT=$(grep -E '^### FW-[0-9]+' "$BACKLOG" \
  | sed -E 's/^### FW-0*([0-9]+).*/\1/' \
  | sort -u -n \
  | awk '
    NR == 1 { last = $1; next }
    {
      while (last + 1 < $1) {
        last++
        printf "FW-%03d\n", last
      }
      last = $1
    }
  ')

if [ -n "$GAP_OUT" ]; then
  echo ""
  echo "framework-backlog-drift: MISSING FW-N numbers in sequence:"
  while read -r missing; do
    [ -z "$missing" ] && continue
    echo "  $missing — no entry; either back-fill or document the gap"
  done <<< "$GAP_OUT"
fi

exit 0
