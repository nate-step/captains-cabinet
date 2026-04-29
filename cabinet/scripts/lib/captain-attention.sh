#!/bin/bash
# captain-attention.sh — Officer-to-Captain DM routing pipeline (FW-084)
# Spec 034 v3 AC #74
#
# In single_ceo mode, non-CEO officers cannot DM the Captain directly.
# Instead they push a Captain-attention payload to a per-project Redis Stream.
# The CEO officer reads the stream each session tick and decides:
#   (a) handle inline — reply to source officer via notify-officer.sh
#   (b) forward to Captain via CEO's Telegram bot (with attribution)
#   (c) defer — ask source officer for more context first
# Captain replies always arrive at the CEO bot; CEO routes reply back to
# the source officer via notify-officer.sh.
# Audit trail: every forward + disposition logged to cabinet/logs/captain-attention/<project>.jsonl
#
# Usage (source this file):
#   . /opt/founders-cabinet/cabinet/scripts/lib/captain-attention.sh
#   captain_attention_push <project> <urgency> "<summary>" "<body>"
#   captain_attention_read <project>
#   captain_attention_ack  <project> <entry_id> <disposition> "<captain_reply>"
#
# Stream key:  cabinet:captain-attention:<project>
# Group:       ceo-reader-<project>
# Consumer:    ceo-worker
#
# Urgency allowlist: low | medium | high | blocking
# Disposition allowlist: handled | forwarded | deferred
#
# Slug contract (mirrors FW-073/074/075/078/080/082):
#   regex: ^[a-z0-9][a-z0-9-]*$
#   length cap: 32 chars
#
# Security:
#   - project slug validated on every call (injection guard)
#   - urgency validated against allowlist (injection guard)
#   - disposition validated against allowlist (injection guard)
#   - audit log path derived only from slug-validated project (no path traversal)
#   - captain_reply forwarded to source officer only via notify-officer.sh
#     (never echoed into shared channels — Captain privacy per pattern C-414a598c)

CATN_REDIS_HOST="${REDIS_HOST:-redis}"
CATN_REDIS_PORT="${REDIS_PORT:-6379}"
CATN_CABINET_ROOT="${CABINET_ROOT:-/opt/founders-cabinet}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# _catn_validate_project <project>
# Exits non-zero (stderr) if slug is malformed. Returns 0 on success.
_catn_validate_project() {
  local project="$1"
  if [ -z "$project" ]; then
    echo "captain-attention: project slug is required" >&2
    return 1
  fi
  if ! [[ "$project" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "captain-attention: project slug must match [a-z0-9][a-z0-9-]* (got '$project')" >&2
    return 1
  fi
  if [ "${#project}" -gt 32 ]; then
    echo "captain-attention: project slug must be <=32 chars (got ${#project} chars: '$project')" >&2
    return 1
  fi
  return 0
}

# _catn_validate_urgency <urgency>
# Returns 0 if urgency is in allowlist, 1 otherwise.
_catn_validate_urgency() {
  local urgency="$1"
  case "$urgency" in
    low|medium|high|blocking) return 0 ;;
    *)
      echo "captain-attention: urgency must be one of: low medium high blocking (got '$urgency')" >&2
      return 1
      ;;
  esac
}

# _catn_validate_disposition <disposition>
# Returns 0 if disposition is in allowlist, 1 otherwise.
_catn_validate_disposition() {
  local disposition="$1"
  case "$disposition" in
    handled|forwarded|deferred) return 0 ;;
    *)
      echo "captain-attention: disposition must be one of: handled forwarded deferred (got '$disposition')" >&2
      return 1
      ;;
  esac
}

# _catn_stream_key <project>
_catn_stream_key() { echo "cabinet:captain-attention:${1}"; }

# _catn_group <project>
_catn_group() { echo "ceo-reader-${1}"; }

# _catn_ids_file <project>
# Per-project temp file for pending entry IDs (parallel to triggers.sh pattern).
_catn_ids_file() { echo "/tmp/.captain_attention_ids_${1}"; }

# _catn_audit_log <project>
# Path to JSONL audit log. Slug already validated by caller so no traversal risk.
_catn_audit_log() {
  local log_dir="${CATN_CABINET_ROOT}/cabinet/logs/captain-attention"
  mkdir -p "$log_dir"
  echo "${log_dir}/${1}.jsonl"
}

# ---------------------------------------------------------------------------
# captain_attention_push <project> <urgency> "<summary>" "<body>"
# ---------------------------------------------------------------------------
# Non-CEO officer pushes a Captain-attention payload.
# Uses OFFICER_NAME env var as source (mirrors trigger_send pattern).
captain_attention_push() {
  local project="$1"
  local urgency="$2"
  local summary="$3"
  local body="$4"

  _catn_validate_project "$project" || return 1
  _catn_validate_urgency "$urgency" || return 1

  local source="${OFFICER_NAME:-unknown}"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local stream
  stream=$(_catn_stream_key "$project")
  local group
  group=$(_catn_group "$project")

  # Ensure consumer group exists
  redis-cli -h "$CATN_REDIS_HOST" -p "$CATN_REDIS_PORT" \
    XGROUP CREATE "$stream" "$group" 0 MKSTREAM > /dev/null 2>&1

  # XADD payload. Fail LOUD — silent drop of a Captain-attention request is
  # how the CEO misses a blocking issue without any diagnostic surface.
  local xadd_out xadd_err
  xadd_err=$(redis-cli -h "$CATN_REDIS_HOST" -p "$CATN_REDIS_PORT" \
    XADD "$stream" '*' \
    source  "$source" \
    project "$project" \
    urgency "$urgency" \
    summary "$summary" \
    body    "$body" \
    ts      "$timestamp" \
    2>&1 > /dev/null)

  if [ $? -ne 0 ] || [ -n "$xadd_err" ]; then
    echo "captain_attention_push: XADD to $stream failed (${xadd_err:-redis unreachable?}) — payload NOT queued, source=$source" >&2
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# captain_attention_read <project>
# ---------------------------------------------------------------------------
# CEO reads pending Captain-attention payloads (consumer group read).
# Outputs: one JSON line per entry with source/urgency/summary/body/ts.
# Sets global CATN_ENTRY_IDS (space-separated) for use with captain_attention_ack.
# Returns 1 if no new entries.
captain_attention_read() {
  local project="$1"

  _catn_validate_project "$project" || return 1

  local stream
  stream=$(_catn_stream_key "$project")
  local group
  group=$(_catn_group "$project")
  local ids_file
  ids_file=$(_catn_ids_file "$project")

  # Ensure consumer group exists
  redis-cli -h "$CATN_REDIS_HOST" -p "$CATN_REDIS_PORT" \
    XGROUP CREATE "$stream" "$group" 0 MKSTREAM > /dev/null 2>&1

  local raw_output
  raw_output=$(redis-cli --raw -h "$CATN_REDIS_HOST" -p "$CATN_REDIS_PORT" \
    XREADGROUP GROUP "$group" ceo-worker COUNT 50 \
    STREAMS "$stream" '>' 2>/dev/null)

  if [ -z "$raw_output" ]; then
    echo "" > "$ids_file"
    return 1
  fi

  # Write entry IDs to temp file (mirrors triggers.sh pattern)
  echo "$raw_output" | grep -E '^[0-9]+-[0-9]+$' | tr '\n' ' ' > "$ids_file"

  # Parse raw output into JSON lines for CEO consumption.
  # XREADGROUP --raw format: stream_name, entry_id, field, value, field, value, ...
  # We use awk to group field/value pairs per entry_id and emit JSON.
  local entry_id=""
  local source="" urgency="" summary="" body="" ts_val=""
  local last_field=""

  while IFS= read -r line; do
    # Skip the stream name line (cabinet:captain-attention:<project>)
    [[ "$line" == cabinet:captain-attention:* ]] && continue

    # Entry ID line: matches timestamp-sequence format
    if [[ "$line" =~ ^[0-9]+-[0-9]+$ ]]; then
      # Emit previous entry if we have one
      if [ -n "$entry_id" ]; then
        printf '{"entry_id":"%s","source":"%s","urgency":"%s","summary":"%s","body":"%s","ts":"%s"}\n' \
          "$entry_id" \
          "$(printf '%s' "$source"  | sed 's/"/\\"/g')" \
          "$(printf '%s' "$urgency" | sed 's/"/\\"/g')" \
          "$(printf '%s' "$summary" | sed 's/"/\\"/g')" \
          "$(printf '%s' "$body"    | sed 's/"/\\"/g')" \
          "$(printf '%s' "$ts_val"  | sed 's/"/\\"/g')"
      fi
      entry_id="$line"
      source="" urgency="" summary="" body="" ts_val="" last_field=""
      continue
    fi

    # Field names and values alternate in raw output
    case "$last_field" in
      source)  source="$line";  last_field="" ;;
      urgency) urgency="$line"; last_field="" ;;
      summary) summary="$line"; last_field="" ;;
      body)    body="$line";    last_field="" ;;
      ts)      ts_val="$line";  last_field="" ;;
      "")
        # This line is a field name
        case "$line" in
          source|urgency|summary|body|ts) last_field="$line" ;;
          *) last_field="" ;;  # skip unknown fields
        esac
        ;;
    esac
  done <<< "$raw_output"

  # Emit last entry
  if [ -n "$entry_id" ]; then
    printf '{"entry_id":"%s","source":"%s","urgency":"%s","summary":"%s","body":"%s","ts":"%s"}\n' \
      "$entry_id" \
      "$(printf '%s' "$source"  | sed 's/"/\\"/g')" \
      "$(printf '%s' "$urgency" | sed 's/"/\\"/g')" \
      "$(printf '%s' "$summary" | sed 's/"/\\"/g')" \
      "$(printf '%s' "$body"    | sed 's/"/\\"/g')" \
      "$(printf '%s' "$ts_val"  | sed 's/"/\\"/g')"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# captain_attention_ack <project> <entry_id> <disposition> "<captain_reply>"
# ---------------------------------------------------------------------------
# CEO acknowledges a payload after disposition.
#   disposition=handled  → log entry, XACK. No notify.
#   disposition=forwarded → log entry, XACK. Notify source officer with captain_reply.
#   disposition=deferred  → log entry, XACK. No notify (CEO will follow up separately).
# Idempotent: re-acking the same entry_id is safe (XACK is idempotent in Redis).
captain_attention_ack() {
  local project="$1"
  local entry_id="$2"
  local disposition="$3"
  local captain_reply="${4:-}"

  _catn_validate_project "$project"         || return 1
  _catn_validate_disposition "$disposition" || return 1

  # Basic entry_id validation: must look like a Redis stream entry ID
  if ! [[ "$entry_id" =~ ^[0-9]+-[0-9]+$ ]]; then
    echo "captain-attention: entry_id must match <timestamp>-<sequence> (got '$entry_id')" >&2
    return 1
  fi

  local stream
  stream=$(_catn_stream_key "$project")
  local group
  group=$(_catn_group "$project")
  local audit_log
  audit_log=$(_catn_audit_log "$project")
  local ceo="${OFFICER_NAME:-ceo}"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Determine source officer from the stream entry (for forward routing).
  # We XRANGE for the specific entry_id to read the source field.
  local entry_source=""
  local entry_raw
  entry_raw=$(redis-cli --raw -h "$CATN_REDIS_HOST" -p "$CATN_REDIS_PORT" \
    XRANGE "$stream" "$entry_id" "$entry_id" 2>/dev/null)
  if [ -n "$entry_raw" ]; then
    # Parse source field from the raw entry
    local _field_mode=false _src=""
    while IFS= read -r _line; do
      if [ "$_field_mode" = true ]; then
        _src="$_line"; _field_mode=false
      elif [ "$_line" = "source" ]; then
        _field_mode=true
      fi
    done <<< "$entry_raw"
    entry_source="$_src"
  fi

  # 1. Write audit log entry (always — regardless of disposition)
  {
    printf '{"ts":"%s","project":"%s","entry_id":"%s","ceo":"%s","source":"%s","disposition":"%s","captain_reply":"%s"}\n' \
      "$timestamp" \
      "$project" \
      "$entry_id" \
      "$ceo" \
      "$(printf '%s' "$entry_source" | sed 's/"/\\"/g')" \
      "$disposition" \
      "$(printf '%s' "$captain_reply" | sed 's/"/\\"/g')"
  } >> "$audit_log"

  # 2. XACK the entry (idempotent — safe to re-ack)
  redis-cli -h "$CATN_REDIS_HOST" -p "$CATN_REDIS_PORT" \
    XACK "$stream" "$group" "$entry_id" > /dev/null 2>&1

  # Trim stream to keep it lean (mirrors triggers.sh)
  redis-cli -h "$CATN_REDIS_HOST" -p "$CATN_REDIS_PORT" \
    XTRIM "$stream" MAXLEN '~' 200 > /dev/null 2>&1

  # 3. If forwarded AND we have a captain_reply AND a source officer:
  #    route reply to source officer via notify-officer.sh.
  #    NEVER echo captain_reply into shared channels (Captain privacy).
  if [ "$disposition" = "forwarded" ] && [ -n "$captain_reply" ] && [ -n "$entry_source" ]; then
    local notify_script="${CATN_CABINET_ROOT}/cabinet/scripts/notify-officer.sh"
    if [ -f "$notify_script" ]; then
      OFFICER_NAME="$ceo" bash "$notify_script" "$entry_source" \
        "CAPTAIN REPLY (via CEO): $captain_reply" 2>/dev/null || \
        echo "captain_attention_ack: WARN — notify-officer.sh failed for $entry_source" >&2
    else
      echo "captain_attention_ack: WARN — notify-officer.sh not found; captain_reply not routed to $entry_source" >&2
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# captain_attention_scan <project>
# ---------------------------------------------------------------------------
# Convenience function for the CEO's post-tool-use hook integration.
# Reads any pending entries and outputs them formatted for CEO triage.
# Returns 0 if entries were found (CEO should process), 1 if queue is empty.
captain_attention_scan() {
  local project="$1"

  _catn_validate_project "$project" || return 1

  local stream
  stream=$(_catn_stream_key "$project")
  local group
  group=$(_catn_group "$project")

  # Ensure consumer group exists
  redis-cli -h "$CATN_REDIS_HOST" -p "$CATN_REDIS_PORT" \
    XGROUP CREATE "$stream" "$group" 0 MKSTREAM > /dev/null 2>&1

  # Check if there are any pending entries (unacknowledged from previous reads)
  # plus any new entries, without consuming them (XPENDING just counts)
  local pending_count
  pending_count=$(redis-cli --raw -h "$CATN_REDIS_HOST" -p "$CATN_REDIS_PORT" \
    XPENDING "$stream" "$group" 2>/dev/null | head -1)

  # Also check for new (unread) entries
  local new_entries
  new_entries=$(redis-cli --raw -h "$CATN_REDIS_HOST" -p "$CATN_REDIS_PORT" \
    XLEN "$stream" 2>/dev/null)

  if [ "${pending_count:-0}" -gt 0 ] || [ "${new_entries:-0}" -gt 0 ]; then
    local entries
    entries=$(captain_attention_read "$project")
    if [ -n "$entries" ]; then
      echo ""
      echo "CAPTAIN-ATTENTION QUEUE ($project) — pending officer escalations:"
      echo "$entries"
      echo ""
      echo "CEO: Review each entry. For each:"
      echo "  - handled:   captain_attention_ack $project <entry_id> handled"
      echo "  - forwarded: captain_attention_ack $project <entry_id> forwarded '<captain-reply>'"
      echo "  - deferred:  captain_attention_ack $project <entry_id> deferred"
      echo ""
      local ids_file
      ids_file=$(_catn_ids_file "$project")
      echo "  Pending IDs: $(cat "$ids_file" 2>/dev/null)"
      return 0
    fi
  fi
  return 1
}
