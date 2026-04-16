# Skill: Create a New Preset

**Status:** draft
**Created by:** CoS, Phase 0 CP6 (2026-04-16)
**Trigger:** The Captain or an officer wants to stand up a new Cabinet preset (beyond `work` and `personal`).

## When to use

You're setting up a Cabinet for a use case that doesn't fit the shipped `work` preset. Examples:
- A coaching Cabinet (Physical Coach, Mindfulness Coach)
- A research Cabinet (Principal Researcher, Literature Scout)
- An ops Cabinet (Incident Commander, Compliance Officer)
- A consulting Cabinet (Engagement Lead, Associate)

The `work` preset works for most product/operator setups. Only create a new preset if the agent archetypes, terminology, autonomy level, or default integrations differ meaningfully.

## Steps

### 1. Copy the template

```bash
cp -r presets/_template presets/<your-slug>
```

Replace `<your-slug>` with a lowercase hyphen-separated name (e.g. `coaching`, `research`, `ops-incident`).

### 2. Fill in `preset.yml`

Edit `presets/<your-slug>/preset.yml`:

- `name`: same as your slug
- `description`: 2-3 sentences on who uses this preset and what shape their work takes
- `agent_archetypes`: the list of agent role abbreviations this preset ships with
- `terminology`: a quick mapping (agent_role, work_unit)
- `autonomy_level`: `execution_high` | `execution_medium` | `execution_low` | `consent_gated`
- `workspace_mount`: where the preset expects its primary workspace (Docker volume or host path)

### 3. Fill in `terminology.yml`

Full term mappings. Cover agent_role, captain_title (if different — usually stays "Captain"), crew_title, work_unit, work_body, backlog, business_brain.

### 4. Write `constitution-addendum.md`

This is what extends `framework/constitution-base.md` for your preset. Focus on:
- **What this Cabinet does** — the shape of work
- **Knowledge Systems** — the external services + internal Library Spaces your preset uses
- **Quality Standards** — domain-specific quality rules beyond the framework base
- **Preset-Specific Capabilities** — capability-to-role mapping for hook routing

Do NOT duplicate content already in the framework base. Only add what's specific.

### 5. Write `safety-addendum.md`

Adds restrictions. Never relaxes the framework base. Must include:
- **Approved External Integrations** table (every service your preset can talk to)
- **Preset-Specific Prohibited Actions** — actions only prohibited for this preset (not universally)

### 6. Fill in `schemas.sql`

Additional database tables needed by this preset. Rules:
- **Additive only** — never DROP or ALTER framework tables
- **CREATE TABLE IF NOT EXISTS** throughout (idempotent)
- **No overlap** with framework base or other preset tables (Captain decision 2026-04-16)

### 7. Create agent files

For each `agent_archetypes` entry, create `presets/<your-slug>/agents/<abbreviation>.md` using `_template/agents/TEMPLATE.md` as a starting point. Fill in identity, responsibilities, tools, skills, escalation triggers.

### 8. Optional: starter skills and starter-spaces

- `presets/<your-slug>/skills/` — drop in skill files your agents should have loaded by default
- `presets/<your-slug>/starter-spaces/` — JSON templates for Library Spaces this preset ships with

### 9. Test the preset loader

```bash
echo <your-slug> > instance/config/active-preset
bash cabinet/scripts/load-preset.sh
```

Expected output:
- "Loading preset: <your-slug>"
- "Assembled constitution → /tmp/cabinet-runtime/constitution.md (N lines)"
- "Assembled safety boundaries → /tmp/cabinet-runtime/safety-boundaries.md"
- "Applied framework schema: cabinet_memory.sql", etc.
- "Applied preset schema: <your-slug>/schemas.sql"
- "Populated agents from preset: N files"
- "Preset '<your-slug>' loaded successfully"

If any step fails, fix the underlying file and re-run. The loader is idempotent.

### 10. Restart officers to pick up the new preset

Officers need to restart to re-read the assembled `/tmp/cabinet-runtime/` files and the new `.claude/agents/*.md` populated by the loader.

```bash
for officer in $(cat presets/<your-slug>/preset.yml | grep -A100 agent_archetypes | grep "^\s*-" | awk '{print $2}'); do
  bash cabinet/scripts/suspend-officer.sh "$officer" "Switching preset"
done
# Then re-launch each with start-officer.sh
```

## Design rules (locked)

- **Flat** — no inheritance between presets. Duplicate content across presets is accepted until 3+ presets share structure.
- **Additive schemas** — see step 6.
- **Tighten, don't loosen** — safety-addendum can only ADD restrictions.
- **Universality** — every file in your preset should make sense for anyone deploying with this preset, not just the first Captain who wrote it. Instance-specific content goes in `instance/`.

## Rolling back

If a new preset doesn't work out:

```bash
echo work > instance/config/active-preset  # revert to work preset
bash cabinet/scripts/load-preset.sh        # reload
# restart officers
```

The broken preset stays on disk at `presets/<your-slug>/` — no damage to other presets. Delete when you're ready.

## Promotion

When a preset is validated in use (weeks of active use by the Captain or an operator), propose promotion to the framework repo via a pull request so other forkers can use it too.

## Origin

Created during Phase 0 CP6 as part of the preset infrastructure refactor (GitHub #22). The _template shape was chosen to minimize boilerplate while forcing preset authors to think about each layer (metadata, terminology, constitution, safety, schemas, agents).
