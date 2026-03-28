# Founder's Cabinet — Implementation Plan

**Project:** Sensed  
**Date:** March 28, 2026  
**Status:** Planning

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│                    VPS (Docker Host)                     │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │              Docker Compose Stack                 │   │
│  │                                                   │   │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐            │   │
│  │  │   CoS   │ │   CTO   │ │   CRO   │  Officers  │   │
│  │  │ Claude  │ │ Claude  │ │ Claude  │  (tmux +   │   │
│  │  │ Code    │ │ Code    │ │ Code    │  Channels) │   │
│  │  │ @cos_bot│ │ @cto_bot│ │ @cro_bot│            │   │
│  │  └────┬────┘ └────┬────┘ └────┬────┘            │   │
│  │       │           │           │                   │   │
│  │       │    Agent Teams (Crew)  │                   │   │
│  │       │    spawned on demand   │                   │   │
│  │       │           │           │                   │   │
│  │  ┌────▼───────────▼───────────▼────┐              │   │
│  │  │        Shared Volumes           │              │   │
│  │  │  /workspace (Sensed repo)       │              │   │
│  │  │  /memory (tiered memory files)  │              │   │
│  │  │  /constitution (read-only)      │              │   │
│  │  │  /logs (structured JSON logs)   │              │   │
│  │  └────────────────┬────────────────┘              │   │
│  │                   │                               │   │
│  │  ┌────────────────▼────────────────┐              │   │
│  │  │    PostgreSQL + pgvector        │              │   │
│  │  │    (episodic memory, logs)      │              │   │
│  │  └─────────────────────────────────┘              │   │
│  │  ┌─────────────────────────────────┐              │   │
│  │  │    Redis                        │              │   │
│  │  │    (kill switch, rate limits,   │              │   │
│  │  │     health flags, pub/sub)      │              │   │
│  │  └─────────────────────────────────┘              │   │
│  │  ┌─────────────────────────────────┐              │   │
│  │  │    Sidecar: Watchdog            │              │   │
│  │  │    (health checks, log ingest,  │              │   │
│  │  │     cost tracking, alerts)      │              │   │
│  │  └─────────────────────────────────┘              │   │
│  └──────────────────────────────────────────────────┘   │
│                                                         │
│  Captain ◄──── Telegram ────► Sensed HQ Group           │
└─────────────────────────────────────────────────────────┘
```

### Key Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Officer runtime | Persistent Claude Code CLI sessions in tmux | Channels requires interactive CLI sessions |
| Crew runtime | Agent Teams spawned by Officers | Ephemeral, inherit Officer boundaries |
| Auth | claude.ai subscription (OAuth token) | Captain's preference for PoC phase |
| Telegram | Official Channels plugin per Officer | One bot per Officer + shared HQ group |
| Model routing | Opus 4.6 for Officers, Sonnet 4.6 for Crew | 5x cost reduction on execution tasks |
| Memory backend | PostgreSQL + pgvector + filesystem | Tier 1/2 = files, Tier 3 = vector DB |
| Safety enforcement | Hooks + read-only mounts + Redis kill switch | Programmatic, not instructional |
| Inter-Officer comms | Shared filesystem + Redis pub/sub | Officers read/write coordination files |
| Observability | Hooks → JSON logs → Watchdog sidecar → Telegram alerts | Never SSH again |
| Parallel git work | Git worktrees per Crew agent | Avoids branch conflicts |

---

## Phase 0: Foundation

**Goal:** Server ready, all credentials gathered, repo structure scaffolded.  
**Duration:** ~1 day  
**Captain effort:** High (manual setup steps)

### Deliverables

- [ ] VPS provisioned (Ubuntu 24.04, Docker, Docker Compose)
- [ ] 4 Telegram bots created via @BotFather (@sensed_cos_bot, @sensed_cto_bot, @sensed_cro_bot, + @sensed_cprod_bot for CPO)
- [ ] "Sensed HQ" Telegram group created, all bots added
- [ ] Bun installed on server (required by Channels plugin)
- [ ] All credentials gathered and stored in `.env`:
  - Telegram bot tokens (4)
  - Captain's Telegram user ID
  - GitHub PAT (nate-step/Sensed)
  - Linear API key
  - Neon connection string
  - Voyage AI API key
  - Perplexity API key
  - Brave Search API key
  - Exa API key
- [ ] Repo structure created:

```
Sensed/
├── .claude/
│   ├── settings.json              # Agent Teams enabled, model config
│   ├── agents/                    # Officer role definitions
│   │   ├── cos.md                 # Chief of Staff
│   │   ├── cto.md                 # Chief Technology Officer
│   │   ├── cro.md                 # Chief Research Officer
│   │   └── cpo.md                 # Chief Product Officer
│   └── hooks/
│       ├── pre-tool-use.sh        # Safety boundary enforcement
│       └── post-tool-use.sh       # Structured logging
├── cabinet/
│   ├── docker-compose.yml         # Full stack definition
│   ├── Dockerfile.officer         # Officer container image
│   ├── Dockerfile.watchdog        # Observability sidecar
│   ├── scripts/
│   │   ├── start-officer.sh       # tmux + claude --channels launch
│   │   ├── health-check.sh        # Ping each Officer, alert on failure
│   │   ├── token-refresh-watch.sh # Detect auth failures, alert Captain
│   │   └── kill-switch.sh         # Emergency halt all Officers
│   └── cron/
│       ├── research-sweep.sh      # 4h CRO trigger
│       ├── backlog-refine.sh      # 12h CPO/CTO trigger
│       ├── briefing.sh            # 07:00 + 19:00 CET daily briefing
│       └── retrospective.sh       # 3-day reflection cycle
├── constitution/
│   ├── CONSTITUTION.md            # Tier 1: always loaded (read-only mount)
│   ├── KILLSWITCH.md              # Safety boundaries (read-only mount)
│   ├── ROLE_REGISTRY.md           # Active Officers and domains
│   └── SAFETY_BOUNDARIES.md       # Hard limits, spending caps
├── memory/
│   ├── tier2/                     # Working notes per Officer
│   │   ├── cos/
│   │   ├── cto/
│   │   ├── cro/
│   │   └── cpo/
│   ├── tier3/                     # Episodic memory (also in pgvector)
│   │   ├── experience-records/
│   │   ├── decision-log/
│   │   └── research-archive/
│   └── skills/                    # Validated reusable procedures
├── shared/
│   ├── backlog.md                 # Current sprint / priorities
│   ├── interfaces/                # Shared data between Officers
│   │   ├── product-specs/
│   │   ├── research-briefs/
│   │   └── deployment-status.md
│   └── coordination/
│       ├── inbox-cos.md           # Message queues between Officers
│       ├── inbox-cto.md
│       ├── inbox-cro.md
│       └── inbox-cpo.md
└── CLAUDE.md                      # Root project context (loads Constitution)
```

### Notes

- Captain authenticates each Officer container manually via `claude /login` on first boot (one-time per container, persisted via Docker volume)
- `.env` is never committed — mounted at runtime via Docker Compose
- Constitution and KILLSWITCH are bind-mounted as read-only — no Officer can modify them

---

## Phase 1: Single Officer (CoS)

**Goal:** Prove the loop — one Officer running 24/7, reachable via Telegram, with memory and safety working.  
**Duration:** ~2-3 days  
**Captain effort:** Medium (testing, pairing, feedback)

### Deliverables

- [ ] Docker Compose with: CoS container, PostgreSQL, Redis
- [ ] CoS running in tmux with `claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions`
- [ ] CoS CLAUDE.md loads Constitution + role definition + Tier 2 memory
- [ ] Telegram pairing completed — Captain can DM @sensed_cos_bot
- [ ] CoS can:
  - Receive Captain messages via Telegram
  - Send briefings to Sensed HQ group
  - Read/write to shared interfaces
  - Create and update experience records
  - Escalate decision requests to Captain
- [ ] Hooks working:
  - `pre-tool-use`: blocks prohibited actions (production deploys, credential access, etc.)
  - `post-tool-use`: logs every action to JSON
- [ ] Redis kill switch: Captain sends `/killswitch` → Redis flag set → hook blocks all subsequent actions
- [ ] Health check cron: pings CoS every 5 min, alerts Captain on failure
- [ ] Token refresh watch: detects auth errors in logs, alerts Captain to re-login
- [ ] Manual session recovery tested: container restart → tmux restarts → CoS resumes

### Validation Criteria

- Captain sends "give me a status update" via Telegram → CoS responds within 60s
- Captain sends `/killswitch` → all CoS actions halt immediately
- CoS session survives container restart (tmux + volume persistence)
- CoS writes an experience record after completing a task
- CoS loads its Tier 2 memory on session start

---

## Phase 2: Add CTO + CPO Officers

**Goal:** Multi-Officer operation with inter-Officer coordination.  
**Duration:** ~3-4 days  
**Captain effort:** Medium

### Deliverables

- [ ] CTO and CPO containers added to Docker Compose
- [ ] Each Officer has its own:
  - Telegram bot + Channels config
  - tmux session
  - CLAUDE.md with role-specific context
  - Tier 2 memory directory
  - Inbox file for inter-Officer messages
- [ ] Inter-Officer communication working:
  - CoS can write to CTO/CPO inbox files
  - CTO/CPO read their inboxes on a polling loop (via CLAUDE.md instruction)
  - Officers coordinate via shared interface files (specs, status)
- [ ] CTO can:
  - Receive tasks from CoS or Captain
  - Spawn Agent Teams (Crew) for implementation
  - Use git worktrees for parallel Crew work
  - Push to GitHub (nate-step/Sensed)
  - Access Linear via MCP server
  - Access Neon via MCP server
- [ ] CPO can:
  - Manage product backlog in Linear
  - Write product specs to shared/interfaces/product-specs/
  - Review CTO implementation against specs
  - Propose prioritization changes to Captain
- [ ] Model routing configured:
  - Officers: Opus 4.6 (default model in their settings)
  - Crew (Agent Teams): Sonnet 4.6 (set in spawn prompts)
- [ ] MCP servers configured:
  - Linear MCP (CTO + CPO)
  - GitHub MCP (CTO)
  - Neon MCP (CTO)

### Validation Criteria

- Captain tells CoS "build feature X" → CoS routes to CPO for spec → CPO writes spec → CTO picks up and implements
- CTO spawns 2 Crew agents via Agent Teams to work in parallel using worktrees
- CPO reviews CTO output and files feedback
- All three Officers appear in Sensed HQ group with their respective updates

---

## Phase 3: Add CRO + Research Loops

**Goal:** Intelligence function operational, scheduled research sweeps running.  
**Duration:** ~2-3 days  
**Captain effort:** Low

### Deliverables

- [ ] CRO container added
- [ ] CRO can:
  - Run market/user/competitive research using Perplexity, Brave Search, Exa
  - Write research briefs to shared/interfaces/research-briefs/
  - Notify CoS of significant findings
  - Store research in Tier 3 episodic memory (pgvector)
- [ ] Research APIs configured as MCP servers or direct tool access:
  - Perplexity MCP
  - Brave Search MCP
  - Exa MCP
- [ ] Cron schedules active:
  - Every 4h: CRO research sweep (via Redis trigger → CRO picks up)
  - Every 12h: CPO backlog refinement
  - 07:00 + 19:00 CET: CoS daily briefing to Sensed HQ
- [ ] Voyage AI embeddings working:
  - voyage-4-large for document storage
  - voyage-4-lite for queries
  - Episodic memory retrievable by semantic search

### Validation Criteria

- CRO runs a research sweep and publishes a brief within 30 min
- CPO uses CRO brief to inform backlog priorities
- Daily briefing arrives at 07:00 CET with summary from all Officers
- Captain can ask CRO "what do you know about [topic]" and get semantically retrieved context

---

## Phase 4: Self-Improvement Loops

**Goal:** The Cabinet learns from experience and proposes its own improvements.  
**Duration:** ~3-4 days  
**Captain effort:** Low (approval of proposed changes)

### Deliverables

- [ ] Task Loop (every task):
  - Plan → execute → verify → record
  - Independent verification (different agent/subagent verifies)
  - Experience record written to Tier 3
- [ ] Reflection Loop (daily, triggered by cron):
  - CoS reviews accumulated experience records
  - Identifies patterns (noted at 2 occurrences, proposed change at 3+)
  - Proposes amendments to Constitution, skills, or role definitions
  - Sends proposals to Captain via Telegram for approval
- [ ] Evolution Loop (every 3 days):
  - Heavier analysis: performance metrics, validation testing
  - Proposed changes tested against golden evals before promotion
  - Rollback mechanism: git branch for instruction changes, revert on regression
  - Can propose org restructuring (new Officers, role merges)
- [ ] Skill Library:
  - Validated procedures extracted from successful episodes
  - Stored in memory/skills/ as markdown
  - Automatically loaded when relevant tasks arise
- [ ] Memory Consolidation:
  - Tier 3 → Tier 2: patterns that recur get promoted to working notes
  - Tier 2 → Tier 1: validated patterns get proposed as Constitution amendments

### Validation Criteria

- After 3 days of operation, CoS proposes at least one improvement
- A proposed skill is validated against a test scenario before promotion
- A bad change is detected and rolled back automatically
- The skill library contains at least 3 validated procedures

---

## Phase 5: Hardening + 24/7 Autonomy

**Goal:** The Cabinet runs reliably without Captain intervention for 48+ hours.  
**Duration:** ~3-4 days  
**Captain effort:** Minimal (monitoring only)

### Deliverables

- [ ] Watchdog sidecar fully operational:
  - Health checks every 5 min per Officer
  - Auto-restart on crash (tmux session recovery)
  - Cost tracking: per-Officer token usage logged
  - Daily cost report to Captain via Telegram
  - Alert on: Officer down > 5 min, cost exceeds daily cap, auth failure
- [ ] Session resilience:
  - Container restart → Officers auto-resume
  - Network interruption → Channels reconnect
  - Context window approaching limit → Officer self-compacts or restarts with fresh session
- [ ] Spending caps enforced:
  - Per-session limit via hook (tracks cumulative tool calls)
  - Per-day limit via Redis counter
  - Per-month limit via Redis counter
  - Exceeded → alert Captain, pause non-critical work
- [ ] Escalation chain working:
  - Crew fails → retries → escalates to Officer
  - Officer fails → retries → self-diagnoses → escalates to CoS
  - CoS fails → escalates to Captain
- [ ] Full 48-hour autonomous test:
  - Captain gives a goal on Day 0
  - Cabinet operates autonomously for 48 hours
  - Captain reviews outcomes, not process

### Validation Criteria

- Cabinet runs 48 hours with < 3 Captain interrupts
- Auto-restart recovers a killed Officer within 2 minutes
- Cost stays within defined daily cap
- Escalation chain triggers correctly on simulated failures

---

## Observability Stack (Built Incrementally Across Phases)

### Phase 1
- `post-tool-use` hook writes JSON logs to /logs/
- Health check cron pings CoS, alerts on failure
- Token refresh watch alerts on auth errors

### Phase 2
- Logs expanded to all Officers
- Per-Officer log separation
- Simple cost estimate per action logged

### Phase 3
- Watchdog sidecar ingests logs into PostgreSQL
- Daily digest to Sensed HQ group (auto-generated)
- Cron trigger confirmations logged

### Phase 4
- Experience records queryable
- Improvement proposals tracked with outcomes
- Skill usage frequency tracked

### Phase 5
- Full dashboard (simple HTML served from container, or Telegram-native reports)
- Cost tracking with projections
- Uptime tracking per Officer
- Alert escalation with cooldowns (no alert storms)

---

## Risk Register

| Risk | Impact | Mitigation | Phase |
|------|--------|------------|-------|
| Rate limits hit during heavy work | Officers stall | Monitor /usage, stagger Officer activity, consider API key fallback | 1+ |
| Telegram message loss (Channels research preview) | Captain misses critical alerts | Log all outbound messages, retry on failure, periodic digest as backup | 1+ |
| OAuth token expiry | Officers go offline | Token refresh watch + Captain alert + documented re-login procedure | 1+ |
| Context window rot | Quality degrades on long sessions | Atomic tasks, periodic session restart, /compact usage | 2+ |
| Inter-Officer race conditions on shared files | Corrupted state | File locking, clear ownership in role definitions, atomic writes | 2+ |
| Cost runaway from parallel Crew | Budget exceeded | Redis-enforced caps, Sonnet for Crew, daily cost alerts | 2+ |
| Self-improvement drift | Cabinet confidently wrong | Golden evals, rollback on regression, Captain approval for structural changes | 4 |
| Server crash / reboot | All Officers down | Docker restart policies, tmux session recovery, volume persistence | 5 |

---

## Open Questions for Captain

1. **VPS provider preference?** (Hetzner, DigitalOcean, AWS, etc.) — need Docker + persistent storage + EU location for CET scheduling
2. **Subscription plan?** Max 5x ($100) or Max 20x ($200)? With 4 Officers, 20x is strongly recommended
3. **Daily cost cap?** What's the max you're comfortable spending per day during PoC? (estimate: $50-150/day at subscription rates with 4 Officers)
4. **Sensed product context?** What is Sensed? What does it do? The CPO and CRO need product context from day one to be useful
5. **First goal for the Cabinet?** What should the Cabinet build/research in its first 48-hour autonomous run?

---

*This plan is a living document. Each phase will get a detailed implementation plan before execution begins.*
