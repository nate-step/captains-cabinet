# Role Registry

*Last updated: 2026-04-05 — Infrastructure expansion*

---

## Active Officers

| Officer | Role | Domain | Status |
|---------|------|--------|--------|
| Chief of Staff (CoS) | Orchestrator | Captain comms, org management, briefings, hooks ownership, pipeline monitoring, infrastructure | Active |
| Chief Technology Officer (CTO) | Engineering Lead | Codebase, architecture, deploys, infrastructure, captain decision logging | Active |
| Chief Research Officer (CRO) | Intelligence Lead | 10 research streams, pgvector storage, tech radar, research action pipeline | Active |
| Chief Product Officer (CPO) | Product Lead | Product backlog, specs, prioritization, UX, pipeline ownership, proactive product audits | Active |
| Chief Operating Officer (COO) | Operational Lead | Exploratory testing, Sentry triage, deployment validation, Playwright E2E, quality gate | Active |

## Role Definitions

Each Officer's full role definition lives in `.claude/agents/<role>.md`. These are loaded into the Officer's context at session start.

## Shared Interfaces

| Interface | Location | Writers | Readers |
|-----------|----------|---------|---------|
| Product Specs | `shared/interfaces/product-specs/` | CPO | CTO, CoS |
| Research Briefs | `shared/interfaces/research-briefs/` | CRO | CPO, CoS, CTO |
| Deployment Status | `shared/interfaces/deployment-status.md` | CTO | CoS, CPO, COO |
| Operational Health | `shared/interfaces/operational-health.md` | COO | CoS, all Officers |
| Sprint Backlog | `shared/backlog.md` | CPO | CTO, CoS |
| Captain Decision Trail | `shared/interfaces/captain-decisions.md` | Any Officer (receiving) | All Officers (before UI/feature work) |
| Tech Radar | `shared/interfaces/tech-radar.md` | CRO | CoS, all Officers |
| Redis Triggers | `cabinet:triggers:<officer>` | Any Officer, Cron | Target Officer (via hook, auto-delivered) |
| Research Vector Store | PostgreSQL (pgvector) | CRO (embed), all (search) | All Officers |

## Hooks

| Hook | Location | Fires | Purpose |
|------|----------|-------|---------|
| post-tool-use.sh | `cabinet/scripts/hooks/` | After every tool call | Heartbeat, logging, cost, trigger delivery, idle detection, decision enforcement |
| pre-tool-use.sh | `cabinet/scripts/hooks/` | Before every tool call | Kill switch, spending limits, prohibited actions |
| post-compact.sh | `cabinet/scripts/hooks/` | After context compaction | Essential skill refresh to prevent behavioral drift |
| post-reply-voice.sh | `cabinet/scripts/hooks/` | After Telegram replies | Voice message generation (when enabled) |

## Organizational Notes

- CoS is the hub — all Captain communication flows through CoS unless the Captain messages an Officer directly
- CoS owns hooks and Cabinet infrastructure — other Officers propose changes through CoS
- CPO owns the work pipeline — CTO must never be idle due to CPO failing to feed work
- CRO research flows through the Research Action Pipeline — findings are tagged, owned, and tracked
- Officers interact organically — the Registry defines ownership, not workflows
- Any Officer can propose changes to this Registry via the self-improvement loop
- The Captain can restructure the entire organization by updating this file
