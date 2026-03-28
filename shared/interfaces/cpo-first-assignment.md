# CPO First Assignment: Backlog Audit & Product Roadmap

**Type:** Product assessment
**Priority:** P0 — Must complete before writing specs or prioritizing work
**Deliverables:** Tier 2 working notes, Product Roadmap in Notion Product Hub, briefing to Sensed HQ group

---

## Objective

You are the new CPO. Before writing specs or prioritizing sprints, you need to understand the product's current state, the business context, and the backlog. Produce a product roadmap that aligns with the Captain's vision.

## Instructions

### 1. Absorb the Business Brain

Read every doc in Notion Business Brain (IDs in `config/product.yml`):
- Vision: What is Sensed? What problem does it solve?
- Strategy Brief: How do we win?
- Brand Guidelines + Messaging Pillars: How do we talk about it?
- Growth Guardrails: What are we not willing to do?
- Pricing: What's the model? (Note: Captain approval pending on Option B at $4.99/mo)

Write a synthesis to `memory/tier2/cpo/business-context.md`.

### 2. Audit the Linear Backlog

Go through the entire Linear Sensed workspace:
- How many issues? In what states?
- Are there well-defined projects/milestones?
- Which issues have specs? Which are just titles?
- What's the priority distribution? (How many P0/P1/P2?)
- Identify issues that are duplicates, stale, or poorly scoped

Write findings to `memory/tier2/cpo/backlog-audit.md`.

### 3. Read the CoS Gap Analysis

Check Notion Cabinet Operations for CoS's gap analysis. Pay attention to:
- Product codebase score and gaps
- Blockers identified (Mapbox ✅, Voyage ✅, Apple Dev April 1st)
- Suggested priorities

### 4. Create the Product Roadmap

In Notion Product Hub (Product Roadmap DB), create entries for:
- **Now (this week):** Top 3-5 items the CTO should work on immediately
- **Next (next 2 weeks):** Features and fixes queued after Now
- **Later (this month):** Bigger initiatives that need specs first

Each roadmap entry should reference the Linear issue (if exists) or note that one needs to be created.

### 5. Write the First Sprint's Spec Queue

Identify the top 3 features/fixes from "Now" that need specs. Write initial specs to `shared/interfaces/product-specs/` following the spec format in your role definition. These don't need to be perfect — they need to be good enough for the CTO to start.

### 6. Coordinate

- Post a summary to Sensed HQ group
- Notify CTO via Redis (`notify-officer.sh cto "CPO roadmap and first specs ready — check Product Hub in Notion and shared/interfaces/product-specs/"`)
- Update `shared/backlog.md` with the prioritized Now/Next/Later view

---

## Success Criteria

- [ ] Business context synthesis written to Tier 2
- [ ] Linear backlog fully audited
- [ ] CoS gap analysis reviewed
- [ ] Product Roadmap created in Notion with Now/Next/Later
- [ ] Top 3 specs written to shared/interfaces/product-specs/
- [ ] shared/backlog.md updated
- [ ] Sensed HQ group briefed
- [ ] CTO notified
