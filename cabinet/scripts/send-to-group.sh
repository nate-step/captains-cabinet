#!/bin/bash
# send-to-group.sh — Legacy wrapper, auto-routes to sensed-warroom.
#
# Phase 1 CP7 (Captain decision 2026-04-16 CD3: auto-migrate existing
# send-to-group calls to sensed-warroom). Preserves the original CLI
# signature so every existing caller keeps working. New code should call
# send-to-warroom.sh directly with an explicit context.
#
# Usage: send-to-group.sh "Your message here"

MESSAGE="${1:?Usage: send-to-group.sh \"message\"}"

exec bash /opt/founders-cabinet/cabinet/scripts/send-to-warroom.sh sensed "$MESSAGE"
