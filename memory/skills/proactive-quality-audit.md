# Skill: Proactive Quality Audit

**Status:** promoted
**Created by:** foundation
**Date:** 2026-03-30
**Validated against:** output quality review, gap detection
**Usage count:** 0

## When to Use

CoS runs this continuously between scheduled work. Not a cron job — an ongoing responsibility whenever CoS has bandwidth.

## Procedure

1. **Audit CTO outputs:**
   - Check recent PRs on GitHub — is CI passing? Are there code review comments?
   - Is CTO following the engineering development loop skill?
   - Are experience records being written after merges?

2. **Audit CPO outputs:**
   - Read recent specs in `shared/interfaces/product-specs/`
   - Do they meet the spec quality gate? Are acceptance criteria testable?
   - Is the Linear backlog groomed — no stale issues, clear priorities?

3. **Audit CRO outputs:**
   - Read recent research briefs in `shared/interfaces/research-briefs/`
   - Are they actionable? Do they end with concrete recommendations?
   - Is research connected to current sprint priorities?

4. **Check trigger responsiveness:**
   - Are Officers acknowledging and acting on triggers promptly?
   - Are any triggers sitting in Redis unprocessed for 1+ hours?

5. **Act on findings:**
   - When you find a problem: notify the Officer with specific feedback immediately
   - If the same problem repeats after feedback: escalate to Captain
   - Don't wait for the retro to flag obvious quality gaps

## Trigger Accountability

- After **1 hour** without trigger acknowledgment: CoS follows up with the target Officer
- After **2 hours**: CoS escalates to Captain with context
- Track trigger response patterns and flag Officers who are consistently slow

## Expected Outcome

Quality problems are caught before they compound. Officers get timely feedback. The Captain only hears about persistent issues, not one-off mistakes.

## Known Pitfalls

- Becoming a message router instead of a quality auditor
- Waiting for the retro to flag problems that are obvious now
- Auditing without actionable feedback ("this isn't great" vs. "acceptance criteria on line 3 aren't testable")
- Micromanaging instead of auditing — check outputs, don't dictate process

## Validation Scenarios

- Scenario 1: CTO merges PR with failing CI → CoS catches it within 30 minutes and notifies CTO
- Scenario 2: Trigger sits unprocessed for 90 minutes → CoS follows up with target Officer
- Scenario 3: CPO publishes spec missing edge cases → CoS provides specific feedback before CTO starts building

## Origin

Foundation skill — ships with the Founder's Cabinet.
