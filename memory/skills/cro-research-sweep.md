# Skill: CRO Research Sweep Protocol

**Status:** promoted
**Created by:** CRO
**Date:** 2026-03-30
**Validated against:** 9 successful research sweeps (2026-03-28 to 2026-03-30), all 3 validation scenarios confirmed by experience records
**Usage count:** 9

## When to Use
When CRO runs a scheduled research sweep (every 4h) or receives a cron-triggered research request. Also applicable for ad-hoc research requests from other Officers.

## Procedure

1. **Check backlog** — Read `shared/backlog.md` for current sprint priorities. Identify what research questions are most actionable right now.
2. **Check recent briefs** — Glob `shared/interfaces/research-briefs/*.md` to avoid duplication. Identify gaps.
3. **Identify 2-3 research angles** — At least one aligned with current sprint, one forward-looking (NEXT sprint prep), and one edge scan (lateral thinking, blind spots).
4. **Run parallel API queries:**
   - **Perplexity `sonar-reasoning-pro`** — For broad synthesis, competitive analysis, multi-source questions. Use `sonar-pro` for simple factual/tactical lookups (faster, cheaper).
   - **Brave Search** — For specific pricing, news, tactical detail. Always use `extra_snippets=true&summary=true` for LLM Context mode.
   - **Exa** — For semantic discovery, finding unknown competitors, academic research. Use `"type": "auto"` (default) or `"type": "deep"` for complex queries.
5. **Cross-reference** — Run a second round of targeted queries to fill gaps from round 1.
6. **Synthesize into brief** — Write to `shared/interfaces/research-briefs/YYYY-MM-DD-topic.md`. Include: findings, action table (who/what/priority), edge scan section.
7. **Store raw data** — Write to `memory/tier3/research-archive/YYYY-MM-DD/`.
8. **Publish to Notion** — Create page in Research Hub database (ID in `instance/config/product.yml`).
9. **Notify Officers** — Use `notify-officer.sh`. Target by relevance:
   - Product insights → CPO
   - Technical findings → CTO
   - Strategic shifts → CoS
   - Include specific context: what's relevant to them and what they should do with it.
10. **Tag usage status** — Add a frontmatter block to each brief:
    ```
    ---
    usage_status: unread
    actioned_by: []
    ---
    ```
    Status values: `unread` → `reviewed` → `actioned` | `declined` | `archived`
    When CPO/CTO/CoS acts on a finding, they update the brief's status and add their role to `actioned_by`.
    CRO tracks actioned % in reflections to optimize research focus.
11. **Record experience** — `record-experience.sh` with actionable lessons.
12. **Update timestamp** — `redis-cli SET cabinet:schedule:last-run:cro:research-sweep`.
13. **Update Tier 2 notes** — If new competitors or market shifts discovered.

## Expected Outcome
A published research brief with actionable insights, delivered to the right Officers, stored in Notion and filesystem, with experience record written.

## Known Pitfalls
- **Perplexity gaps:** `sonar-reasoning-pro` sometimes returns "no results" for niche wellness/journaling queries. Fall back to `sonar-pro` or rephrase.
- **Monitoring sweeps too light:** If no new research questions, use the sweep for deeper dives on existing topics rather than surface-level monitoring.
- **Edge scanning forgotten:** Easy to skip lateral thinking under time pressure. Mandate at least one non-obvious angle per sweep.
- **Notification context:** Don't just say "brief published." Tell each Officer what's relevant to them specifically and what action they should take.

## Validation Scenarios
- Scenario 1: Sprint-aligned sweep → brief covers current blockers, notifies CTO with actionable items
- Scenario 2: Forward-looking sweep → brief prepares NEXT sprint, notifies CPO with spec inputs
- Scenario 3: Competitive alert → new competitor discovered, added to Tier 2 notes, CoS notified for Captain

## Origin
Experience records 1-9 (2026-03-28 to 2026-03-30). Pattern: API usage refined across all 9 sweeps, notification protocol stabilized by sweep 4, edge scanning added after Captain feedback.
