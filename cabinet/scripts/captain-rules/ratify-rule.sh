#!/bin/bash
# cabinet/scripts/captain-rules/ratify-rule.sh — Spec 048 v2 Phase 2
#
# Captain ratify path for auto-drafted hook + skill pairs. Officer
# invokes after Captain says yes/no/edit on a pending draft.
#
# Usage:
#   ratify-rule.sh <rule_id> yes        — promote drafts to live + register hook
#   ratify-rule.sh <rule_id> no         — delete drafts; memory-file entry stays
#   ratify-rule.sh <rule_id> edit "..." — refine drafts (officer applies feedback manually for now)
#
# yes path:
#   1. mv cabinet/scripts/hooks/draft/<rule_id>.sh.draft → cabinet/scripts/hooks/<rule_id>.sh
#   2. chmod +x the new hook
#   3. mv memory/skills/evolved/draft/<rule_id>.md.draft → memory/skills/evolved/<rule_id>.md
#   4. jq-update .claude/settings.json to register the new hook with appropriate matcher
#   5. Append audit-log entry phase=ratified-yes
#   6. Remove rule_id from pending-drafts marker
#
# no path:
#   1. rm both .draft files
#   2. Append audit-log entry phase=ratified-no
#   3. Remove rule_id from pending-drafts marker
#
# Anti-FW-042: never blocks; missing files / parse errors / settings.json
# write failures emit stderr + still try to clean up the marker.

set -u

RULE_ID="${1:-}"
VERDICT="${2:-}"
EDIT_NOTE="${3:-}"

if [ -z "$RULE_ID" ] || [ -z "$VERDICT" ]; then
  cat >&2 <<EOF
Usage:
  ratify-rule.sh <rule_id> yes
  ratify-rule.sh <rule_id> no
  ratify-rule.sh <rule_id> edit "<note>"
EOF
  exit 1
fi

REPO_ROOT="${REPO_ROOT:-/opt/founders-cabinet}"
HOOK_DRAFT="$REPO_ROOT/cabinet/scripts/hooks/draft/$RULE_ID.sh.draft"
SKILL_DRAFT="$REPO_ROOT/memory/skills/evolved/draft/$RULE_ID.md.draft"
HOOK_LIVE="$REPO_ROOT/cabinet/scripts/hooks/$RULE_ID.sh"
SKILL_LIVE="$REPO_ROOT/memory/skills/evolved/$RULE_ID.md"
SETTINGS_JSON="$REPO_ROOT/.claude/settings.json"
AUDIT_LOG="$REPO_ROOT/cabinet/logs/rule-promotions.jsonl"
OFFICER="${OFFICER_NAME:-${CABINET_OFFICER:-unknown}}"
PENDING_FILE="/tmp/.captain-pending-drafts-$OFFICER"
NOW_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null

remove_from_pending() {
  if [ -f "$PENDING_FILE" ]; then
    grep -vxF "$RULE_ID" "$PENDING_FILE" > "${PENDING_FILE}.tmp" 2>/dev/null
    if [ -s "${PENDING_FILE}.tmp" ]; then
      mv "${PENDING_FILE}.tmp" "$PENDING_FILE"
    else
      rm -f "${PENDING_FILE}.tmp" "$PENDING_FILE"
    fi
  fi
}

write_audit() {
  local outcome="$1"
  local extra="${2:-}"
  local line
  line="$(jq -cn \
    --arg ts "$NOW_ISO" \
    --arg officer "$OFFICER" \
    --arg rule_id "$RULE_ID" \
    --arg outcome "$outcome" \
    --arg extra "$extra" \
    '{ts:$ts, officer:$officer, rule_id:$rule_id, phase:"ratified", outcome:$outcome, extra:$extra}' 2>/dev/null)"
  [ -n "$line" ] && echo "$line" >> "$AUDIT_LOG"
}

case "$VERDICT" in
  yes)
    if [ ! -f "$HOOK_DRAFT" ] || [ ! -f "$SKILL_DRAFT" ]; then
      echo "[ratify] drafts missing for $RULE_ID; nothing to promote" >&2
      write_audit "yes-no-drafts" ""
      remove_from_pending
      exit 0
    fi

    mv "$HOOK_DRAFT" "$HOOK_LIVE"
    chmod +x "$HOOK_LIVE"
    mv "$SKILL_DRAFT" "$SKILL_LIVE"

    # Register the new hook in .claude/settings.json under PreToolUse(any).
    # V1 chooses the safe matcher (any tool). Authors can refine post-ratify
    # by editing settings.json + restarting; we don't try to infer from the
    # classifier surface field at this stage to avoid wrong matchers.
    if [ -f "$SETTINGS_JSON" ] && command -v jq >/dev/null 2>&1; then
      TMP="$(mktemp)"
      jq --arg cmd "bash $HOOK_LIVE" '
        .hooks.PreToolUse += [{
          matcher: "",
          hooks: [{type: "command", command: $cmd}]
        }]
      ' "$SETTINGS_JSON" > "$TMP" 2>/dev/null && mv "$TMP" "$SETTINGS_JSON"
    fi

    write_audit "yes" "$HOOK_LIVE"
    remove_from_pending
    echo "[ratify] $RULE_ID promoted: $HOOK_LIVE + $SKILL_LIVE"
    ;;

  no|reject)
    rm -f "$HOOK_DRAFT" "$SKILL_DRAFT" 2>/dev/null
    write_audit "no" ""
    remove_from_pending
    echo "[ratify] $RULE_ID rejected; drafts removed"
    ;;

  edit)
    # V1 edit-flow: log the edit note + leave drafts in place. Officer or CoS
    # refines manually; subsequent yes/no ratifies the refined draft.
    write_audit "edit" "$EDIT_NOTE"
    echo "[ratify] $RULE_ID edit recorded: $EDIT_NOTE"
    echo "[ratify] drafts remain at $HOOK_DRAFT + $SKILL_DRAFT for hand-refinement"
    ;;

  *)
    echo "[ratify] unknown verdict: $VERDICT (expected yes / no / edit)" >&2
    exit 1
    ;;
esac

exit 0
