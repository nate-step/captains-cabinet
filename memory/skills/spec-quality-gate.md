# Skill: Spec Quality Gate

**Status:** promoted
**Created by:** foundation
**Date:** 2026-03-30
**Validated against:** spec review, CTO feedback cycle
**Usage count:** 0

## When to Use

Every time CPO writes or updates a product specification before publishing to shared interfaces or notifying CTO.

## Procedure

Before publishing a spec, verify all 5 checks pass:

1. **Problem is real.** Can you point to a Captain directive, research brief, or user feedback that justifies this work? If not, don't spec it.

2. **Acceptance criteria are testable.** Each criterion must be verifiable by someone who didn't write the spec. "Works well" is not testable. "Report button appears in the signal card overflow menu" is testable.

3. **Edge cases are covered.** What happens with empty states, errors, permissions, offline, missing data? If you can't think of edge cases, you haven't thought hard enough.

4. **Dependencies are identified.** What must exist before CTO can build this? Other features, API endpoints, database tables, third-party accounts?

5. **Context is incorporated.** Have you checked the business brain in Notion for relevant brand/strategy context? Have you checked recent research briefs from CRO?

If any check fails, fix the spec before publishing. Don't publish drafts that need CTO to fill in the gaps.

## Expected Outcome

Every published spec has: clear problem statement with evidence, testable acceptance criteria, identified edge cases, mapped dependencies, and relevant business context.

## Known Pitfalls

- Specs that say "standard behavior" or "follow best practices" without defining what that means
- Missing edge cases that CTO discovers during implementation — wasted back-and-forth
- Specs without acceptance criteria lead to ambiguous "is this done?" discussions
- Publishing a spec without checking research briefs may miss market context that changes the design

## Validation Scenarios

- Scenario 1: CPO writes spec → runs quality gate → finds missing edge cases → adds them before notifying CTO
- Scenario 2: CPO writes spec → acceptance criteria are all testable → CTO can verify implementation independently
- Scenario 3: Spec references a Captain directive as justification → traceable to strategic intent

## Origin

Foundation skill — ships with the Founder's Cabinet.
