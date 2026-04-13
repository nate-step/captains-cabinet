#!/bin/bash
# notify-officer.sh — Push a trigger to another Officer via Redis Streams
# The receiving Officer's post-tool-use hook will surface it.
#
# Usage: notify-officer.sh <officer> "Your message here"
# Example: notify-officer.sh cto "New spec ready: feature-x.md"

TARGET="${1:?Usage: notify-officer.sh <cos|cto|cro|cpo|coo> \"message\"}"
MESSAGE="${2:?Usage: notify-officer.sh <officer> \"message\"}"

# Source shared trigger library
. /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh

trigger_send "$TARGET" "$MESSAGE"

echo "Trigger sent to $TARGET"
