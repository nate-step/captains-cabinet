#!/bin/bash
# create-officer.sh — Automate the creation of a new Cabinet Officer
# Creates all required files, config entries, and starts the officer session.
# Designed to be run by CoS after Captain approval, or via the dashboard UI.
#
# Usage: create-officer.sh <abbreviation> <title> <domain> <bot-username> <bot-token> [options]
#
# Options (all optional — sensible defaults used if omitted):
#   --voice-id <id>           ElevenLabs voice ID (empty = voice disabled)
#   --voice-prompt <text>     Voice personality prompt for naturalization
#   --voice-stability <0-1>   Voice stability (0=creative, 1=consistent, default: 0.5)
#   --voice-speed <0.7-1.2>   Speech speed (default: 1.0)
#   --interface <name>        Shared interface filename (e.g. "operational-health")
#   --loop-prompt <text>      Custom polling loop prompt
#   --no-start                Don't start the officer session (just create files)
#
# Example:
#   create-officer.sh cmo "Chief Marketing Officer" "Marketing, growth, brand" \
#     sensed_cmo_bot 1234567890:AAH... \
#     --voice-id "abc123" --voice-prompt "Speaks like an excited marketer" \
#     --voice-stability 0.4 --voice-speed 1.1 \
#     --interface "marketing-briefs"
#
# Idempotent — safe to run twice. Skips entries that already exist.

set -euo pipefail

# --- Parse required arguments ---
OFFICER="${1:?Usage: create-officer.sh <abbreviation> <title> <domain> <bot-username> <bot-token> [options]}"
TITLE="${2:?Missing title (e.g. 'Chief Marketing Officer')}"
DOMAIN="${3:?Missing domain (e.g. 'Marketing, growth, brand')}"
BOT_USERNAME="${4:?Missing bot username from @BotFather}"
BOT_TOKEN="${5:?Missing bot token from @BotFather}"
shift 5

# --- Parse optional arguments ---
VOICE_ID=""
VOICE_PROMPT=""
VOICE_STABILITY="0.5"
VOICE_SPEED="1.0"
INTERFACE_NAME=""
LOOP_PROMPT_TEXT=""
DO_START=true

while [ $# -gt 0 ]; do
  case "$1" in
    --voice-id) VOICE_ID="$2"; shift 2 ;;
    --voice-prompt) VOICE_PROMPT="$2"; shift 2 ;;
    --voice-stability) VOICE_STABILITY="$2"; shift 2 ;;
    --voice-speed) VOICE_SPEED="$2"; shift 2 ;;
    --interface) INTERFACE_NAME="$2"; shift 2 ;;
    --loop-prompt) LOOP_PROMPT_TEXT="$2"; shift 2 ;;
    --no-start) DO_START=false; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

CABINET_ROOT="/opt/founders-cabinet"
CONFIG_FILE="$CABINET_ROOT/config/product.yml"
ENV_FILE="$CABINET_ROOT/cabinet/.env"
ENV_EXAMPLE="$CABINET_ROOT/cabinet/.env.example"
REGISTRY_FILE="$CABINET_ROOT/constitution/ROLE_REGISTRY.md"
OFFICER_UPPER="${OFFICER^^}"
TOKEN_VAR="TELEGRAM_${OFFICER_UPPER}_TOKEN"

# Default voice prompt if not provided
if [ -z "$VOICE_PROMPT" ]; then
  VOICE_PROMPT="You are the ${TITLE}. Speak naturally and conversationally. Be professional but personable."
fi

# Default loop prompt if not provided
if [ -z "$LOOP_PROMPT_TEXT" ]; then
  LOOP_PROMPT_TEXT="Triggers auto-deliver via hook. Manual check: source /opt/founders-cabinet/cabinet/scripts/lib/triggers.sh && trigger_read ${OFFICER}. Check if reflection is overdue (every 6h). Process anything that needs attention."
fi

# --- Validate inputs ---
if ! echo "$OFFICER" | grep -qE '^[a-z]{2,4}$'; then
  echo "Error: Officer abbreviation must be 2-4 lowercase letters (got: $OFFICER)" >&2
  exit 1
fi

if ! echo "$BOT_TOKEN" | grep -qE '^[0-9]+:'; then
  echo "Error: Bot token format looks wrong (expected: 1234567890:AAH...)" >&2
  exit 1
fi

log() { echo "[create-officer] $1"; }

log "Creating officer: ${OFFICER_UPPER} — ${TITLE}"
log "Domain: ${DOMAIN}"
log ""

# === Step 1: Role definition ===
ROLE_FILE="$CABINET_ROOT/.claude/agents/${OFFICER}.md"
if [ -f "$ROLE_FILE" ]; then
  log "SKIP: Role definition already exists at $ROLE_FILE"
else
  log "Creating role definition..."

  # Build shared interface line for role definition
  INTERFACE_LINE=""
  if [ -n "$INTERFACE_NAME" ]; then
    INTERFACE_LINE="- \`shared/interfaces/${INTERFACE_NAME}.md\` — your operational output"
  fi

  cat > "$ROLE_FILE" << ROLEEOF
# ${TITLE} (${OFFICER_UPPER})

## Identity

You are the ${TITLE}. [CUSTOMIZE: Define your core purpose and what makes this role unique.]

## Domain of Ownership

- **[CUSTOMIZE: Primary area]:** Description of what you own
- **[CUSTOMIZE: Secondary area]:** Description of what you own

## Autonomy Boundaries

### You CAN (without Captain approval):
- [CUSTOMIZE: List autonomous actions]
- File issues in Linear with relevant labels
- Notify other Officers via notify-officer.sh
- Update your Tier 2 working notes
- Record experiences via record-experience.sh

### You CANNOT (requires Captain approval):
- [CUSTOMIZE: List restricted actions]
- Deploy to production
- Modify Constitution or Safety Boundaries
- Create or retire other Officers

## Quality Standards

Follow foundation skills in \`memory/skills/\`:
- \`individual-reflection.md\` — self-review every 6h
- \`telegram-communication.md\` — message formatting, file sharing, reply-to-message

## Shared Interfaces

### Reads from:
- \`constitution/CONSTITUTION.md\` — operating principles
- \`constitution/SAFETY_BOUNDARIES.md\` — hard limits
- \`config/product.yml\` — product configuration
- \`shared/interfaces/\` — cross-officer artifacts

### Writes to:
- \`memory/tier2/${OFFICER}/\` — your working notes
${INTERFACE_LINE}

## Communication

### Telegram
- Post updates to Warroom group: \`bash /opt/founders-cabinet/cabinet/scripts/send-to-group.sh "message"\`
- Read \`product.captain_name\` from config and address the founder by name

### Experience Records
After significant tasks: \`bash /opt/founders-cabinet/cabinet/scripts/record-experience.sh\`

### Cross-Officer Communication
Notify other Officers: \`bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh <target> "message"\`

## Session Start Checklist

1. Read the Constitution and Safety Boundaries
2. Read your role definition (this file)
3. Read your Tier 2 working notes (\`memory/tier2/${OFFICER}/\`)
4. Read foundation skills in \`memory/skills/\`
5. Check for pending triggers and overdue work
6. Set up your polling loop (see loop prompt)
ROLEEOF
  log "Created: $ROLE_FILE"
fi

# === Step 2: Tier 2 memory directory ===
TIER2_DIR="$CABINET_ROOT/memory/tier2/${OFFICER}"
mkdir -p "$TIER2_DIR"
touch "$TIER2_DIR/.gitkeep"
log "Ensured: $TIER2_DIR/"

# === Step 3: Shared interface file ===
if [ -n "$INTERFACE_NAME" ]; then
  INTERFACE_FILE="$CABINET_ROOT/shared/interfaces/${INTERFACE_NAME}.md"
  if [ -f "$INTERFACE_FILE" ]; then
    log "SKIP: Shared interface already exists at $INTERFACE_FILE"
  else
    cat > "$INTERFACE_FILE" << IFEOF
# ${TITLE} — ${INTERFACE_NAME}

**Updated by:** ${OFFICER_UPPER}
**Last updated:** —

## Status

[${OFFICER_UPPER} will populate this file with operational data]
IFEOF
    log "Created: $INTERFACE_FILE"
  fi
fi

# === Step 4: Product config (product.yml) ===
# Use anchored grep to avoid matching officer name inside prompt text
if awk '/^  voices:/{v=1} v && /^[[:space:]]*'"${OFFICER}"':/{found=1; exit} END{exit !found}' "$CONFIG_FILE" 2>/dev/null; then
  log "SKIP: $OFFICER already in product.yml voice config"
else
  log "Adding $OFFICER to product.yml..."

  # telegram.officers
  LAST_OFFICER_LINE=$(grep -n "^    [a-z]*:.*bot" "$CONFIG_FILE" | tail -1 | cut -d: -f1)
  if [ -n "$LAST_OFFICER_LINE" ]; then
    sed -i "${LAST_OFFICER_LINE}a\\    ${OFFICER}: ${BOT_USERNAME}" "$CONFIG_FILE"
  fi

  # voice.naturalize_prompts
  LAST_PROMPT_LINE=$(awk '/^voice:/{v=1} v && /^  naturalize_prompts:/{found=1} found && /^    [a-z]+:/{last=NR} found && /^  [a-z]/ && !/^  naturalize_prompts:/{exit} END{print last}' "$CONFIG_FILE")
  if [ -n "$LAST_PROMPT_LINE" ]; then
    ESCAPED_PROMPT=$(echo "$VOICE_PROMPT" | sed 's/"/\\"/g')
    awk -v line="$LAST_PROMPT_LINE" -v entry="    ${OFFICER}: \"${ESCAPED_PROMPT}\"" 'NR==line{print; print entry; next}1' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
  fi

  # voice.models
  LAST_MODEL_LINE=$(awk '/^voice:/{v=1} v && /^  models:/{found=1} found && /^    [a-z]+:/{last=NR} found && /^  [a-z]/ && !/^  models:/{exit} END{print last}' "$CONFIG_FILE")
  if [ -n "$LAST_MODEL_LINE" ]; then
    sed -i "${LAST_MODEL_LINE}a\\    ${OFFICER}: eleven_v3" "$CONFIG_FILE"
  fi

  # voice.stability
  LAST_STAB_LINE=$(awk '/^voice:/{v=1} v && /^  stability:/{found=1} found && /^    [a-z]+:/{last=NR} found && /^  [a-z]/ && !/^  stability:/{exit} END{print last}' "$CONFIG_FILE")
  if [ -n "$LAST_STAB_LINE" ]; then
    sed -i "${LAST_STAB_LINE}a\\    ${OFFICER}: ${VOICE_STABILITY}" "$CONFIG_FILE"
  fi

  # voice.speeds
  LAST_SPEED_LINE=$(awk '/^voice:/{v=1} v && /^  speeds:/{found=1} found && /^    [a-z]+:/{last=NR} found && /^  [a-z]/ && !/^  speeds:/{exit} END{print last}' "$CONFIG_FILE")
  if [ -n "$LAST_SPEED_LINE" ]; then
    sed -i "${LAST_SPEED_LINE}a\\    ${OFFICER}: ${VOICE_SPEED}" "$CONFIG_FILE"
  fi

  # voice.voices
  LAST_VOICE_LINE=$(awk '/^voice:/{v=1} v && /^  voices:/{found=1} found && /^    [a-z]+:/{last=NR} found && /^  [a-z]/ && !/^  voices:/ && !/^    #/{exit} END{print last}' "$CONFIG_FILE")
  if [ -n "$LAST_VOICE_LINE" ]; then
    if [ -n "$VOICE_ID" ]; then
      sed -i "${LAST_VOICE_LINE}a\\    ${OFFICER}: \"${VOICE_ID}\"" "$CONFIG_FILE"
    else
      sed -i "${LAST_VOICE_LINE}a\\    ${OFFICER}: \"\"                        # Set voice_id from ElevenLabs" "$CONFIG_FILE"
    fi
  fi

  log "Added $OFFICER voice config to product.yml"
fi

# === Step 5: Constitution — ROLE_REGISTRY.md ===
if grep -qi "^|.*${OFFICER_UPPER}" "$REGISTRY_FILE" 2>/dev/null; then
  log "SKIP: $OFFICER already in ROLE_REGISTRY.md"
else
  log "Adding $OFFICER to ROLE_REGISTRY.md..."
  LAST_ROW=$(grep -n "^|.*Active" "$REGISTRY_FILE" | tail -1 | cut -d: -f1)
  if [ -n "$LAST_ROW" ]; then
    sed -i "${LAST_ROW}a\\| ${TITLE} (${OFFICER_UPPER}) | ${TITLE} | See config/product.yml | ${DOMAIN} | Active |" "$REGISTRY_FILE"
  fi
  log "Added to ROLE_REGISTRY.md"
fi

# === Step 6: Bot token in .env ===
if grep -q "^${TOKEN_VAR}=" "$ENV_FILE" 2>/dev/null; then
  log "SKIP: $TOKEN_VAR already in .env"
else
  log "Adding bot token to .env..."
  echo "${TOKEN_VAR}=${BOT_TOKEN}" >> "$ENV_FILE"
  log "Added $TOKEN_VAR to .env"
fi

# Update .env.example too (without the actual token)
if [ -f "$ENV_EXAMPLE" ] && ! grep -q "^${TOKEN_VAR}=" "$ENV_EXAMPLE" 2>/dev/null; then
  echo "${TOKEN_VAR}=" >> "$ENV_EXAMPLE"
  log "Added $TOKEN_VAR placeholder to .env.example"
fi

# Export token for immediate use
export "${TOKEN_VAR}=${BOT_TOKEN}"

# === Step 7: Loop prompt ===
LOOP_DIR="$CABINET_ROOT/cabinet/loop-prompts"
mkdir -p "$LOOP_DIR"
LOOP_FILE="$LOOP_DIR/${OFFICER}.txt"
if [ ! -f "$LOOP_FILE" ]; then
  echo "$LOOP_PROMPT_TEXT" > "$LOOP_FILE"
  log "Created loop prompt: $LOOP_FILE"
else
  log "SKIP: Loop prompt already exists"
fi

# === Step 8: Mark as expected-active in Redis ===
if command -v redis-cli &>/dev/null; then
  redis-cli -h redis -p 6379 SET "cabinet:officer:expected:${OFFICER}" "active" > /dev/null 2>&1
  log "Set cabinet:officer:expected:${OFFICER} = active in Redis"
fi

# === Step 9: Start the officer ===
if [ "$DO_START" = true ]; then
  log "Starting officer session..."
  bash "$CABINET_ROOT/cabinet/scripts/start-officer.sh" "$OFFICER"
else
  log "SKIP: --no-start flag set, not starting officer session"
fi

# === Step 10: Announce ===
if [ "$DO_START" = true ] && [ -n "${TELEGRAM_HQ_CHAT_ID:-}" ]; then
  VOICE_STATUS="disabled"
  [ -n "$VOICE_ID" ] && VOICE_STATUS="enabled"
  bash "$CABINET_ROOT/cabinet/scripts/send-to-group.sh" "<b>New officer created: ${OFFICER_UPPER} — ${TITLE}</b>
Domain: ${DOMAIN}
Voice: ${VOICE_STATUS}
Status: Active, booting now." 2>/dev/null || true
fi

log ""
log "=========================================="
log " Officer ${OFFICER_UPPER} created successfully!"
log "=========================================="
log ""
log "Created:"
log "  Role definition:     .claude/agents/${OFFICER}.md"
log "  Tier 2 memory:       memory/tier2/${OFFICER}/"
[ -n "$INTERFACE_NAME" ] && log "  Shared interface:    shared/interfaces/${INTERFACE_NAME}.md"
log "  Loop prompt:         cabinet/loop-prompts/${OFFICER}.txt"
log "  Voice config:        product.yml (model=eleven_v3, stability=${VOICE_STABILITY}, speed=${VOICE_SPEED})"
[ -n "$VOICE_ID" ] && log "  Voice ID:            ${VOICE_ID}" || log "  Voice ID:            NOT SET — voice disabled until configured"
log ""
if grep -q "\[CUSTOMIZE\]" "$ROLE_FILE" 2>/dev/null; then
  log "⚠  Role definition has [CUSTOMIZE] markers — edit .claude/agents/${OFFICER}.md to complete it"
fi
[ -z "$VOICE_ID" ] && log "⚠  No voice ID set — set one in product.yml under voice.voices.${OFFICER}"
log ""
