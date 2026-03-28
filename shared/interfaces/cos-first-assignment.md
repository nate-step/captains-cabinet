# CoS First Assignment: Cabinet Gap Analysis

**Type:** Strategic assessment
**Priority:** P0 — Must complete before any other Officers come online
**Deliverables:** Gap analysis doc in Notion (Cabinet Operations), briefing to Sensed HQ group, DM to Captain

---

## Objective

You are the first Officer live. Before we bring CTO, CPO, and CRO online, we need a clear picture of what exists and what's missing — across the product, the backlog, the business knowledge, and the Cabinet infrastructure itself.

## Instructions

### 1. Discover the Product

Explore the product codebase at `/workspace/product`:
- What framework, language, structure?
- What features are built vs. scaffolded vs. missing?
- What's the database schema? (Query Neon)
- What's deployed? (Check Vercel if accessible)

Write your findings to `memory/tier2/cos/product-discovery.md`.

### 2. Audit the Business Brain

Read the Notion Business Brain (IDs in `config/product.yml`):
- Vision, Strategy Brief, Brand Guidelines, Messaging Pillars, Growth Guardrails, Pricing
- Are these complete and coherent, or do they have gaps?
- Is there alignment between vision and what's actually built?

### 3. Assess the Linear Backlog

Check the Linear Sensed workspace:
- How many issues exist? What states are they in?
- Is there a clear priority stack, or is it a flat list?
- Are there specs linked, or just titles?

### 4. Evaluate Cabinet Readiness

Check what the Cabinet itself needs before scaling:
- Are all shared interfaces directories created?
- Do the memory tier directories exist and have correct permissions?
- Are the Notion databases populated or empty shells?
- Can you successfully write to Notion (test by creating a dummy briefing, then delete it)?

### 5. Produce the Gap Analysis

Create a Notion page in the Cabinet Operations section with:
- **Product Status:** What exists, what's missing, what's broken
- **Business Knowledge Status:** What's documented, what's vague, what's absent
- **Backlog Status:** Health assessment, priority clarity, spec coverage
- **Cabinet Infrastructure Status:** What works, what needs fixing before Phase 2
- **Recommended First Priorities:** Top 3-5 things the Cabinet should tackle first when all Officers are online

### 6. Brief the Captain

- Post a summary to the Sensed HQ group (use `bash /opt/founders-cabinet/cabinet/scripts/send-to-group.sh`)
- DM the Captain with the top findings and any decisions needed

---

## Success Criteria

- [ ] Product discovery notes written to Tier 2
- [ ] All Notion Business Brain pages read and assessed
- [ ] Linear backlog audited
- [ ] Cabinet infrastructure verified
- [ ] Gap analysis published to Notion
- [ ] Sensed HQ group briefed
- [ ] Captain DM'd with summary and decisions needed
