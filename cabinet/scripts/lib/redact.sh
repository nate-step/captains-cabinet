#!/bin/bash
# cabinet/scripts/lib/redact.sh — Personal-capacity redaction helpers.
#
# STUB (Phase 2 CP1b, not live). Sourced by personal-capacity agents and
# by hooks when a write targets a personal-capacity table. Provides the
# API surface the constitution-addendum §6 and safety-addendum §"Privacy
# redaction defaults" reference. Implementation is deferred until a
# Personal Cabinet is actually standing; stub returns input unchanged
# with a WARN so tests can identify non-redacted paths.
#
# When implemented, these functions will:
# - redact_identifiers: replace proper nouns with role labels ("Captain",
#   "a family member") via a small rules file at instance/config/redaction-rules.yml
# - redact_locations: aggregate precise locations to region-level
# - redact_timestamps: aggregate exact times to day-of-week / time-of-day
#   for sensitive-event patterns
# - redact_numeric_specifics: drop numeric specifics from cross-session
#   summaries while preserving them in single-session review
#
# Usage (when live):
#   source /opt/founders-cabinet/cabinet/scripts/lib/redact.sh
#   safe_text=$(redact_for_log "$raw_text")
#
# Phase 2 ships the interface; Phase 2.5 or the first Personal Cabinet
# session ships the rules + implementation.

redact_for_log() {
  local raw="$1"
  echo "[WARN] redact.sh is a stub — input passed through unchanged. Implement before personal-capacity data hits logs." >&2
  echo "$raw"
}

redact_identifiers() {
  redact_for_log "$1"
}

redact_locations() {
  redact_for_log "$1"
}

redact_timestamps() {
  redact_for_log "$1"
}

redact_numeric_specifics() {
  redact_for_log "$1"
}
