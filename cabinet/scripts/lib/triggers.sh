#!/bin/bash
# triggers.sh — Shared trigger functions using Redis Streams
# Source this: . /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh
#
# Redis Streams give us: crash recovery (pending until ACK'd),
# delivery audit trail (XINFO), automatic message IDs + timestamps.
#
# FW-074 (Pool Phase 1B): when $CABINET_ACTIVE_PROJECT is set in the
# calling shell, the stream key + consumer group derive the project
# suffix:
#   legacy:  cabinet:triggers:<officer>          group: officer-<officer>
#   pool:    cabinet:triggers:<officer>:<proj>   group: officer-<officer>-<proj>
# Sender can route cross-project by inline-overriding the env var, e.g.:
#   CABINET_ACTIVE_PROJECT=other-proj trigger_send cpo "msg"
# Legacy callsites (no CABINET_ACTIVE_PROJECT) are byte-for-byte unchanged.

TRIG_REDIS_HOST="${REDIS_HOST:-redis}"
TRIG_REDIS_PORT="${REDIS_PORT:-6379}"

# Compute (stream, group, ids_file) for a given target officer based on the
# caller's CABINET_ACTIVE_PROJECT. Echoes "<stream>|<group>|<ids_file>" —
# callers split on '|'. Pure function, no Redis I/O. The slug regex must
# match start-officer.sh's guard so a malformed env var never lands as a
# malformed Redis key. The ids_file path is per-(officer, project) in pool
# mode so concurrent reads by the same officer across different projects
# do not stomp each other's pending-IDs (FW-074 regression: shared file
# path caused pool trigger_ack to drop the wrong IDs).
_trigger_keys() {
  local target="$1"
  local proj="${CABINET_ACTIVE_PROJECT:-}"
  # Slug guard mirrors start-officer.sh (FW-073): regex + 32-char cap. Any
  # malformed slug (length, charset, leading hyphen) falls through to the
  # legacy stream so a corrupted env var never lands as a malformed Redis
  # key or 100-char tmp path.
  if [ -n "$proj" ] && [[ "$proj" =~ ^[a-z0-9][a-z0-9-]*$ ]] && [ "${#proj}" -le 32 ]; then
    echo "cabinet:triggers:${target}:${proj}|officer-${target}-${proj}|/tmp/.trigger_ids_${target}_${proj}"
  else
    echo "cabinet:triggers:${target}|officer-${target}|/tmp/.trigger_ids_${target}"
  fi
}

# Send a trigger to an officer
# Usage: trigger_send <target_officer> "<message>"
trigger_send() {
  local target="$1" message="$2"
  local sender="${OFFICER_NAME:-unknown}"
  local timestamp=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

  local keys stream group _ids_file
  keys=$(_trigger_keys "$target")
  IFS='|' read -r stream group _ids_file <<< "$keys"

  # Ensure consumer group exists for the target
  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XGROUP CREATE "$stream" "$group" 0 MKSTREAM > /dev/null 2>&1

  # Add message to stream. Fail LOUD on XADD error — silent drop of a
  # deploy-notify or Captain-relay trigger is how the validators miss a
  # production push entirely (audit Finding #1, 2026-04-21). stderr only,
  # so normal success remains silent.
  local _xadd_err
  _xadd_err=$(redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XADD "$stream" '*' \
    sender "$sender" \
    message "[$timestamp] From $sender: $message" \
    2>&1 > /dev/null)
  if [ $? -ne 0 ] || [ -n "$_xadd_err" ]; then
    echo "trigger_send WARN: XADD to $stream failed (${_xadd_err:-redis unreachable?}) — trigger NOT queued, sender=$sender" >&2
  fi

  # Cabinet Memory: queue trigger for semantic indexing (fire-and-forget).
  # FW-077: redirect bg subshell stdout+stderr to /dev/null and disown so
  # bash's job-control "Done" message cannot leak the env vars exported by
  # memory.sh's `set -a; source cabinet/.env` (NEON_CONNECTION_STRING +
  # others) into the calling officer's session JSONL. The disown drops the
  # job from the parent's job table entirely so no completion notice fires.
  if [ -f /opt/founders-cabinet/cabinet/scripts/lib/memory.sh ]; then
    (
      source /opt/founders-cabinet/cabinet/scripts/lib/memory.sh 2>/dev/null
      if declare -f memory_queue_embed > /dev/null; then
        local source_id="trg-$(date -u +%Y%m%dT%H%M%S)-${sender}-to-${target}"
        local metadata
        metadata=$(jq -nc --arg sender "$sender" --arg target "$target" \
          '{sender: $sender, target: $target}')
        memory_queue_embed "officer_trigger" "$source_id" "$sender" "$sender" \
          "[$sender → $target] $message" "$metadata" \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null || true
      fi
    ) >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

# Read NEW triggers for an officer (marks them as pending until ACK'd)
# Usage: trigger_read <officer>
# Outputs: message content lines (one per trigger)
# Sets TRIGGER_IDS variable with space-separated message IDs for ACK
trigger_read() {
  local officer="$1"

  local keys stream group ids_file
  keys=$(_trigger_keys "$officer")
  IFS='|' read -r stream group ids_file <<< "$keys"

  # Ensure consumer group exists (silence BUSYGROUP if already exists)
  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XGROUP CREATE "$stream" "$group" 0 MKSTREAM > /dev/null 2>&1

  local output
  output=$(redis-cli --raw -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XREADGROUP GROUP "$group" worker COUNT 50 \
    STREAMS "$stream" '>' 2>/dev/null)

  if [ -z "$output" ]; then
    echo "" > "$ids_file"
    return 1
  fi

  # Write message IDs to temp file (survives subshell capture). In pool
  # mode the file path is per-(officer, project) so concurrent reads
  # across projects do not stomp each other (FW-074).
  echo "$output" | grep -E '^[0-9]+-[0-9]+$' | tr '\n' ' ' > "$ids_file"
  # Output message content
  echo "$output" | awk '/^message$/{getline; print}'
}

# Read PENDING (unacknowledged) triggers — for crash recovery
# Usage: trigger_read_pending <officer>
trigger_read_pending() {
  local officer="$1"

  local keys stream group ids_file
  keys=$(_trigger_keys "$officer")
  IFS='|' read -r stream group ids_file <<< "$keys"

  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XGROUP CREATE "$stream" "$group" 0 MKSTREAM > /dev/null 2>&1

  local output
  output=$(redis-cli --raw -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XREADGROUP GROUP "$group" worker COUNT 50 \
    STREAMS "$stream" '0' 2>/dev/null)

  if [ -z "$output" ]; then
    echo "" > "$ids_file"
    return 1
  fi

  echo "$output" | grep -E '^[0-9]+-[0-9]+$' | tr '\n' ' ' > "$ids_file"
  echo "$output" | awk '/^message$/{getline; print}'
}

# Acknowledge triggers (mark as processed)
# Usage: trigger_ack <officer> "<id1> <id2> ..."
trigger_ack() {
  local officer="$1" ids="$2"
  [ -z "$ids" ] && return

  local keys stream group _ids_file
  keys=$(_trigger_keys "$officer")
  IFS='|' read -r stream group _ids_file <<< "$keys"

  for id in $ids; do
    redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
      XACK "$stream" "$group" "$id" > /dev/null 2>&1
  done

  # Trim acknowledged messages (keep stream lean)
  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XTRIM "$stream" MAXLEN '~' 100 > /dev/null 2>&1
}

# Count pending (unacknowledged) triggers
# Usage: trigger_count <officer>
trigger_count() {
  local officer="$1"

  local keys stream group _ids_file
  keys=$(_trigger_keys "$officer")
  IFS='|' read -r stream group _ids_file <<< "$keys"

  redis-cli -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XGROUP CREATE "$stream" "$group" 0 MKSTREAM > /dev/null 2>&1

  local pending
  pending=$(redis-cli --raw -h "$TRIG_REDIS_HOST" -p "$TRIG_REDIS_PORT" \
    XPENDING "$stream" "$group" 2>/dev/null | head -1)

  echo "${pending:-0}"
}

# Echo the per-(officer, project) IDS file path. Useful for callers that
# need to construct the cat | trigger_ack pipeline outside the lib.
# Pool mode: /tmp/.trigger_ids_<officer>_<project>
# Legacy:    /tmp/.trigger_ids_<officer>
trigger_ids_path() {
  # Use ${1:-} so set -u callers don't trip the "unbound variable" trap
  # before our explicit guard runs.
  local officer="${1:-}"
  if [ -z "$officer" ]; then
    echo "trigger_ids_path: officer argument required" >&2
    return 1
  fi
  local keys _stream _group ids_file
  keys=$(_trigger_keys "$officer")
  IFS='|' read -r _stream _group ids_file <<< "$keys"
  echo "$ids_file"
}
