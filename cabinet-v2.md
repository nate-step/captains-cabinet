# Captain Directive: Cabinet Evolution

**From:** Nate (Captain)
**To:** CoS
**Date:** 2026-04-16
**Status:** Phase 0 authorized for planning. Phases 1–3 documented in sequence; each requires separate authorization before execution.

---

## How to read this document

This directive covers four phases of Cabinet evolution. Each builds on the previous one. Only Phase 0 is authorized for execution right now.

- **Phase 0** — Profile infrastructure. Refactor the current Cabinet so the framework supports multiple "profiles" (work, personal, future). Authorized.
- **Phase 1** — Multi-context within one Cabinet. Concurrent work across Sensed, STEP, PolAds, Personal, ad-hoc. Authorized after Phase 0 lands.
- **Phase 2** — Cabinet Suite. Split into two Cabinet instances (Work + Personal), connected by a Cabinet MCP. Documented for architectural awareness. Not authorized.
- **Phase 3** — Federation. Organizational rollout (STEP Network). Intent only. Far future. Not authorized.

**What CoS should do with this:**
1. Read the full document. Understand the vision.
2. Execute Phase 0 per the directive below.
3. Keep later-phase awareness in mind when making Phase 0 and Phase 1 design decisions. Prefer choices that make future phases clean. Flag trade-offs that would meaningfully complicate later phases.
4. Do not build Phase 1, 2, or 3 without separate authorization. Each phase gets its own directive when the time comes.

---

## Part 1 — Vision and architecture

### The one-sentence summary

**One framework, many profiles, many Cabinet instances per Captain, communicating through a Cabinet MCP — scaling from solo founder to full organization.**

### The profile concept

A **profile** is a preset that configures a Cabinet for a particular mode of operation. Profiles define:

- What agent archetypes pre-scaffold (in work profile: officers like CoS, CTO, Ops. In personal profile: coaches like Physical Coach, Mindfulness Coach).
- What terminology the profile uses by default ("officer" vs. "coach") — overridable per-role.
- What memory schemas initialize (work profile adds standard tables; personal profile additionally adds longitudinal_metrics, coaching_narratives, consent_log, coaching_experiments).
- What Constitution additions load (work profile loads standard Constitution; personal profile loads standard + Coaching Principles).
- What default autonomy levels apply (work profile: higher execution autonomy. Personal profile: lower, consent-gated).
- What hook defaults enforce (personal profile adds privacy redaction and consent checks).
- What warroom conventions apply (work profile: per-context warrooms. Personal profile: Captain DM dominant).

A profile is **not** a separate codebase, a fork, or an alternate framework. It's a configuration overlay within one framework.

Profiles are inheritable and composable. A future "coaching" profile could extend personal. A future "employee" profile could extend work. Founders can create custom profiles for their specific use cases.

### The three scales of Cabinet deployment

| Scale | What | Example |
|-------|------|---------|
| **1. Cabinet** | One deployed instance | Your current Cabinet |
| **2. Cabinet Suite** | Multiple Cabinet instances owned by one Captain | Your future Work Cabinet + Personal Cabinet |
| **3. Federation** | Many Captains' Cabinets, coordinated by a Meta-Cabinet | STEP Network with per-employee Cabinets + STEP HQ Meta-Cabinet |

Phase 0 and Phase 1 operate at Scale 1 (one Cabinet). Phase 2 introduces Scale 2 (Suite). Phase 3 introduces Scale 3 (Federation).

### Terminology (use consistently in code, docs, and communication)

- **Framework** — the founders-cabinet codebase. One repo. Upgradeable from upstream.
- **Profile** — a configuration overlay that adapts the framework for a use case (work, personal, etc.).
- **Cabinet** — a deployed instance of the framework with a profile applied. One Docker stack, one Postgres, one Redis.
- **Context** — a coherent scope of work within a Cabinet. Products (Sensed, PolAds), operations (STEP ops), life domains (personal admin), ephemeral (adhoc). Multiple contexts coexist in one Cabinet.
- **Capacity** — a tag on contexts and agents distinguishing work from personal. Used for logical isolation in Phase 1, physical separation in Phase 2.
- **Agent** — the generic term for a persistent AI identity within a Cabinet. "Officer" and "coach" are profile-specific renamings of this concept. Agent archetypes include: CoS, CTO, CPO, COO, CRO, CIO, Ops, Comp, EA, Physical Coach, Mindfulness Coach, etc.
- **Captain** — the human who directs a Cabinet. One Captain per Cabinet instance. Federation has a Captain-of-Captains at the Meta-Cabinet.

### What changes are framework-level vs. profile-level vs. instance-level

Three layers, clearly separated:

- **Framework** (ships to everyone, universal): Docker orchestration, hooks, three-tier memory infrastructure, Constitution base, Safety Boundaries base, Redis streams, Task/Reflection/Evolution loops, Skill Library infrastructure, capability-based routing, dashboard, Cabinet MCP (Phase 2+).
- **Profile** (ships with the framework, per-use-case): agent archetypes, terminology conventions, memory schema additions, Constitution addendums, default autonomy levels, hook defaults, warroom conventions.
- **Instance** (per-Captain, per-Cabinet): actual officer role definitions, specific contexts, bot tokens, MCP scope for this Captain, config for this Captain's repos/knowledge systems, Tier 2 memory contents.

When CoS makes a change, it goes in exactly one of these layers. Universal improvements go framework-level. Use-case improvements go profile-level. Personal customizations go instance-level. This three-way separation is how upstream-safe evolution works.

---

## Part 2 — Phase 0: Profile Infrastructure

**Status:** Authorized. CoS to propose implementation plan and golden evals before execution.

### The problem Phase 0 solves

The current Cabinet works, but it conflates three things:
- Framework code
- Implicit profile conventions (product-shaped: CTO + CPO + CRO + COO pattern, Linear backlog, Notion HQ, etc.)
- Sensed-specific instance config

Right now, swapping in a different profile (like personal coaching) would require editing framework files. That's wrong. Phase 0 establishes the three-layer separation so later phases can add profiles without touching framework, and can customize instances without touching profiles.

### The outcome I want from Phase 0

When Phase 0 is complete:

1. The current Cabinet is running unchanged from my perspective — same officers, same warroom, same work.
2. Under the hood, the framework is profile-agnostic. Any profile-specific element (agent definitions, memory schemas, Constitution addendums, default autonomy levels) has moved from framework-level files into a `profiles/work/` directory.
3. The Sensed-era officer definitions, schemas, and Constitution patterns are packaged as the work profile's product-team pattern.
4. A profile loader exists: on Cabinet startup, it reads which profile this instance uses and overlays the profile's content onto the framework base.
5. An empty `profiles/personal/` directory exists as a placeholder, ready to be filled in during Phase 2 (but not populated yet).
6. Creating a new profile is a documented process — `profiles/_template/` shows the shape, and the CoS evolved skill library has a `create-profile.md` skill.

Phase 0 is a **refactor, not a feature add.** No new capabilities for me. The payoff is entirely in what becomes possible afterward.

### Principles for Phase 0 execution

**Preserve everything that works.** The current Cabinet runs through Phase 0. At no point do I lose functionality. Migrations are staged so rollback is always possible.

**Universality test, always.** The profile concept itself must be framework-level, universal. The work profile's content must be sufficiently generic that any founder running a business could use it, with only instance-level customization needed for their specifics.

**Three-layer discipline.** Every file gets classified: framework, profile, or instance. Document the classification. When in doubt, ask me.

**Preserve craft standards.** Infrastructure Change Protocol applies: plan, execute, spawn Sonnet review agent, fix findings, commit. Pre-tool-use.sh changes are particularly sensitive.

**Ask when the decision is mine.** Specific [Captain decision] items below.

### Scope of work for Phase 0

**1. Establish the three-layer directory structure.**

Current state (approximate):
```
founders-cabinet/
├── .claude/agents/          # Mixed: framework + profile + instance
├── cabinet/                 # Framework
├── config/                  # Instance
├── constitution/            # Mixed: framework base + profile additions
├── memory/                  # Mixed: framework infra + instance contents
└── shared/                  # Instance
```

Target state (approximate — CoS to refine):
```
founders-cabinet/
├── cabinet/                           # Framework (Docker, hooks, scripts)
├── framework/                         # Framework (core constitution, base schemas)
│   ├── constitution-base.md
│   ├── safety-boundaries-base.md
│   └── schemas-base.sql
├── profiles/
│   ├── work/                          # Work profile
│   │   ├── profile.yml
│   │   ├── terminology.yml            # "agent" → "officer" in this profile
│   │   ├── constitution-addendum.md
│   │   ├── safety-addendum.md
│   │   ├── schemas.sql                # Additional tables for this profile
│   │   ├── agents/                    # Pre-scaffolded agent definitions
│   │   │   ├── cos.md
│   │   │   ├── cto.md                 # Product team pattern
│   │   │   ├── cpo.md
│   │   │   ├── coo.md
│   │   │   ├── cro.md
│   │   │   └── (Ops, Comp, EA when Phase 1 adds them)
│   │   └── skills/                    # Work-specific skill defaults
│   ├── personal/                      # Personal profile — empty placeholder
│   │   └── (populated in Phase 2)
│   └── _template/                     # For creating new profiles
├── instance/                          # Instance-specific (formerly root-level)
│   ├── config/
│   │   ├── platform.yml
│   │   └── contexts/                  # Phase 1 populates this
│   ├── agents/                        # Instance-specific agent customizations
│   │   └── (overlays or overrides of profile agent definitions)
│   └── memory/
│       ├── tier2/
│       └── tier3/
└── CLAUDE.md                          # Framework entry point, loads profile + instance
```

Whether this exact layout is right is CoS's call — the principle is the three-layer separation, not the specific directory names.

**2. Build the profile loader.**

On Cabinet startup:
1. Read which profile this instance uses (from `instance/config/profile.yml` or similar).
2. Validate the profile exists in `profiles/<name>/`.
3. Apply the profile:
   - Concatenate framework `constitution-base.md` + profile `constitution-addendum.md` → loaded Constitution.
   - Concatenate framework `safety-boundaries-base.md` + profile `safety-addendum.md` → loaded Safety Boundaries.
   - Apply framework `schemas-base.sql` + profile `schemas.sql` to Postgres at init.
   - Make profile-scaffolded agent definitions available to agents unless instance-level overrides exist.
   - Load profile-specific skill defaults unless instance-level variants override.
4. Overlay instance-level config on top of profile defaults.

The loader runs on container start, not on every session start. Session start just reads the already-loaded state.

**3. Move Sensed-era content into the work profile.**

- Current agent definitions (`.claude/agents/cos.md`, `cto.md`, `cpo.md`, `cro.md`, `coo.md`) become the work profile's pre-scaffolded agents.
- Current Constitution and Safety Boundaries get split: universal sections → framework base; work-specific sections (product team roles, specific MCPs, etc.) → profile addendum.
- Current schemas: base tables (experience_records, decision_log, skills) → framework. Any schemas that are profile-specific go to profile.
- Sensed-specific content (the Sensed mount, Linear workspace for Sensed, Notion IDs) stays at instance level in `instance/config/`.

**4. Create the `_template` profile.**

A skeleton showing what a profile looks like: required files, metadata schema, inheritance structure. This is what future founders (or future you) use to create a new profile.

**5. Write the create-profile skill.**

Add `memory/skills/evolved/create-profile.md` describing how to create a new profile, based on whatever CoS learns from extracting the work profile.

**6. Update documentation.**

- CLAUDE.md becomes profile-aware: describes the three-layer model, how the active profile affects the session.
- README gets a "Profiles" section explaining the concept and how to pick one at deployment time.
- A new `profiles/README.md` documents the profile catalog and how to contribute new ones upstream.

### What I'll need to decide during Phase 0

[**Captain decision 1**] **Exact directory layout.** CoS proposes, I approve. Do we use `framework/`, `profiles/`, `instance/` as top-level dirs, or keep the current layout and just mark files by their layer? CoS's call with my review.

[**Captain decision 2**] **Backward-compatibility window.** During Phase 0 execution, the old file paths continue to work via symlinks or shims. How long do we keep those shims before removing them? I lean: until end of Phase 1, then clean up.

[**Captain decision 3**] **Profile naming confirmation.** Profiles will be `work` and `personal`. Confirmed. Any objection to these specific strings? (No.)

[**Captain decision 4**] **Profile versioning.** Should profiles be versioned (e.g., `profiles/work@1.0.0/`)? My lean: not yet. Revisit when we have multiple profiles in active use and need to upgrade them independently.

### What "done" looks like for Phase 0

Four criteria:

1. **The Cabinet runs unchanged from my perspective.** I open Telegram, DM CoS bot, get a response. Same officers, same warroom, same work. Nothing visible broke.
2. **The three-layer separation is real.** Any file can be classified as framework, profile, or instance. No file is ambiguous.
3. **Adding a second profile would be a pure profile-directory addition.** No framework files need to change. This is provable: CoS demonstrates by adding a stub `profiles/personal/` directory with one sample agent and showing the loader can load it (without actually deploying a personal Cabinet).
4. **Upstream-safe is preserved.** The extracted work profile is generic enough that another founder could use it for their own business. Sensed-specific content is all at instance level.

---

## Part 3 — Phase 1: Multi-context within one Cabinet

**Status:** Documented for sequencing and design. Not authorized. Separate directive issued after Phase 0 lands.

### Scope

What was described in the prior directive's "Phase 1" section. I won't repeat the full detail here — CoS can reference it when Phase 1 is authorized.

Summary: Introduce the Contexts concept, add Ops / Comp / EA agents, establish per-agent MCP scope, build CoS context routing, add the ad-hoc task inbox, enable multi-warroom routing, tag memory by context.

### What changes because Phase 0 happened first

With profile infrastructure in place, Phase 1 becomes cleaner:

- **Contexts live at instance level.** `instance/config/contexts/sensed.yml`, `instance/config/contexts/step.yml`, etc. They're instance-specific, so they go in instance, not in the profile.
- **New agents (Ops, Comp, EA) go at profile level.** They're work-profile additions, generic enough that any business could use an Ops agent. Specific MCP scopes and context assignments happen at instance level.
- **Capacity tagging is framework-enforced.** The framework's base schemas include `capacity` fields on contexts and agents. Profiles and instances populate them.
- **The MCP scope system is profile-aware.** Default scopes for standard agents come from the profile; instance overlays add context-specific permissions.

Phase 1 does not require a second profile. The work profile and instance customization are enough.

### Phase-1-affects-Phase-2 constraints

When Phase 1 is authorized and executed, CoS must honor these Phase-2-forward design constraints:

1. **Capacity tagging is non-negotiable.** Every context, agent, experience record, and shared interface artifact gets tagged `work` or `personal`. The adhoc context is typically personal but individual tasks can be routed either way and get tagged accordingly. No nulls. No "unknown."

2. **MCP scope structure allows per-Cabinet filtering.** Design the scope file so "agent X has MCPs Y, Z" can be further filtered by "only in Cabinet N" without restructuring.

3. **No cross-capacity data coupling.** Work-capacity agents do not write to personal-capacity agents' Tier 2 notes, and vice versa. Enforced via pre-tool-use.sh.

4. **Cabinet identity in logs.** Structured logs include `cabinet_id` (default `main` during Phase 1, meaningful after Phase 2).

5. **Bot tokens per agent, warrooms per context.** Never per-Cabinet. Phase 2's split doesn't move bots or warrooms; it moves which Cabinet each agent reports to.

---

## Part 4 — Phase 2: Cabinet Suite (documented only, not authorized)

### Why this phase might exist

Three conditions might make literal Cabinet separation worthwhile:

1. **Data gravity.** Apple Health data, sleep patterns, and eventually journal content in the same Postgres as STEP work emails creates an attack surface and trust surface I may want eliminated.
2. **Ownership clarity.** If STEP provisions a Work Cabinet, STEP owns the data. My personal data must not be entangled with that ownership.
3. **Scale to others.** If the architecture gets adopted by other STEP employees, each of them has their own Work Cabinet — not a shared one.

None of these are urgent. Evaluate after Phase 1 has run 6–8 weeks.

### What Phase 2 would do

- Create a second Cabinet instance (Personal Cabinet) alongside the existing one (which becomes Work Cabinet).
- Migrate personal-capacity contexts (Sensed, Personal, personal-adhoc) from the current Cabinet to Personal Cabinet, using capacity tags as the migration key.
- Keep work-capacity contexts (STEP, PolAds, work-adhoc) in the current Cabinet (Work Cabinet).
- **Populate the personal profile.** Now `profiles/personal/` gets actual content: coaching agents, longitudinal schemas, Coaching Principles constitutional additions. Physical Coach becomes the first concrete coach.
- Introduce the **Cabinet MCP** — an MCP server each Cabinet exposes for inter-Cabinet communication. Enables: availability queries, message passing, calendar read-through, handoff requests, meeting coordination.
- Define trust policies per Cabinet — what can the other Cabinet ask? What requires Captain approval?

### What's premature to decide now

- **Where Personal Cabinet would be hosted** (own VPS, same host separate stack, Mac mini).
- **Exact Cabinet MCP protocol** (specific tools, trust model, request format).
- **Whether Sensed stays with me in Personal or splits off** if Sensed ever grows a team.
- **Coaching-profile details** (Physical Coach role definition, consent model specifics, longitudinal schema design). These are Phase 2 scope; specifying them now is premature.

Don't build toward these. Knowing they exist is enough to inform Phase 1 design constraints.

---

## Part 5 — Phase 3: Federation (intent only, far future)

### Why this phase is mentioned now

Phase 3 is organizational rollout of the Cabinet framework — potentially to STEP Network, potentially to anyone. It's mentioned here because Phase 0's profile architecture and Phase 2's Cabinet MCP are the prerequisites for it. If we know Federation might happen, we can design the earlier phases to support it cleanly.

### What Phase 3 would do

- **Meta-Cabinet** — an org-level Cabinet running a "federation" profile, owned by the CEO or delegate. Handles employee directory, shared MCP services, org-wide policy, cross-employee coordination.
- **Per-employee Work Cabinets** — each employee gets their own Cabinet instance running the work profile, provisioned from a template by the Meta-Cabinet's Registrar agent.
- **Shared MCP gateway** — expensive / central MCPs (STEPhie, Monday, GAM) run once at the Meta-Cabinet and proxy to member Cabinets with per-employee auth, audit, and rate limiting.
- **Employee lifecycle** — Meta-Cabinet handles onboarding, offboarding, legal hold, role transitions via defined protocols.
- **Cost and policy governance** — per-employee spending caps, data retention policies, approved MCP allowlist, all enforced at the Meta level but executed by individual Cabinets.

### What stays true regardless

- **Personal Cabinets never join a Federation.** The Federation is Work-only. Personal Cabinets remain individually owned, even if hosted on org infrastructure.
- **Meta-Cabinet has structured access, not content access.** It sees cost logs, policy violations, error rates. It does not read message content, officer conversations, or decisions.
- **Every employee consents individually.** A Cabinet is not mandatory. Neither is a Personal Cabinet.

### Why it's intent-only

Phase 3 requires Phase 2 to have proven out. It also requires real organizational readiness at STEP — policy decisions about data, consent, governance that go beyond what a directive can answer. Until Phase 2 is running well and STEP is ready, Phase 3 is architectural vision, not a plan.

---

## Part 6 — Process for CoS

### Immediate (Phase 0 kickoff)

1. **Read this directive in full.** Raise clarifying questions in Captain DM before planning.

2. **Confirm understanding.** Acknowledge that Phase 0 is authorized, Phase 1 is planned but not yet authorized, and Phases 2 and 3 are intent-only. No work on Phases 2 or 3.

3. **Propose the Phase 0 plan.** Roughly checkpoint-level, with golden evals per checkpoint, rollback paths, and estimated effort. Post to Captain's Dashboard Notion as a decision-queue entry. I approve before execution begins.

4. **Surface [Captain decision] items** one at a time as they become blocking. Don't bundle.

5. **Sequence for safety.** Phase 0 is a refactor under a live system. Each checkpoint must leave the Cabinet fully functional. If a checkpoint can't meet this bar, it's scoped wrong — revise before proceeding.

### Throughout Phase 0

6. **Three-layer discipline.** Every file touched gets classified: framework, profile, or instance. Document the classification in commit messages or a tracking doc. Ambiguous cases surface to me.

7. **Universality test at every step.** When extracting content to the work profile, ask: "would another founder running a business find this useful as-is?" If no, it's instance-level, not profile-level.

8. **Run the Evolution loop normally.** Changes modify-then-validate — no bypassing the iron rule. Golden evals cover new behaviors before promotion.

9. **Experience records for every checkpoint.** Especially for surprises, refactor pain points, and things that inform Phase 1 planning.

10. **Flag Phase-0-choices-that-affect-later-phases.** If a Phase 0 decision meaningfully affects Phase 1 or Phase 2, surface it to me before implementing. Examples: directory structure choices, loader design choices, schema migration patterns.

### After Phase 0

11. **Write a Phase 0 retrospective.** What worked, what didn't, what Phase 1 planning should account for. Post to Captain's Dashboard.

12. **Wait for Phase 1 authorization.** I'll review the retro and decide whether to green-light Phase 1 as-scoped, adjust scope based on Phase 0 findings, or pause to reassess.

### Standing orders across all phases

13. **Preserve upstream-safe changes.** Framework and profile improvements flow through the founders-cabinet repo. Instance-level customizations stay in instance config. Three-layer separation is the mechanism; don't violate it.

14. **Flag late-phase implications early.** If a design decision in phase N meaningfully affects phase N+1 or later, surface it. Better to discuss now than rework later.

15. **Quality over speed.** Every phase is foundational for what comes after. Take whatever time is needed.

---

*Signed,*
*Nate*

---

*CoS: acknowledge receipt in Captain DM with any immediate clarifying questions. Confirm explicitly: (1) Phase 0 is authorized, (2) Phase 1 is planned-but-not-authorized, (3) Phases 2 and 3 are intent-only. Then begin Phase 0 planning. Golden evals proposed per checkpoint BEFORE execution begins — no exceptions.*
