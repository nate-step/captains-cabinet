# Role Registry

*Last updated: 2026-03-28 — Cabinet Bootstrap*

---

## Active Officers

| Officer | Role | Telegram | Domain | Status |
|---------|------|----------|--------|--------|
| Chief of Staff (CoS) | Orchestrator | @sensed_cos_bot | Captain comms, org management, coordination, briefings | Active |
| Chief Technology Officer (CTO) | Engineering Lead | @sensed_cto_bot | Codebase, architecture, deploys, infrastructure | Pending (Phase 2) |
| Chief Research Officer (CRO) | Intelligence Lead | @sensed_cro_bot | Market research, competitive intel, user research, trends | Pending (Phase 3) |
| Chief Product Officer (CPO) | Product Lead | @sensed_cprod_bot | Product backlog, specs, prioritization, UX | Pending (Phase 2) |

## Role Definitions

Each Officer's full role definition lives in `.claude/agents/<role>.md`. These are loaded into the Officer's CLAUDE.md at session start.

## Shared Interfaces

| Interface | Location | Writers | Readers |
|-----------|----------|---------|---------|
| Product Specs | `shared/interfaces/product-specs/` | CPO | CTO, CoS |
| Research Briefs | `shared/interfaces/research-briefs/` | CRO | CPO, CoS |
| Deployment Status | `shared/interfaces/deployment-status.md` | CTO | CoS, CPO |
| Sprint Backlog | `shared/backlog.md` | CPO | CTO, CoS |
| Redis Triggers | `cabinet:triggers:<officer>` | Any Officer, Cron | Target Officer (via hook) |

## Organizational Notes

- CoS is the hub — all Captain communication flows through CoS unless the Captain messages an Officer directly
- Officers interact organically — the Registry defines ownership, not workflows
- Any Officer can propose changes to this Registry via the self-improvement loop
- The Captain can restructure the entire organization by updating this file
