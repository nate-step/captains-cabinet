# Phase 0: Foundation — Step-by-Step Guide

**Goal:** Server ready, all credentials gathered, repo structure scaffolded, ready for Phase 1.  
**Duration:** ~1 day  
**Captain effort:** High (manual setup, one-time)

---

## Step 1: Provision Hetzner VPS

### Server Specs

| Setting | Value |
|---------|-------|
| Provider | Hetzner Cloud |
| Type | CPX31 (4 vCPU, 8 GB RAM, 160 GB SSD) |
| Image | Ubuntu 24.04 |
| Location | Falkenstein (eu-central, good for CET scheduling) |
| Networking | Public IPv4, no floating IP needed |
| SSH Key | Your existing key |

**Why CPX31:** Claude Code CLI is network-bound (API calls), not CPU-bound. 4 concurrent Officer sessions + PostgreSQL + Redis fit comfortably in 8GB. Scale up later if needed.

### After provisioning, SSH in and run:

```bash
# Update system
apt update && apt upgrade -y

# Install Docker
curl -fsSL https://get.docker.com | sh
systemctl enable docker

# Install Docker Compose (v2 is included with Docker now)
docker compose version  # verify

# Install tmux (used inside containers)
apt install -y tmux

# Install Bun (required by Channels plugin)
curl -fsSL https://bun.sh/install | bash
source ~/.bashrc

# Install Node.js 22 (required by Claude Code)
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs

# Install Claude Code globally
npm install -g @anthropic-ai/claude-code

# Verify
claude --version
bun --version
docker compose version
```

---

## Step 2: Create Telegram Bots

Open Telegram and chat with [@BotFather](https://t.me/BotFather).

Create **4 bots** by sending `/newbot` four times:

| Bot | Display Name | Username | Purpose |
|-----|-------------|----------|---------|
| 1 | Sensed CoS | @sensed_cos_bot | Chief of Staff — Captain's primary interface |
| 2 | Sensed CTO | @sensed_cto_bot | CTO — Engineering updates |
| 3 | Sensed CRO | @sensed_cro_bot | CRO — Research findings |
| 4 | Sensed CPO | @sensed_cprod_bot | CPO — Product updates |

**Save each bot token.** They look like: `123456789:AAHfiqksKZ8...`

### Create the "Sensed HQ" Group

1. Create a new Telegram group called "Sensed HQ"
2. Add all 4 bots to the group
3. Send a message in the group to generate the chat ID
4. Get the group chat ID by visiting: `https://api.telegram.org/bot<COS_BOT_TOKEN>/getUpdates`
5. Look for `"chat":{"id":-100XXXXXXXXX}` — that negative number is the group ID

### Get Your Telegram User ID

Send any message to [@userinfobot](https://t.me/userinfobot) — it replies with your user ID.

### Group Chat Model

The Sensed HQ group is a **broadcast feed**. Officers post updates, briefings, and alerts. The Captain reads. Commands go via DM to specific Officer bots, not in the group.

By default, Telegram bots have privacy mode ON — they can only see group messages that @mention them. This is correct for our model: Officers post *to* the group via the Telegram Bot API (`send-to-group.sh`), but they don't need to *read* group messages.

### Known Limitations

- **Channels is a research preview.** Messages sent to a bot while its session is down are lost (Telegram doesn't queue them). If an Officer restarts, any DMs sent during the restart window are gone. Mitigated by the Watchdog health check (5 min) which alerts you if an Officer is down.
- **No voice messages.** Telegram voice notes arrive as opaque audio files that Claude can't transcribe.
- **Cost tracking is approximate.** The hook-based cost counter estimates tokens from character counts. Use `/status` in Claude Code for real usage data. The counter exists for daily cap enforcement, not precise billing.

---

## Step 3: Gather All Credentials

Create a file called `.env` (NOT committed to git). Use the template at `cabinet/.env.example`.

You need:

| Credential | How to get it |
|-----------|---------------|
| `TELEGRAM_COS_TOKEN` | BotFather (Step 2) |
| `TELEGRAM_CTO_TOKEN` | BotFather (Step 2) |
| `TELEGRAM_CRO_TOKEN` | BotFather (Step 2) |
| `TELEGRAM_CPO_TOKEN` | BotFather (Step 2) |
| `TELEGRAM_HQ_CHAT_ID` | Group chat ID (Step 2) |
| `CAPTAIN_TELEGRAM_ID` | @userinfobot (Step 2) |
| `GITHUB_PAT` | GitHub → Settings → Developer settings → Personal access tokens → Fine-grained → nate-step/Sensed repo (read/write Contents, Issues, PRs) |
| `LINEAR_API_KEY` | Linear → Settings → API → Personal API keys |
| `NEON_CONNECTION_STRING` | Neon dashboard → Connection string (with pooler) |
| `NOTION_API_KEY` | Notion → Settings → Connections → Develop or manage integrations → Create integration → Copy Internal Integration Secret. Grant it access to the Cabinet HQ page tree. |
| `VOYAGE_API_KEY` | Voyage AI dashboard → API keys |
| `PERPLEXITY_API_KEY` | Perplexity API dashboard |
| `BRAVE_SEARCH_API_KEY` | Brave Search API dashboard |
| `EXA_API_KEY` | Exa dashboard → API keys |

---

## Step 4: Clone Repos & Add Cabinet Structure

```bash
# Clone the product repo
cd /opt
git clone https://github.com/nate-step/Sensed.git

# Create the Cabinet framework repo
mkdir founders-cabinet
cd founders-cabinet
git init

# Copy all Phase 0 files into the Cabinet repo
# (these are the files created by this plan)
```

Copy the entire file tree from this deliverable into `/opt/founders-cabinet`. The structure:

```
/opt/founders-cabinet/             ← THE FRAMEWORK (this repo)
├── .claude/
│   ├── settings.json              ← Hooks, permissions, Agent Teams, Notion MCP
│   └── agents/
│       ├── cos.md
│       ├── cto.md
│       ├── cro.md
│       └── cpo.md
├── cabinet/
│   ├── docker-compose.yml
│   ├── Dockerfile.officer
│   ├── Dockerfile.watchdog
│   ├── .env.example
│   ├── init.sql
│   ├── tmux.conf
│   ├── scripts/
│   │   ├── entrypoint.sh
│   │   ├── start-officer.sh
│   │   ├── health-check.sh
│   │   ├── kill-switch.sh
│   │   ├── token-refresh-watch.sh
│   │   ├── watchdog-entrypoint.sh
│   │   └── hooks/
│   │       ├── pre-tool-use.sh
│   │       └── post-tool-use.sh
│   └── cron/
│       ├── briefing.sh
│       ├── research-sweep.sh
│       ├── backlog-refine.sh
│       └── retrospective.sh
├── config/
│   └── product.yml                ← Product-specific config (Notion IDs, etc.)
├── constitution/                  ← Tier 1 memory (read-only mount)
│   ├── CONSTITUTION.md
│   ├── KILLSWITCH.md
│   ├── ROLE_REGISTRY.md
│   └── SAFETY_BOUNDARIES.md
├── memory/
│   ├── tier2/{cos,cto,cro,cpo}/
│   ├── tier3/{experience-records,decision-log,research-archive}/
│   ├── skills/
│   └── logs/
├── shared/
│   ├── interfaces/{product-specs,research-briefs}/
│   ├── backlog.md
│   └── deployment-status.md
├── CLAUDE.md                      ← Root project context
├── founders-cabinet-guide.md      ← The theory document
└── README.md

/opt/Sensed/                       ← THE PRODUCT (untouched, no Cabinet files)
├── src/
├── package.json
└── ...
```

**Key principle:** The product repo has zero Cabinet awareness. It's just a normal app. Any founder can fork `founders-cabinet`, point it at their repo via `config/product.yml`, and deploy.

---

## Step 4b: Set Up Notion Workspace

The Cabinet requires a Notion workspace with the canonical "Cabinet HQ" structure. You have two options:

### Option A: Bootstrap Script (recommended for new founders)

```bash
cd /opt/founders-cabinet

# Set your Notion integration token
export NOTION_API_KEY="your-notion-internal-integration-token"

# Run the bootstrap — creates all pages and databases, writes config/product.yml
bash cabinet/scripts/bootstrap-notion.sh "YourProductName"
```

This creates the entire Cabinet HQ structure in Notion and auto-populates `config/product.yml` with all the page and database IDs. No manual ID copying required.

After running, open Notion and verify the structure exists, then fill in the TODO fields in `config/product.yml` (repo URL, Linear team, Telegram bot names, etc.).

### Option B: Existing Workspace (for Sensed / existing setups)

If the Notion structure already exists (e.g., it was created during planning), verify that `config/product.yml` has the correct IDs for every page and database. Each ID is a UUID you can extract from Notion page URLs.

---

## Step 5: Configure Environment

```bash
cd /opt/founders-cabinet

# Copy env template and fill in credentials
cp cabinet/.env.example cabinet/.env
nano cabinet/.env  # fill in all values from Step 3

# Make scripts executable
chmod +x cabinet/scripts/*.sh
chmod +x cabinet/scripts/hooks/*.sh
chmod +x cabinet/cron/*.sh
```

---

## Step 6: Build & Start Infrastructure

```bash
cd /opt/founders-cabinet/cabinet

# Build images
docker compose build

# Start PostgreSQL + Redis first
docker compose up -d postgres redis

# Wait for PostgreSQL to be healthy
docker compose exec postgres pg_isready  # should say "accepting connections"

# The init.sql runs automatically via docker-entrypoint-initdb.d
# Verify the schema is created:
docker compose exec postgres psql -U cabinet -d cabinet_memory -c "\dt"
```

**Do NOT start Officers yet — that's Phase 1.**

---

## Step 7: Verify Foundation

Run through this checklist:

- [ ] VPS accessible via SSH
- [ ] Docker, Docker Compose, Bun, Node.js, Claude Code CLI installed
- [ ] 4 Telegram bots created, tokens saved
- [ ] Sensed HQ group created, bots added, chat ID saved
- [ ] All API credentials gathered and in `cabinet/.env` (including Notion)
- [ ] **founders-cabinet** repo created at `/opt/founders-cabinet`
- [ ] **Sensed** product repo cloned at `/opt/Sensed`
- [ ] `config/product.yml` has correct Notion page/database IDs
- [ ] Cabinet directory structure exists (constitution, memory, shared, config)
- [ ] Constitution, KILLSWITCH, role definitions written
- [ ] Docker images build successfully
- [ ] PostgreSQL starts, accepts connections, and has memory schema
- [ ] Redis starts and responds to PING
- [ ] `cabinet/.env` has no empty values
- [ ] Notion workspace has Cabinet HQ structure with all databases

---

## What's Next

Phase 1 starts the CoS Officer. You'll:
1. Start the Officer container
2. Authenticate with `claude /login` (one-time, manual)
3. Install + configure the Telegram plugin
4. Pair @sensed_cos_bot with the Captain
5. Send the first command: "Read the Constitution and report for duty"

The CoS comes online. The Cabinet is in session.
