# Skill: Cross-Officer Retrospective

**Status:** promoted
**Created by:** foundation
**Date:** 2026-03-30
**Validated against:** coordination pattern detection, improvement proposal cycle
**Usage count:** 0

## When to Use

CoS runs this every 24 hours. Triggered by cron or run on demand. Tracked via Redis: `cabinet:schedule:last-run:cos:retrospective`

## Procedure

1. **Gather all experience records since last retro:**
   ```bash
   ls -lt memory/tier3/experience-records/ | head -50
   ```
   Read each record. Group by Officer and by outcome.

2. **Analyze cross-Officer coordination patterns:**
   - **Handoff quality:** Are specs clear enough for CTO? Are research briefs actionable for CPO?
   - **Trigger responsiveness:** Are Officers acting on triggers promptly? Any SLA violations?
   - **Communication gaps:** Is work getting stuck between Officers? Are outputs sitting unread?
   - **Communication isolation:** Are Officers producing outputs without notifying peers?

3. **Analyze individual patterns** (supplement to Officers' own 6h reflection):
   - Same failure happening twice → note it in `memory/tier2/cos/patterns.md`
   - Same failure happening 3+ times → propose a change (new skill in `memory/skills/evolved/`, role update, or process fix)

4. **Draft improvement proposals:**
   Write to Notion Cabinet Operations (Improvement Proposals DB). Each proposal must include:
   - What pattern was observed (with links to experience records)
   - What change is proposed
   - How to validate the change (test scenario)
   - Rollback plan if it doesn't work

5. **Submit to Captain:**
   DM the Captain with a summary of proposals. Wait for approval before promoting changes to role definitions, skills, or the Constitution.

6. **Record:**
   - Write an experience record for the retro itself
   - Record the timestamp:
   ```bash
   redis-cli -h redis -p 6379 SET "cabinet:schedule:last-run:cos:retrospective" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   ```

## Expected Outcome

Cross-Officer coordination problems are caught within 24 hours. Improvement proposals are specific, validated, and actionable. The Captain receives a clear summary with recommendations.

## Known Pitfalls

- Reviewing records without looking for cross-Officer patterns — that's just individual reflection
- Proposing changes without validation scenarios — that's improvement drift
- Producing a report nobody reads — keep it focused and actionable
- Running the retro mechanically without actually finding patterns — if there are no patterns, say so and move on

## Validation Scenarios

- Scenario 1: Retro finds CTO is consistently asking CPO for spec clarification → proposes spec template improvement
- Scenario 2: Retro finds triggers are being ignored for 2+ hours → proposes SLA with auto-escalation
- Scenario 3: Retro finds no significant patterns → records "clean retro" and moves on

## Origin

Foundation skill — ships with the Founder's Cabinet.
