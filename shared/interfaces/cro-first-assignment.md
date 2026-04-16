# CRO First Assignment: Market Landscape & Competitive Intelligence

**Type:** Research assessment
**Priority:** P0 — Must complete before entering the 4-hour sweep cadence
**Deliverables:** Tier 2 working notes, research briefs in Notion Research Hub, briefing to Warroom group

---

## Objective

You are the new CRO. Before entering the automated research sweep cadence, you need a foundational understanding of the market, the competition, and the user landscape. Produce an initial intelligence package that CPO and CoS can use immediately.

## Instructions

### 1. Absorb Context

Read the business brain in Notion (IDs in `instance/config/product.yml`):
- Vision: What is Sensed? What human need does it address?
- Strategy Brief: Market positioning, growth thesis, differentiation
- Brand Guidelines + Messaging Pillars: How Sensed talks about itself
- Growth Guardrails: What Sensed won't do

Read the CPO's product roadmap in Notion Product Hub — understand what's being built now vs. later.

Read `shared/backlog.md` for current priorities.

Write your synthesis to `instance/memory/tier2/cro/market-context.md`.

### 2. Competitive Landscape

Using Perplexity, Brave Search, and Exa, research:
- **Direct competitors:** Apps that map or track personal experiences, inner states, or meaningful moments (e.g., journaling apps with location, experience mapping, emotional tracking)
- **Adjacent players:** Mindfulness/meditation apps, life logging apps, memory/nostalgia apps, location-based social networks
- **Emerging threats:** AI-powered personal tracking, Apple/Google native features that could overlap

For each competitor, capture: name, positioning, key features, pricing, user base size (if available), strengths, weaknesses.

Publish to Notion Research Hub (Competitive Intelligence DB).

### 3. Market Sizing & Trends

Research:
- Market size for experiential/wellness apps
- Growth trends in mindfulness, self-tracking, and experience-sharing
- User behavior patterns: how people currently record and reflect on experiences
- Technology trends: AI in personal apps, spatial computing, AR/VR experiences

Publish to Notion Research Hub (Market Trends DB).

### 4. Initial Research Brief

Write your first research brief covering:
- **Competitive positioning map:** Where Sensed sits relative to alternatives
- **Key differentiation:** What Sensed does that nobody else does (dual-map thesis)
- **Market gaps:** Opportunities competitors aren't addressing
- **Risks:** Competitive threats to watch, market headwinds
- **Recommended research priorities:** What to dig into in future sweeps

Publish to Notion Research Hub (Research Briefs DB) and write a copy to `shared/interfaces/research-briefs/`.

### 5. Coordinate

- Post a summary to the Warroom group
- Notify CPO via Redis (`notify-officer.sh cpo "CRO initial research package ready — check Research Hub in Notion"`)
- Notify CoS via Redis (`notify-officer.sh cos "CRO initial intelligence complete — competitive landscape and market sizing in Notion"`)

---

## Success Criteria

- [ ] Business context absorbed, synthesis in Tier 2
- [ ] 5+ competitors profiled in Notion Competitive Intelligence DB
- [ ] Market sizing and trends in Notion Market Trends DB
- [ ] Initial research brief published (Notion + shared/interfaces/)
- [ ] Warroom group briefed
- [ ] CPO and CoS notified
