# presets/ — Use-case configurations

A **preset** is a configuration overlay that adapts the Captain's Cabinet framework for a particular mode of operation. Presets define:

- Which agent archetypes pre-scaffold (work: CoS, CTO, CPO, CRO, COO; personal: coaches)
- Terminology defaults ("officer" vs "coach", "sprint" vs "cycle")
- Constitution and safety addenda specific to the use case
- Additional database schema beyond the framework base
- Default autonomy levels and hook defaults per use case
- Default skill sets and warroom conventions

A preset is **not** a separate codebase, a fork, or an alternate framework. It's a configuration overlay within one framework.

## Shipped presets

| Preset | Status | Description |
|--------|--------|-------------|
| `work/` | Active | Product-team shape: CoS / CTO / CPO / CRO / COO, Linear-or-Library backlog, Notion-or-Library business brain, product repo workspace. |
| `personal/` | Placeholder | Coaching / life-operator shape. Empty until Phase 2 of the Cabinet v2 arc populates it. |
| `_template/` | Template | Skeleton for creating a new preset. Copy to `presets/<your-name>/` and customize. |

## Preset structure

Every preset follows this layout:

```
presets/<name>/
├── preset.yml              # Preset metadata (name, description, agent archetypes, autonomy)
├── terminology.yml         # Term mappings (e.g. "agent" → "officer")
├── constitution-addendum.md  # Preset-specific Constitution additions
├── safety-addendum.md      # Preset-specific safety rules + approved integrations
├── schemas.sql             # Additional database tables for this use case
├── agents/                 # Pre-scaffolded agent definitions (one .md per role)
│   ├── cos.md
│   ├── cto.md
│   └── ...
├── skills/                 # Preset-specific skill defaults
└── starter-spaces/         # Preset-specific Library starter-space templates (optional)
```

Framework files in `framework/` plus the active preset's files compose into the runtime Cabinet state via `cabinet/scripts/load-preset.sh`.

## How the active preset is chosen

`instance/config/active-preset` — a flat file whose only content is the preset slug (e.g. `work`). The loader reads this at container start.

Default: `work`. Forkers who don't change this get the current Sensed-shaped behavior.

## Switching presets

1. Stop officers (cabinet/scripts/suspend-officer.sh on each)
2. Edit `instance/config/active-preset` to the new preset slug
3. Run `cabinet/scripts/load-preset.sh` manually, or restart the container
4. Resume officers

Schema migrations are additive-only (per Captain directive 2026-04-16) — switching presets preserves existing data. To wholesale reset, use `cabinet/scripts/reset-preset-schemas.sh` (opt-in, does NOT run automatically).

## Creating a new preset

```
cp -r presets/_template presets/my-new-preset
$EDITOR presets/my-new-preset/preset.yml
$EDITOR presets/my-new-preset/agents/*.md
# ...customize all _template files...
echo my-new-preset > instance/config/active-preset
# restart officers
```

See `memory/skills/evolved/create-preset.md` for the full skill.

## Inheritance / composition

Locked per Captain decision 2026-04-16: **flat only, no inheritance** until 3+ presets share structure and duplication becomes painful. A preset is self-contained; duplicate content across presets is accepted.
