# REPLACE_ME Preset

*Copy this directory to `presets/<your-slug>/` and customize every REPLACE_ME marker. This template is NOT a loadable preset — the preset loader skips `_template/`.*

## What this preset is

One-paragraph description: who runs a Cabinet with this preset, what shape
the work takes, what makes this preset different from others.

## Agent archetypes

List each agent role this preset ships. For each, create `agents/<role>.md`
using the template in `_template/agents/TEMPLATE.md`.

## Checklist when creating a new preset

1. `cp -r presets/_template presets/<your-slug>`
2. Fill in `preset.yml` (metadata, archetypes, autonomy)
3. Fill in `terminology.yml` (term mappings)
4. Fill in `constitution-addendum.md` (preset-specific Constitution additions)
5. Fill in `safety-addendum.md` (preset-specific approved integrations + restrictions)
6. Fill in `schemas.sql` (additional tables, or leave empty)
7. Create each agent file under `agents/` (one .md per archetype)
8. Optionally populate `skills/` and `starter-spaces/`
9. Test: `echo <your-slug> > instance/config/active-preset && bash cabinet/scripts/load-preset.sh`
10. Restart officers to pick up the new preset

## Design rules

- **Flat** — do not reference or inherit from other presets. Captain decision 2026-04-16.
- **Additive schemas** — your `schemas.sql` can only add tables, never alter or drop framework tables.
- **Tighten, don't loosen** — your `safety-addendum.md` can only ADD restrictions; never contradict framework base safety rules.
- **Universality test** — every file in your preset should make sense for anyone deploying with this preset, not just the first Captain who wrote it. Instance-specific content goes in `instance/`.
