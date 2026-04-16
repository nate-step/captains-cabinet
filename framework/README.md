# framework/ — Universal Cabinet base

Everything in this directory ships with the Captain's Cabinet framework and is **universal** — used by every Cabinet regardless of preset, use case, or operator role. When you fork the repo, treat `framework/` as read-only under normal operation. Changes here are framework-wide and flow through git to every deployment.

## What lives here

| File | Purpose |
|------|---------|
| `constitution-base.md` | Universal Constitution — identity, work principles, communication, quality, self-improvement, model usage. Assembled with the active preset's `constitution-addendum.md` at container start to form the runtime Constitution every Officer reads. |
| `safety-boundaries-base.md` | Universal safety rules — Captain approvals required, spending limits, retry limits, scope boundaries, kill switch, prohibited actions. Active preset's `safety-addendum.md` can ADD restrictions (never relax). |
| `schemas-base.sql` | Base database schema used by every Cabinet: `experience_records`, `decision_log`, `cabinet_memory`, `library_spaces`, `library_records`. |

## What is NOT here

Content that is specific to one use case, domain, or operator belongs in **`presets/<name>/`** (see `presets/README.md`).

Content specific to one particular Cabinet deployment (this Captain's product, this Captain's Notion workspace, this Cabinet's Tier 2 working notes) belongs in **`instance/`** (see `instance/README.md`).

## The three-layer model

```
framework/   — universal, ships with the repo
  + presets/<active>/   — reusable configuration for a use case (work, personal, …)
  + instance/           — this specific Cabinet's deployment (product, bots, working notes)
  = runtime Cabinet state
```

The **preset loader** (`cabinet/scripts/load-preset.sh`, wired into `cabinet/scripts/start-officer.sh`) concatenates the three layers at container start:

1. Framework base as foundation.
2. Preset addenda overlaid.
3. Instance overrides on top.

Officers read the assembled output from the runtime path the loader produces.

## Terminology note

`cabinet-v2.md` (Captain directive 2026-04-16) uses the term "profile" throughout. The locked implementation uses "**preset**" — a terminology decision made to avoid overloading with user profiles, OS profiles, AWS profiles, etc. Mentally substitute as you read.

## Framework-classified artifacts outside this directory

For historical and architectural reasons, some universal framework components live outside `framework/` in well-known locations:

- `cabinet/scripts/` — shell libraries, hooks, and cron scripts (framework; used by every preset)
- `cabinet/sql/` — Library + Cabinet Memory schema files (framework)
- `cabinet/channels/` — MCP servers (framework)
- `cabinet/dashboard/` — Next.js operator UI (framework)
- `cabinet/starter-spaces/` — Library starter-space JSON templates (framework; spaces are generic)
- `cabinet/Dockerfile.officer` and related Docker files (framework infrastructure)

These stay in `cabinet/` because they're physical artifacts (containers, SQL schemas, server code) — the logical classification is framework, but the physical layout is pragmatic. `framework/` is for LAYERABLE TEXT (constitution, safety, schema additions) that gets assembled into the runtime Cabinet state by the loader.

## Editing framework content

Framework changes are strictly-reviewed and flow through git commits. They affect every forker on next pull. Only the coordinating officer, with Captain approval, amends `framework/` files.
