# Skill: 5-Layer Quality Pyramid

**Status:** promoted
**Created by:** CoS (Captain-approved 2026-04-04)
**Date:** 2026-04-04
**Validated against:** pending first full cycle
**Usage count:** 0

## When to Use

Every Officer follows their layer(s) for every piece of work that touches the product codebase or user experience.

## The 5 Layers

### Layer 1: Pre-Push Review (CTO, every commit)

Before pushing ANY code to a branch:

1. Run build + lint + type check + tests locally — all must pass
2. Spawn a Crew agent (Sonnet) to review the git diff:
   - Logic errors
   - Security: XSS, injection, hardcoded secrets, auth bypass
   - Performance: N+1 queries, missing indexes, unnecessary re-renders
   - Spec compliance: does it match the acceptance criteria?
3. If Crew finds critical issues: fix before push, no exceptions
4. Cost: ~1-3 minutes per commit (Crew spawn + diff review)

**This is NOT optional.** High-tempo sessions do not skip this layer.

### CoS: Quality Pyramid Compliance Auditing

CoS audits all 5 layers during proactive quality audits:
- Is CTO spawning Crew reviews? (check experience records for "pre-push review" tags)
- Are GitHub Action findings being resolved before merge?
- Is COO validating every deploy?
- Is CPO checking spec compliance on shipped features?
- Is the weekly audit happening on schedule?

### Layer 2: PR Review (GitHub Actions, automated)

On every PR open/sync:

- CI pipeline: build, lint, test (ci.yml)
- Claude Code Review: automated review (claude-code-review.yml)
- UI Screenshot Review: visual regression (ui-screenshot-review.yml)
- E2E tests: critical flow validation (e2e.yml)
- QA Explorer: exploratory testing (qa-explorer.yml)

**CTO MUST check and resolve all review findings before merging.** No merging with unresolved GitHub Action failures or review comments.

### Layer 3: Post-Deploy Validation (COO, after every merge)

After code deploys to production:

1. Poll Vercel until READY (deploy-and-verify skill)
2. Git diff review: every line of deployed code
3. Route validation: all links resolve, no 404s
4. Content accuracy: matches Notion source of truth
5. Visual consistency: matches Particle S design system
6. Console errors: zero tolerance
7. Legal compliance: privacy/terms links present on registration
8. File Linear issues for anything wrong
9. Confirm to CTO: "validated" or "bugs filed"

### Layer 4: Feature Validation (cross-officer, after feature ships)

When CTO notifies "SEN-XXX deployed":

- **CPO:** Review against spec — does implementation match acceptance criteria? File "spec-deviation" bugs if not.
- **COO:** Test as real user — is the UX intuitive? Any friction points?
- **CRO:** If the feature was motivated by a CRO research brief, validate it serves the identified user need. Not every feature needs CRO validation — only research-driven ones.

Trigger: CTO → CPO notification after deploy. CPO owns the validation loop.

### Layer 5: Periodic Audit (CTO, weekly + sprint boundaries)

Every 7 days or after major sprint completion:

1. Full codebase scan: security, performance, dead code, consistency
2. Dependency audit: outdated packages, known vulnerabilities
3. Performance benchmarks: LCP, CLS, API response times
4. Schema health: indexes, query patterns, N+1 detection
5. Architecture review: tech debt assessment
6. Output: Linear issues + summary to CoS

## What Each Layer Catches

- Layer 1: typos, logic errors, security holes — before they hit GitHub
- Layer 2: integration failures, visual regressions, test failures
- Layer 3: deploy failures, broken routes, content mismatches
- Layer 4: "built correctly but doesn't match what we asked for"
- Layer 5: systemic issues, accumulated debt, performance degradation

## Known Pitfalls

- Skipping Layer 1 under tempo pressure — this is how bugs reach users
- Merging despite GitHub Action failures — defeats the purpose
- COO validating only uptime, not user experience — must be comprehensive
- Skipping Layer 4 — "it deployed, it's done" misses spec deviations
- Layer 5 becoming a checkbox — must produce real findings, not "all good"

## Origin

Captain directive 2026-04-04. Designed to address repeated quality gaps: premature deploy announcements, missed 404s, content mismatches, skipped reviews under tempo.
