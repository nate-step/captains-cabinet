# The Founder's Cabinet

An autonomous AI organization that builds, ships, and improves your product — while you steer from Telegram.

## What This Is

The Founder's Cabinet is a framework for running a 24/7 AI development organization. You are the Captain. AI Officers own domains (product, engineering, research). They coordinate, execute, learn, and improve — continuously.

This repo is the **infrastructure**. It contains the organizational framework, memory system, safety boundaries, and Docker configuration. Your product repo is separate — the Cabinet mounts it as a workspace.

## How It Works

```
You (Captain)
  ↕ Telegram
Cabinet (this repo)
├── CoS — orchestration, briefings, self-improvement
├── CTO — engineering, code, deploys
├── CPO — product specs, backlog, prioritization
└── CRO — market research, competitive intel, trends
  ↕ reads/writes
Your Product Repo (mounted at /workspace/product)
```

Each Officer runs as a persistent Claude Code session with Telegram Channels. They read strategy from Notion, execute tasks from Linear, write code in your repo, and report back via Telegram.

## Quick Start

### 1. Fork This Repo

```bash
git clone https://github.com/YOUR-USERNAME/founders-cabinet.git
cd founders-cabinet
```

### 2. Set Up Notion

The bootstrap script creates the entire Cabinet HQ workspace structure automatically:

```bash
export NOTION_API_KEY="your-notion-internal-integration-token"
bash cabinet/scripts/bootstrap-notion.sh "YourProductName"
```

This creates all pages and databases and writes the IDs to `config/product.yml`. Then add your strategy docs (vision, brand guidelines, etc.) to the Business Brain section.

### 3. Configure Your Product

Edit `config/product.yml` — point it at your repo, Notion workspace, Linear team, and Neon project.

### 4. Set Up Telegram Bots

Create 4 bots via @BotFather (CoS, CTO, CRO, CPO) and a "YourProduct HQ" group.

### 5. Fill In Credentials

```bash
cp cabinet/.env.example cabinet/.env
# Fill in all API keys and tokens
```

### 6. Deploy

```bash
# On your server (Hetzner/DO/AWS, Ubuntu 24.04)
cd /opt/founders-cabinet/cabinet
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
| **Notion** | Business brain — strategy, research, decisions (required) |
| **Linear** | Execution backlog — what to build |
| **PostgreSQL + pgvector** | Episodic memory with semantic search |
| **Redis** | Kill switch, rate limits, state flags |
| **Watchdog** | Health checks, cost tracking, cron triggers, alerts |
| **Telegram** | Captain's command interface |

## The Five Pillars

1. **Dynamic Roles** — Officers are markdown files, not code. Restructure the org in one message.
2. **The Founder as Captain** — You set direction. The Cabinet figures out how.
3. **Memory That Compounds** — Three tiers: always-loaded constitution, working notes, episodic recall.
4. **Self-Improvement Loops** — Three nested loops: Task (per-task experience records), Reflection (every 6h individual self-review), Evolution (every 24h cross-officer retro + skill promotion). Foundation skills ship with the repo and improve over time.
5. **Safety Boundaries** — Hard limits enforced by hooks and Redis. Read-only constitution. Kill switch.

## Repo Structure

```
founders-cabinet/
├── .claude/agents/          # Officer role definitions (identity, not procedures)
├── cabinet/                 # Docker, scripts, hooks, cron
├── config/product.yml       # Product-specific configuration
├── constitution/            # Governance (read-only at runtime)
├── memory/
│   ├── skills/              # Foundation + promoted skills (procedures, quality gates)
│   ├── golden-evals/        # Validation scenarios for Cabinet changes
│   ├── tier2/               # Officer working notes (per-role)
│   └── tier3/               # Experience records, decision log, research archive
├── shared/                  # Inter-Officer interfaces
├── CLAUDE.md                # Root context loaded every session
└── founders-cabinet-guide.md # The theory document
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
```

Browse voices at [elevenlabs.io/voice-library](https://elevenlabs.io/voice-library) or via API. Requires `ELEVENLABS_API_KEY` in `.env`.

### Image Generation (optional)
Officers can generate images via Google Gemini (Nano Banana 2) and send them through Telegram. Requires `GOOGLE_API_KEY` in `.env`.

### Improvement Cadences
Default cadences in `CLAUDE.md` (adjust to match your Cabinet's throughput):
- **Individual reflection:** every 6h per Officer
- **Cross-officer retro:** every 24h (CoS)
- **Evolution loop:** every 24h after retro (CoS)

### Foundation Skills
Ship with the repo in `memory/skills/`. Officers follow these as baseline procedures. The learning loop can improve them by writing evolved versions to `memory/skills/evolved/` — foundation files are never modified directly.

### What to Customize After Forking
1. `config/product.yml` — your product name, Notion IDs, Linear workspace, Telegram bots, voice settings
2. `cabinet/.env` — all API keys and tokens
3. `constitution/CONSTITUTION.md` — your product's work principles (optional)
4. `.claude/agents/*.md` — officer identity if you add domain-specific context (optional)

## Requirements

- **Server:** Ubuntu 24.04 with Docker (Hetzner CPX31 recommended)
- **Claude:** Max 20x subscription ($200/mo) for 4 Officers
- **Notion:** Business plan (for MCP integration)
- **Telegram:** 4 bot tokens + group chat
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

© 2026 Nathaniel Refslund. All rights reserved.

See `founders-cabinet-guide.md` for the full framework theory.
