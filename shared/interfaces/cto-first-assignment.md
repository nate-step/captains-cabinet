# CTO First Assignment: Codebase Deep Dive & Engineering Assessment

**Type:** Technical assessment
**Priority:** P0 — Must complete before taking on implementation work
**Deliverables:** Tier 2 working notes, Architecture Decision in Notion Engineering Hub, briefing to Sensed HQ group

---

## Objective

You are the new CTO. Before building anything, you need to deeply understand the codebase, the database, and the deployment pipeline. Produce an engineering assessment that becomes your reference for all future work.

## Instructions

### 1. Explore the Codebase

The product repo is at `/workspace/product`. Map the full structure:
- Project layout: monorepo? workspaces? packages?
- Framework versions (Next.js, React Native, Expo)
- Key directories and their purposes
- Entry points (web, mobile, API)
- Shared code / libraries

Write findings to `memory/tier2/cto/codebase-map.md`.

### 2. Understand the Database

Query the Neon database:
- Full schema: tables, columns, types, constraints, indexes
- Relationships and foreign keys
- Row counts per table (gauge data maturity)
- Any migrations pending or migration history

Write findings to `memory/tier2/cto/database-schema.md`.

### 3. Assess Build & Deploy Pipeline

Check:
- `package.json` scripts: what's the build/test/dev/lint setup?
- Does `npm run build` succeed?
- Are there tests? Do they pass?
- Vercel config (if any): `vercel.json`, environment variables needed
- CI/CD: GitHub Actions, pre-commit hooks?

### 4. Identify Technical Debt

Based on your exploration:
- Missing or incomplete error handling
- Missing tests (coverage assessment)
- Hardcoded values that should be env vars
- Unused dependencies
- Performance concerns
- Security considerations

### 5. Publish Engineering Assessment

Create a Notion page in Engineering Hub (Architecture Decisions DB) with:
- **Codebase Health:** Structure, patterns, quality assessment
- **Database Health:** Schema quality, index coverage, migration state
- **Build Pipeline:** What works, what's missing
- **Technical Debt Top 10:** Ranked by impact
- **Recommended First Engineering Tasks:** What to build/fix first

### 6. Coordinate

- Post a summary to Sensed HQ group
- Notify CPO via Redis (`notify-officer.sh cpo "CTO assessment complete — check Engineering Hub in Notion"`)
- Read the CoS gap analysis in Notion Cabinet Operations for context

---

## Success Criteria

- [ ] Codebase map written to Tier 2
- [ ] Database schema documented in Tier 2
- [ ] Build pipeline tested and documented
- [ ] Tech debt identified and ranked
- [ ] Engineering assessment published to Notion
- [ ] Sensed HQ group briefed
- [ ] CPO notified
