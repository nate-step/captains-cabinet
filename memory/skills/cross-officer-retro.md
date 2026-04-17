# Skill: Cross-Officer Retrospective (Evolved)

**Status:** promoted
**Created by:** foundation (evolved by CoS per Captain directive 2026-04-04)
**Date:** 2026-04-04
**Validated against:** coordination pattern detection, improvement proposal cycle, opportunity scanning
**Usage count:** 6

## When to Use

CoS runs this event-triggered: at 5 accumulated reflections across officers (`cabinet:reflections:count >= 5`) OR 48 hours since the last retro — whichever first. Tracked via Redis: `cabinet:schedule:last-run:cos:retrospective`

## Procedure

### Part 1: Experience Record Review (existing)

1. **Gather all experience records since last retro:**
   ```bash
   ls -lt memory/tier3/experience-records/ | head -50
   ```
   Read each record. Group by Officer and by outcome.

2. **Analyze cross-Officer coordination patterns:**
   - **Handoff quality:** Are specs clear enough for CTO? Are research briefs actionable for CPO?
   - **Trigger responsiveness:** Are Officers acting on triggers promptly? Any SLA violations?
   - **Communication gaps:** Is work getting stuck between Officers? Are outputs sitting unread?
   - **Quality pyramid compliance:** Is each layer being followed? Any layers being skipped?

3. **Analyze individual patterns** (supplement to Officers' own 6h reflection):
   - Same failure happening twice → note it
   - Same failure happening 3+ times → propose a change

### Part 2: Opportunity Scan (NEW)

4. **Tool & feature scan:**
   - What new tools, APIs, or platform features launched this week?
   - Check: Claude Code changelog, Vercel updates, Neon features, ElevenLabs models, Linear updates
   - Would any of these improve our product or workflow?

5. **Competitive lateral scan:**
   - What are competitors doing that we should steal or avoid?
   - Any adjacent-space innovations we could adapt?
   - Cross-reference with CRO's latest briefs

6. **Workflow automation check:**
   - Is any Officer doing something manually that could be automated?
   - Are there repeated steps that should become a hook, script, or skill?

### Part 3: "How Could We Do This Smarter?" (NEW)

7. **Pick ONE process and challenge it:**
   - Choose one current process, workflow, or convention
   - Ask: "If we were starting fresh today, would we do it this way?"
   - Not everything — just one thing per retro. Focused kaizen.
   - Examples:
     - "Is the 5min poll loop the right cadence?"
     - "Should CRO briefs be shorter?"
     - "Is the experience record format too verbose?"
     - "Are we over-engineering the retro itself?"
   - If the answer is "yes, we'd do it the same" — record that and move on
   - If the answer is "no" — draft a proposal

### Part 4: Proposals & Recording (existing)

8. **Draft improvement proposals:**
   Write to Notion Cabinet Operations (Improvement Proposals DB). Each proposal must include:
   - What pattern/opportunity was identified
   - What change is proposed
   - How to validate the change
   - Rollback plan

9. **CRO research effectiveness review:**
   - Check `usage_status` on recent CRO briefs
   - What % were actioned vs declined?
   - Are there patterns in what gets used vs what doesn't?
   - Feed back to CRO: "more of X, less of Y"

10. **Submit to Captain:**
    DM Nate with a summary of proposals. Wait for approval before promoting changes.

11. **Record:**
    - Write an experience record for the retro itself
    - Record the timestamp:
    ```bash
    redis-cli -h redis -p 6379 SET "cabinet:schedule:last-run:cos:retrospective" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ```

## Expected Outcome

Cross-Officer coordination problems caught within 24h. Opportunities for improvement surfaced proactively. One process challenged per cycle. CRO research effectiveness tracked. The Cabinet gets measurably better — not just by fixing failures, but by finding better ways to work.

## Known Pitfalls

- Reviewing records without looking for cross-Officer patterns — that's just individual reflection
- Skipping the opportunity scan because "nothing new happened" — something always changed
- Picking the same process to challenge every retro — rotate
- Over-engineering the "smarter" section — keep it to one focused question, not a redesign
- Proposing changes without validation scenarios
- Running the retro mechanically — if there are no patterns, say so and move on

## Validation Scenarios

- Scenario 1: Retro finds CTO is skipping Layer 1 reviews → proposes enforcement mechanism
- Scenario 2: Opportunity scan finds new Vercel feature → proposes adoption to CTO
- Scenario 3: "Smarter?" section challenges poll cadence → proposes 10min instead of 5min → validates token savings
- Scenario 4: CRO brief tracking shows 80% actioned rate → CRO doing well, no change needed
- Scenario 5: Clean retro with no failures → opportunity scan still produces one finding

## Origin

Foundation skill — evolved per Captain directive 2026-04-04. Added: Opportunity Scan (Part 2), "How Could We Do This Smarter?" (Part 3), CRO research effectiveness review (step 9).
