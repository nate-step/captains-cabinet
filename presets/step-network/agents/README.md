# Step Network Preset — Agent Role-Defs

Inheritance pattern: Step Network preset reuses the `presets/work/agents/` role-defs as the baseline (cos, cto, cpo, cro, coo + scaffolds). Project-specialized variants live here per Captain ratification.

## Inheritance source

Default agent role-defs:
- `presets/work/agents/cos.md`
- `presets/work/agents/cto.md`
- `presets/work/agents/cpo.md`
- `presets/work/agents/cro.md`
- `presets/work/agents/coo.md`

Plus the `work` preset's scaffolded archetypes (operations-officer, compliance-officer, executive-assistant) — hire-on-demand per `cabinet/scripts/create-officer.sh`.

## Step-Network-specific archetypes (scaffolded — hire on demand)

These are NOT shipped as default role-defs. CPO authors per project per Captain ratification:

- **`data-analyst.md`** — politiske-annoncer-specific. Capabilities: `analyzes_political_ads`, `queries_external_data`. Specializes in ad-data analysis primitives, regulatory-aware data handling, query authoring against external political-ad datasets. Captain-gate on first-data-source onboarding.

- **`mcp-publisher.md`** — stephie-mcp-specific. Capabilities: `publishes_mcp_catalog`, `validates_mcp_protocol`. Specializes in MCP server publishing flow, catalog metadata curation, Monday.com API ops, MCP-protocol-compliance validation. Captain-gate on first public-namespace publish.

## Pool architecture notes per archetype

All archetypes (inherited + scaffolded) operate under pool architecture per Spec 034 v3 §2b.4:

- One tmux window per (officer, project). Pre-warmed at cabinet boot for default-active project; lazy-spawned for others.
- Per-window env: `CABINET_ACTIVE_PROJECT`, `TELEGRAM_HQ_CHAT_ID`, `OFFICER_DIR` (per-project symlink).
- Hooks read `$CABINET_ACTIVE_PROJECT` per-window for context resolution (Spec 034 v3 AC #28).
- Per-(officer, project) cost counters via `HINCRBY <role>_<project>_cost_micro` (Spec 034 v3 H11/S3).

## Captain-decision authority on adding new archetypes

When Step Network adds a new project that needs a specialized archetype, CPO drafts the role-def alongside the project YAML in the wizard's officer-roster panel. Captain ratifies before the archetype lands. Default archetypes (cos/cto/cpo/cro/coo) cover the vast majority of projects; specialization is opt-in.

## Single-CEO bot mode (Captain msg 2197)

Default for Step Network projects: ONE Telegram bot per project, fronted by CoS (CEO-mode mapping). Other officers (CTO, CPO, CRO, COO + scaffolds) operate inside cabinet but don't have direct Telegram bots. Driver: BotFather 85k rate limit + 20-bot Telegram ceiling per Captain account.

**Officer-to-Captain DM routing under single_ceo (per Spec 034 v3 AC #74):**
- Non-CEO officer creates Captain-attention payload → pushes to Redis queue `cabinet:captain-attention:<project>` with metadata (source officer, urgency tag, summary).
- CoS (CEO-mode) reads the queue (existing post-tool-use trigger pattern) and decides: (a) handle directly, (b) forward to Captain via CoS's Telegram bot with attribution ("CTO surfaced: ..."), or (c) defer + ask source for context.
- Captain replies always go to CoS's Telegram bot. CoS routes Captain reply back to source officer via `notify-officer.sh <source> "<reply>"`.
- Audit trail: every escalation forward logged to `cabinet/logs/captain-attention/<project>.jsonl`.

**Captain UX:** one bot conversation per project. Cleaner than 5 separate per-project bot threads. Officer specialization preserved cabinet-internally.

**Mode is per-project** (set in `instance/config/projects/<slug>.yml` → `telegram.bot_mode: single_ceo | multi_officer`). Projects can mix modes if needed; `single_ceo` is the default for new Step Network projects.
