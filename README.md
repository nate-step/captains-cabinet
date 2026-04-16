# Captain's Cabinet

An autonomous AI organization that builds, ships, and improves your work — while you steer from Telegram.

## What This Is

The Captain's Cabinet is a framework for running a 24/7 AI development organization. You are the Captain. AI Officers own domains (product, engineering, research). They coordinate, execute, learn, and improve — continuously.

This repo is the **infrastructure**. It contains the organizational framework, memory system, safety boundaries, and Docker configuration. Your product repo is separate — the Cabinet mounts it as a workspace.

## How It Works

```
You (Captain)
  ↕ Telegram
Cabinet (this repo)
├── CoS — orchestration, briefings, self-improvement
├── CTO — engineering, code, deploys
├── CPO — product specs, backlog, prioritization
├── CRO — market research, competitive intel, trends
└── COO — operations, deployment validation, uptime
  ↕ reads/writes
Your Product Repo (mounted at /workspace/product)
```

Each Officer runs as a persistent Claude Code session with Telegram Channels. They read strategy from Notion, execute tasks from Linear, write code in your repo, and report back via Telegram.

Officer sets are fully configurable per deployment — add, remove, or rename Officers in `config/platform.yml`. The framework is officer-agnostic.

## Quick Start

### 1. Fork This Repo

Click **Fork** on https://github.com/nate-step/captains-cabinet, then clone your fork:

```bash
git clone https://github.com/YOUR-GITHUB-USERNAME/captains-cabinet.git
cd captains-cabinet
```

### 2. Set Up Notion

The bootstrap script creates the entire Cabinet HQ workspace structure automatically:

```bash
export NOTION_API_KEY="your-notion-internal-integration-token"
bash cabinet/scripts/bootstrap-notion.sh "YourProductName"
```

This creates all pages and databases and writes the IDs to `config/product.yml`. Then add your strategy docs (vision, brand guidelines, etc.) to the Business Brain section.

### 3. Configure Your Product and Platform

Edit two config files:

- `config/product.yml` — what you're building: product name, Notion IDs, Linear workspace, Neon project, voice settings, Telegram bots
- `config/platform.yml` — how the Cabinet operates: timezone, accountability tone, communication preferences, briefing cadence, officer set (fulltime vs consultant)

### 4. Set Up Telegram Bots

Create one bot per Officer via @BotFather (default set: CoS, CTO, CPO, CRO, COO — 5 bots) and a "YourProduct HQ" group. You can add or remove Officers later via `bash cabinet/scripts/create-officer.sh` and `cabinet/scripts/suspend-officer.sh`.

### 5. Fill In Credentials

```bash
cp cabinet/.env.example cabinet/.env
# Fill in all API keys and tokens
```

### 6. Deploy

```bash
# On your server (Hetzner/DO/AWS, Ubuntu 24.04)
# Clone into the location you want — we use /opt/cabinet as an example
cd /opt/cabinet/cabinet
docker compose build
docker compose up -d postgres redis
docker compose up -d officers watchdog
```

### 7. Start Your First Officer

```bash
docker exec -it cabinet-officers bash
./start-officer.sh cos
# Authenticate with claude /login (one-time)
# Pair Telegram bot
# Send: "Read the Constitution and report for duty"
```

## Architecture

| Component | Purpose |
|-----------|---------|
| **Officers** | Persistent Claude Code CLI sessions in tmux, one per domain |
| **Crew** | Agent Teams spawned by Officers for parallel execution |
| **Notion** | Business brain — strategy, research, decisions (default; replaceable — see `config/product.yml`) |
| **Linear** | Execution backlog — what to build (default; replaceable — see GitHub #16) |
| **Neon (PostgreSQL + pgvector)** | Cabinet Memory layer — universal semantic search over all Cabinet-produced text (Telegram, triggers, decisions, specs, research, reflections). Query via `bash cabinet/scripts/search-memory.sh "<query>"`. |
| **Redis** | Kill switch, rate limits, state flags |
| **Watchdog** | Health checks, cost tracking, cron triggers, alerts |
| **Telegram** | Captain's command interface |

## The Five Pillars

1. **Dynamic Roles** — Officers are markdown files, not code. Restructure the org in one message.
2. **The Operator as Captain** — You set direction, the Cabinet figures out how. Works for founders, employees, team leads, solo operators — anyone running a system that benefits from always-on AI delegation.
3. **Memory That Compounds** — Three tiers: always-loaded constitution, working notes, episodic recall.
4. **Self-Improvement Loops** — Three nested loops: Task (per-task log entries), Reflection (event-triggered — after compaction or completion milestones), Evolution (cross-officer retro every 5 reflections or 48h, whichever first). Foundation skills ship with the repo and improve over time.
5. **Safety Boundaries** — Hard limits enforced by hooks and Redis. Read-only constitution. Kill switch.

## Repo Structure

```
founders-cabinet/
├── .claude/agents/          # Officer role definitions (identity, not procedures)
├── cabinet/
│   ├── scripts/             # All Cabinet tooling (hooks, supervisor, memory lib, notify, etc.)
│   ├── sql/                 # Schema migrations (cabinet_memory.sql, future kb_spaces, ...)
│   ├── cron/                # Scheduled triggers (briefings, research sweeps, retro)
│   ├── channels/            # MCP plugins (Redis trigger channel, etc.)
│   ├── dashboard/           # Next.js operator dashboard
│   └── Dockerfile.officer   # Per-officer container image
├── config/
│   ├── product.yml          # What you're building (product name, Notion IDs, bots, voice)
│   └── platform.yml         # How the Cabinet operates (timezone, comms, cadence, officer set)
├── constitution/            # Governance (read-only at runtime)
├── memory/
│   ├── skills/              # Foundation + promoted skills (procedures, quality gates)
│   ├── golden-evals/        # Validation scenarios for Cabinet changes
│   ├── tier2/               # Officer working notes (per-role)
│   └── tier3/               # Experience records, decision log, research archive
├── shared/                  # Inter-Officer interfaces (specs, decisions, tech radar)
├── CLAUDE.md                # Root context loaded every session
└── captains-cabinet-guide.md # The theory document
```

## Customization

Everything is configured in `config/product.yml` and `cabinet/.env`. Key options:

### Voice Messages (optional)
Officers can send voice messages alongside text via ElevenLabs TTS. Each officer has their own voice.

```yaml
# config/product.yml
voice:
  enabled: true                  # false by default
  model: eleven_flash_v2_5       # fastest model
  mode: all                      # all | captain-dm | group | briefings
  voices:
    cos: "7ceZgj78jCCeAW93ItNk" # override with your own voice_ids
    cto: "AMNzDFTtLuyoKAL3YPnu"
    cpo: "sgk995upfe3tYLvoGcBN"
    cro: "77aEIu0qStu8Jwv1EdhX"
    coo: "YOUR_COO_VOICE_ID"
```

Browse voices at [elevenlabs.io/voice-library](https://elevenlabs.io/voice-library) or via API. Requires `ELEVENLABS_API_KEY` in `.env`.

### Image Generation (optional)
Officers can generate images via Google Gemini (Nano Banana 2) and send them through Telegram. Requires `GOOGLE_API_KEY` in `.env`.

### Improvement Cadences
Default cadences in `CLAUDE.md`:
- **Individual reflection:** event-triggered (after compaction or completion milestones — don't reflect on nothing)
- **Cross-officer retro:** event-triggered (fires at 5 accumulated reflections or 48h since last — whichever first)
- **Evolution loop:** runs alongside retro (Phase 1 retro, Phase 2 skill promotion)

### Foundation Skills
Ship with the repo in `memory/skills/`. Officers follow these as baseline procedures. The learning loop can improve them by writing evolved versions to `memory/skills/evolved/` — foundation files are never modified directly.

### What to Customize After Forking
1. `config/product.yml` — your product name, Notion IDs, Linear workspace, Telegram bots, voice settings
2. `config/platform.yml` — your timezone, accountability tone, briefing cadence, officer set (fulltime vs consultant)
3. `cabinet/.env` — all API keys and tokens (copy from `cabinet/.env.example`)
4. `cabinet/officer-capabilities.conf` — map your officers to capabilities (deploys_code, reviews_specs, etc.)
5. `constitution/CONSTITUTION.md` — your operating principles (optional)
6. `.claude/agents/*.md` — officer identity if you add domain-specific context (optional)

## Requirements

- **Server:** Ubuntu 24.04 with Docker (Hetzner CPX31 recommended)
- **Claude:** Max 20x subscription ($200/mo) for 4–5 Officers
- **Notion:** Business plan (for MCP integration)
- **Telegram:** One bot token per Officer (default 5) + group chat
- **APIs (required):** Linear, Neon, Voyage AI, Perplexity, Brave Search, Exa
- **APIs (optional):** ElevenLabs (voice messages), Google Gemini (image generation)

## Safety

- Kill switch halts all operations instantly via Telegram or Redis
- Constitution and safety boundaries are read-only mounts
- Pre-tool-use hooks block prohibited actions programmatically
- Spending caps enforced per-session, per-day, per-month via Redis
- Permission inheritance: Crew never exceed Officer boundaries
- Escalation chain: Crew → Officer → CoS → Captain

## License

**Business Source License 1.1** (see [`LICENSE`](./LICENSE))

Free to fork, self-host, modify, and use internally. Commercial hosted/managed offerings competing with the Licensor's paid service are reserved to the Licensor until the Change Date (4 years after each version's publication), at which point that version converts to Apache 2.0.

Short version: if you're a team running the Cabinet for your own organization — whether as a founder, an employee, a solo operator, or anything in between — go ahead. If you want to sell a hosted Cabinet-as-a-Service to third parties, reach out.

See `captains-cabinet-guide.md` for the full framework theory.
