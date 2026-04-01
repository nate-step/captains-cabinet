#!/bin/bash
# create-officer.sh — Automate the creation of a new Cabinet Officer
# Creates all required files, config entries, and starts the officer session.
# Designed to be run by CoS after Captain approval.
#
# Usage: create-officer.sh <abbreviation> <title> <domain> <bot-username> <bot-token>
# Example: create-officer.sh cmo "Chief Marketing Officer" "Marketing, growth, brand" sensed_cmo_bot 1234567890:AAH...
#
# Idempotent — safe to run twice. Skips entries that already exist.

set -euo pipefail

# --- Validate arguments ---
OFFICER="${1:?Usage: create-officer.sh <abbreviation> <title> <domain> <bot-username> <bot-token>}"
TITLE="${2:?Missing title (e.g. 'Chief Marketing Officer')}"
DOMAIN="${3:?Missing domain (e.g. 'Marketing, growth, brand')}"
BOT_USERNAME="${4:?Missing bot username from @BotFather}"
BOT_TOKEN="${5:?Missing bot token from @BotFather}"

CABINET_ROOT="/opt/founders-cabinet"
CONFIG_FILE="$CABINET_ROOT/config/product.yml"
ENV_FILE="$CABINET_ROOT/cabinet/.env"
REGISTRY_FILE="$CABINET_ROOT/constitution/ROLE_REGISTRY.md"
OFFICER_UPPER="${OFFICER^^}"
TOKEN_VAR="TELEGRAM_${OFFICER_UPPER}_TOKEN"

# Validate abbreviation format (2-4 lowercase letters)
if ! echo "$OFFICER" | grep -qE '^[a-z]{2,4}$'; then
  echo "Error: Officer abbreviation must be 2-4 lowercase letters (got: $OFFICER)" >&2
  exit 1
fi

# Validate bot token format
if ! echo "$BOT_TOKEN" | grep -qE '^[0-9]+:'; then
  echo "Error: Bot token format looks wrong (expected: 1234567890:AAH...)" >&2
  exit 1
fi

log() { echo "[create-officer] $1"; }

# --- Step 1: Role definition ---
ROLE_FILE="$CABINET_ROOT/.claude/agents/${OFFICER}.md"
if [ -f "$ROLE_FILE" ]; then
  log "SKIP: Role definition already exists at $ROLE_FILE"
else
  log "Creating role definition..."
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
- [CUSTOMIZE: Add any shared interfaces you maintain]

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

# --- Step 2: Tier 2 memory directory ---
TIER2_DIR="$CABINET_ROOT/memory/tier2/${OFFICER}"
mkdir -p "$TIER2_DIR"
touch "$TIER2_DIR/.gitkeep"
log "Ensured: $TIER2_DIR/"

# --- Step 3: Config — telegram.officers ---
if grep -q "    ${OFFICER}:" "$CONFIG_FILE" 2>/dev/null; then
  log "SKIP: $OFFICER already in product.yml"
else
  log "Adding $OFFICER to product.yml..."

  # Add to telegram.officers (after last entry in the section)
  sed -i "/^  officers:/,/^  [a-z]/{
    /^  [a-z]/!{
      /^    [a-z]/H
    }
  }" "$CONFIG_FILE"

  # Simpler approach: append after the last officer entry in each section
  # telegram.officers
  LAST_OFFICER_LINE=$(grep -n "^    [a-z]*:.*bot" "$CONFIG_FILE" | tail -1 | cut -d: -f1)
  if [ -n "$LAST_OFFICER_LINE" ]; then
    sed -i "${LAST_OFFICER_LINE}a\\    ${OFFICER}: ${BOT_USERNAME}" "$CONFIG_FILE"
  fi

  # voice.naturalize_prompts (after last prompt entry — find by looking for long quoted strings after naturalize_prompts)
  LAST_PROMPT_LINE=$(awk '/^  naturalize_prompts:/{found=1} found && /^    [a-z]+:/{last=NR} found && /^  [a-z]/ && !/^  naturalize_prompts:/{exit} END{print last}' "$CONFIG_FILE")
  if [ -n "$LAST_PROMPT_LINE" ]; then
    sed -i "${LAST_PROMPT_LINE}a\\    ${OFFICER}: \"You are the ${TITLE}. Speak naturally and conversationally. Be professional but personable.\"" "$CONFIG_FILE"
  fi

  # voice.models
  LAST_MODEL_LINE=$(awk '/^  models:/{found=1} found && /^    [a-z]+:/{last=NR} found && /^  [a-z]/ && !/^  models:/{exit} END{print last}' "$CONFIG_FILE")
  if [ -n "$LAST_MODEL_LINE" ]; then
    sed -i "${LAST_MODEL_LINE}a\\    ${OFFICER}: eleven_v3" "$CONFIG_FILE"
  fi

  # voice.stability
  LAST_STAB_LINE=$(awk '/^  stability:/{found=1} found && /^    [a-z]+:/{last=NR} found && /^  [a-z]/ && !/^  stability:/{exit} END{print last}' "$CONFIG_FILE")
  if [ -n "$LAST_STAB_LINE" ]; then
    sed -i "${LAST_STAB_LINE}a\\    ${OFFICER}: 0.5" "$CONFIG_FILE"
  fi

  # voice.speeds
  LAST_SPEED_LINE=$(awk '/^  speeds:/{found=1} found && /^    [a-z]+:/{last=NR} found && /^  [a-z]/ && !/^  speeds:/{exit} END{print last}' "$CONFIG_FILE")
  if [ -n "$LAST_SPEED_LINE" ]; then
    sed -i "${LAST_SPEED_LINE}a\\    ${OFFICER}: 1.0" "$CONFIG_FILE"
  fi

  # voice.voices (empty — voice disabled until configured)
  LAST_VOICE_LINE=$(awk '/^  voices:/{found=1} found && /^    [a-z]+:/{last=NR} found && /^  [a-z]/ && !/^  voices:/ && !/^    #/{exit} END{print last}' "$CONFIG_FILE")
  if [ -n "$LAST_VOICE_LINE" ]; then
    sed -i "${LAST_VOICE_LINE}a\\    ${OFFICER}: \"\"                        # Set voice_id from ElevenLabs" "$CONFIG_FILE"
  fi

  log "Added $OFFICER config to product.yml"
fi

# --- Step 4: Constitution — ROLE_REGISTRY.md ---
if grep -qi "$OFFICER" "$REGISTRY_FILE" 2>/dev/null; then
  log "SKIP: $OFFICER already in ROLE_REGISTRY.md"
else
  log "Adding $OFFICER to ROLE_REGISTRY.md..."
  # Find the last row in the Active Officers table and append after it
  LAST_ROW=$(grep -n "^|.*Active" "$REGISTRY_FILE" | tail -1 | cut -d: -f1)
  if [ -n "$LAST_ROW" ]; then
    sed -i "${LAST_ROW}a\\| ${TITLE} (${OFFICER_UPPER}) | ${TITLE} | See config/product.yml | ${DOMAIN} | Active |" "$REGISTRY_FILE"
  fi
  log "Added to ROLE_REGISTRY.md"
fi

# --- Step 5: Bot token in .env ---
if grep -q "$TOKEN_VAR" "$ENV_FILE" 2>/dev/null; then
  log "SKIP: $TOKEN_VAR already in .env"
else
  log "Adding bot token to .env..."
  echo "${TOKEN_VAR}=${BOT_TOKEN}" >> "$ENV_FILE"
  log "Added $TOKEN_VAR to .env"
fi

# Export token for immediate use
export "${TOKEN_VAR}=${BOT_TOKEN}"

# --- Step 6: Loop prompt ---
LOOP_DIR="$CABINET_ROOT/cabinet/loop-prompts"
mkdir -p "$LOOP_DIR"
LOOP_FILE="$LOOP_DIR/${OFFICER}.txt"
if [ ! -f "$LOOP_FILE" ]; then
  echo "Check triggers: redis-cli -h redis -p 6379 LRANGE cabinet:triggers:${OFFICER} 0 -1 — process each, then DEL. Check if reflection is overdue (every 6h). Process anything that needs attention." > "$LOOP_FILE"
  log "Created default loop prompt: $LOOP_FILE"
else
  log "SKIP: Loop prompt already exists"
fi

# --- Step 7: Mark as expected-active in Redis ---
if command -v redis-cli &>/dev/null; then
  redis-cli -h redis -p 6379 SET "cabinet:officer:expected:${OFFICER}" "active" > /dev/null 2>&1
  log "Set cabinet:officer:expected:${OFFICER} = active in Redis"
fi

# --- Step 8: Start the officer ---
log "Starting officer session..."
bash "$CABINET_ROOT/cabinet/scripts/start-officer.sh" "$OFFICER"

# --- Step 9: Announce ---
if [ -n "${TELEGRAM_HQ_CHAT_ID:-}" ]; then
  bash "$CABINET_ROOT/cabinet/scripts/send-to-group.sh" "<b>New officer created: ${OFFICER_UPPER} — ${TITLE}</b>
Domain: ${DOMAIN}
Status: Active, booting now." 2>/dev/null || true
fi

log ""
log "=========================================="
log " Officer ${OFFICER_UPPER} created successfully!"
log "=========================================="
log ""
log "Next steps:"
log "  1. Customize the role definition: .claude/agents/${OFFICER}.md"
log "  2. Set a voice_id in config/product.yml under voice.voices.${OFFICER}"
log "  3. Customize the naturalize prompt in voice.naturalize_prompts.${OFFICER}"
log "  4. Customize the loop prompt in cabinet/loop-prompts/${OFFICER}.txt"
log ""
