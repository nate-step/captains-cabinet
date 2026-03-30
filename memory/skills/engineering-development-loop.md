# Skill: Engineering Development Loop

**Status:** promoted
**Created by:** foundation
**Date:** 2026-03-30
**Validated against:** PR creation, CI failure recovery, code review cycle
**Usage count:** 0

## When to Use

Every time CTO (or CTO's Crew) implements a feature, fix, or refactor. No exceptions.

## Procedure

1. **Read the spec and acceptance criteria** before writing code. If the spec is unclear, notify CPO before building.

2. **Build on a feature branch.** Never commit directly to main.

3. **Verify locally — CI must pass before creating a PR.**
   - Run the project's build command
   - Run the test suite
   - Run linting and type checks
   - If ANY check fails: fix → re-run → loop until green
   - Do NOT create a PR with failing local checks

4. **Code review via independent verification.**
   - Spawn a separate Crew agent specifically for code review
   - The reviewer checks: correctness, edge cases, security, performance, spec compliance
   - Process review findings — fix issues, don't dismiss them
   - Re-run the review after fixes if the reviewer flagged critical issues
   - Loop until the reviewer is satisfied

5. **Create PR.**
   - Title references the backlog issue (e.g., issue prefix + number + description)
   - Description includes: what changed, why, how to test
   - CI must pass in the remote pipeline — if it fails, fix locally and push

6. **GitHub review loop (if applicable).**
   - Poll for review status
   - If changes requested: fix → push → poll again
   - Loop until approved and CI green

7. **Preview verification.**
   - If a preview deployment is generated, verify it works
   - If preview build fails: debug why, fix it, push, verify again
   - "It works on main" is NOT acceptable — fix the preview pipeline
   - If the failure is an infrastructure issue you cannot fix, document it in the PR and escalate to CoS

8. **Merge and record.**
   - Merge only when: CI green + review approved + preview verified (or documented exception)
   - Write an experience record immediately after merge
   - Notify CPO that the feature is ready for spec review

## Expected Outcome

Every merged PR has: passing CI, independent code review, working preview (or documented exception), and an experience record.

## Known Pitfalls

- Skipping local CI and hoping remote CI catches issues wastes time on push/wait cycles
- "It works on main" is always a workaround, never a solution — investigate root cause
- Code review by the same agent that wrote the code is not independent verification
- Forgetting the experience record means the learning loop has nothing to learn from

## Validation Scenarios

- Scenario 1: Local build fails → CTO fixes and re-runs until green before creating PR
- Scenario 2: Preview deployment fails → CTO investigates root cause, does not skip to "merge to main"
- Scenario 3: Code reviewer flags a security issue → CTO fixes and re-reviews before merging

## Origin

Foundation skill — ships with the Founder's Cabinet. Derived from engineering best practices and early Cabinet operation experience.
