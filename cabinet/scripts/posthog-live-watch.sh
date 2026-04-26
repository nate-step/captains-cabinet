#!/usr/bin/env bash
# Phase-0 TestFlight live-watch — polls PostHog for the 8-event taxonomy and
# alarms if app_first_open does not appear within 60s of start.
#
# Setup (FW-018 Phase B cross-uid pattern):
#   1. Captain creates a Personal API Key in PostHog (Settings -> Personal API
#      Keys -> Create, scope: project read on the Sensed project).
#   2. Drop the key value to ${KEY_FILE} (default /opt/founders-cabinet/secrets/posthog-cro-key)
#      from host SSH (uid 1001), then post-write:
#         chgrp cabinet $KEY_FILE   # gid 60000 — container reads via group
#         chmod 640    $KEY_FILE
#      (Captain must be in 'cabinet' group on host. bootstrap-host.sh handles this;
#      one-time membership add otherwise.) secrets/ is gitignored.
#   3. Drop the numeric project_id to ${PROJECT_FILE} (default
#      /opt/founders-cabinet/secrets/posthog-project-id) with same chgrp/chmod,
#      or export POSTHOG_PROJECT_ID=<id>.
#   4. Default host: https://eu.posthog.com (EU region, API endpoint).
#      US tenants set POSTHOG_HOST=https://app.posthog.com.
#      eu.i.posthog.com / us.i.posthog.com are INGEST-only hosts — do not use here.
#
# Modes:
#   posthog-live-watch.sh --test                 # API auth + project smoke test only.
#   posthog-live-watch.sh [duration_min] [interval_sec]
#                                                # Default: 5 minutes, 15s poll.

set -euo pipefail

KEY_FILE="${POSTHOG_KEY_FILE:-/opt/founders-cabinet/secrets/posthog-cro-key}"
PROJECT_FILE="${POSTHOG_PROJECT_FILE:-/opt/founders-cabinet/secrets/posthog-project-id}"
HOST="${POSTHOG_HOST:-https://eu.posthog.com}"
EVENTS=(app_first_open dream_capture_started dream_capture_completed ai_response_received session_resumed_d2 session_resumed_d7 prompt_skip_rate ai_response_dismissed)

if [ ! -r "$KEY_FILE" ]; then
  echo "ERROR: $KEY_FILE missing or unreadable." >&2
  echo "       Setup: drop key value, then 'chgrp cabinet \$file && chmod 640 \$file'." >&2
  exit 2
fi
if [ -z "${POSTHOG_PROJECT_ID:-}" ] && [ ! -r "$PROJECT_FILE" ]; then
  echo "ERROR: project id missing." >&2
  echo "       Export POSTHOG_PROJECT_ID=<numeric-id> or write the id to $PROJECT_FILE with chgrp cabinet + chmod 640." >&2
  exit 2
fi

KEY=$(cat "$KEY_FILE")
PROJECT_ID="${POSTHOG_PROJECT_ID:-$(cat "$PROJECT_FILE")}"

if [ "${1:-}" = "--test" ]; then
  CODE=$(curl -sS -o /tmp/.posthog-test-out -w "%{http_code}" \
    -H "Authorization: Bearer $KEY" "$HOST/api/projects/$PROJECT_ID/" || echo "000")
  if [ "$CODE" = "200" ]; then
    NAME=$(python3 -c "import json; print(json.load(open('/tmp/.posthog-test-out')).get('name','?'))")
    echo "OK 200 — auth valid, project '$NAME' accessible."
    rm -f /tmp/.posthog-test-out
    exit 0
  else
    echo "FAIL HTTP $CODE — body in /tmp/.posthog-test-out (no key value logged)." >&2
    exit 1
  fi
fi

DURATION_MIN="${1:-5}"
INTERVAL_SEC="${2:-15}"
START_TS=$(date -u +%s)
END_TS=$((START_TS + DURATION_MIN * 60))
AFTER_ISO=$(date -u -d "@$START_TS" +%Y-%m-%dT%H:%M:%SZ)
APP_FIRST_OPEN_DEADLINE=$((START_TS + 60))
declare -A FIRST_SEEN
ALARMED=0

echo "Watching $HOST project $PROJECT_ID for ${DURATION_MIN}min (poll every ${INTERVAL_SEC}s)."
echo "After: $AFTER_ISO"
echo "Events: ${EVENTS[*]}"
echo "Alarm: app_first_open must appear by $(date -u -d "@$APP_FIRST_OPEN_DEADLINE" +%H:%M:%SZ)"
echo "---"

while [ "$(date -u +%s)" -lt "$END_TS" ]; do
  NOW=$(date -u +%s)
  for E in "${EVENTS[@]}"; do
    [ -n "${FIRST_SEEN[$E]:-}" ] && continue
    COUNT=$(curl -sS -G --max-time 10 \
      -H "Authorization: Bearer $KEY" \
      --data-urlencode "event=$E" \
      --data-urlencode "after=$AFTER_ISO" \
      "$HOST/api/projects/$PROJECT_ID/events/" 2>/dev/null \
      | python3 -c "import sys,json
try: d=json.load(sys.stdin); print(len(d.get('results',[])))
except: print(0)" 2>/dev/null || echo "0")
    if [ "$COUNT" -gt 0 ]; then
      FIRST_SEEN[$E]=$(date -u +%H:%M:%SZ)
      echo "[$(date -u +%H:%M:%SZ)] FIRST $E (count=$COUNT in window)"
    fi
  done
  if [ -z "${FIRST_SEEN[app_first_open]:-}" ] && [ "$ALARMED" -eq 0 ] && [ "$NOW" -ge "$APP_FIRST_OPEN_DEADLINE" ]; then
    echo "[$(date -u +%H:%M:%SZ)] ALARM: app_first_open not observed within 60s. Escalate to CoS + CTO." >&2
    ALARMED=1
  fi
  sleep "$INTERVAL_SEC"
done

echo "---"
echo "Watch window closed."
for E in "${EVENTS[@]}"; do
  if [ -n "${FIRST_SEEN[$E]:-}" ]; then
    echo "  OK  $E (first seen ${FIRST_SEEN[$E]})"
  else
    echo "  --  $E (not observed)"
  fi
done
