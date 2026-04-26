#!/bin/bash
# transcribe-voice.sh — Transcribe a Telegram voice message file to text via ElevenLabs Scribe.
# Usage: transcribe-voice.sh <path-to-audio-file>
# Requires: ELEVENLABS_API_KEY in environment.

FILE="${1:?Usage: transcribe-voice.sh <path-to-audio-file>}"
[ -f "$FILE" ] || { echo "File not found: $FILE" >&2; exit 1; }
[ -n "$ELEVENLABS_API_KEY" ] || { echo "ELEVENLABS_API_KEY not set" >&2; exit 1; }

curl -sS --max-time 60 -X POST "https://api.elevenlabs.io/v1/speech-to-text" \
  -H "xi-api-key: $ELEVENLABS_API_KEY" \
  -F "file=@$FILE" \
  -F "model_id=scribe_v1" | jq -r '.text'
