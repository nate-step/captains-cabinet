# Skill: Create a New Officer

**Status:** promoted
**Created by:** CoS + Captain
**Date:** 2026-04-01
**Validated against:** COO creation
**Usage count:** 0

## When to Use

When the Captain requests a new officer, or when CoS identifies a gap in the Cabinet that requires a new role. Officers can be created for any purpose — the default officers (CoS, CTO, CPO, CRO, COO) are suggestions, not limits.

## Prerequisites

- Captain must approve the new officer (this is a governance requirement — Safety Boundaries)
- Captain must create a Telegram bot via @BotFather and provide the bot token
- The bot token serves as proof of Captain authorization

## Workflow

### 1. Propose the Officer

DM the Captain with:
- **Abbreviation:** 2-4 lowercase letters (e.g., `cmo`)
- **Title:** Full role title (e.g., "Chief Marketing Officer")
- **Domain:** What the officer owns (e.g., "Marketing, growth, brand awareness")
- **Rationale:** Why this officer is needed now

### 2. Get Captain Approval + Bot Token

The Captain:
1. Opens @BotFather on Telegram
2. Creates a new bot (name + username)
3. Copies the bot token
4. Sends the token to CoS with approval

### 3. Run the Script

```bash
bash /opt/founders-cabinet/cabinet/scripts/create-officer.sh <abbreviation> "<title>" "<domain>" <bot-username> <bot-token>
```

Example:
```bash
bash /opt/founders-cabinet/cabinet/scripts/create-officer.sh cmo "Chief Marketing Officer" "Marketing, growth, brand" sensed_cmo_bot 1234567890:AAH...
```

The script automatically:
- Creates the role definition (`.claude/agents/<officer>.md`) with a template
- Creates Tier 2 memory directory
- Adds all config entries to `product.yml` (telegram, voice)
- Adds row to `ROLE_REGISTRY.md`
- Saves bot token to `.env`
- Creates a default loop prompt
- Starts the officer in a tmux window
- Announces on the warroom

### 4. Verify

- Check tmux: `tmux list-windows -t cabinet` — officer window should exist
- Check warroom — officer should have announced itself
- DM the officer via Telegram — it should respond

### 5. Customize (post-creation)

The script creates a working officer with sensible defaults. Customize:

1. **Role definition** — Edit `.claude/agents/<officer>.md` to add specific responsibilities, boundaries, and domain knowledge. Replace `[CUSTOMIZE]` markers.
2. **Voice** — Set a voice_id in `config/product.yml` under `voice.voices.<officer>`. Browse: `https://elevenlabs.io/voice-library`
3. **Voice personality** — Edit `voice.naturalize_prompts.<officer>` to give the officer a distinctive character for voice messages.
4. **Loop prompt** — Edit `cabinet/loop-prompts/<officer>.txt` to add officer-specific monitoring (e.g., check Sentry for COO, check research briefs for CRO).
5. **Stability/speed** — Adjust `voice.stability.<officer>` (lower = more creative) and `voice.speeds.<officer>` (0.7-1.2).

### 6. Record Experience

After creating and customizing the officer, record an experience:
```bash
bash /opt/founders-cabinet/cabinet/scripts/record-experience.sh
```

## Expected Outcome

A fully operational officer running in the Cabinet, with Telegram connectivity, voice messaging, and a working role definition. The officer boots, reads its role, and starts processing work immediately.

## Known Pitfalls

- The bot token must be exported in the current shell environment for start-officer.sh to find it. The create-officer.sh script handles this, but if you restart the container, tokens are loaded from `.env` by the entrypoint.
- The default role definition has `[CUSTOMIZE]` markers — the officer will work but won't know its specific responsibilities until you fill these in.
- Voice is disabled for new officers (empty voice_id) until you set one in product.yml.
- If the script fails partway through, it's safe to re-run — all steps are idempotent.

## Origin

Evolved skill — created during COO onboarding, formalized as a repeatable process.
