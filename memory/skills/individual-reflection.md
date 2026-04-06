# Skill: Individual Reflection (Evolved)

**Status:** promoted
**Created by:** foundation (evolved by CoS per Captain directive 2026-04-04)
**Date:** 2026-04-04
**Validated against:** experience record review, pattern detection, value maximization
**Usage count:** 0

## When to Use

Every Officer runs this every 6 hours. Tracked via Redis: `cabinet:schedule:last-run:<role>:reflection`

## Procedure

1. **Read your recent experience records:**
   ```bash
   ls -lt memory/tier3/experience-records/$(date -u +%Y-%m-%d)-<your-role>-*.md | head -10
   ```
   Also check yesterday's if the 6h window spans midnight. If you have ZERO records since last reflection, that's a red flag — you were idle.

2. **Self-assess with SPECIFIC answers (not "all clear"):**
   - "What did I actually produce in the last 6 hours?" — name concrete outputs (PRs, specs, briefs, tests, audits)
   - "What went wrong or was harder than expected?" — name at least one friction point
   - "What did I learn that I didn't know before?" — name one thing
   - If you can't answer these, you weren't doing enough real work.

3. **Detect patterns:**
   - Same failure 2x → note it in `memory/tier2/<your-role>/patterns.md`
   - Same failure 3+ times → write a draft skill to `memory/skills/evolved/`

4. **Value maximization — produce at least ONE actionable idea:**
   - "What's the highest-value thing I could do RIGHT NOW that nobody asked me to?"
   - "What gap exists in the product/process that my skills could fill?"
   - "What did another officer produce that I should build on?"
   - You MUST produce at least one concrete idea or proposal. "All clear" is not acceptable.
   - Send proposals to CoS via `notify-officer.sh cos "..."`. CoS routes to Captain if it requires approval.

5. **Update Tier 2 working notes:**
   - Any new knowledge about the codebase, product, or domain
   - Any corrections to existing notes
   - What you plan to work on in the next 6 hours

6. **Write an experience record for the reflection itself:**
   Include: what you produced, what you learned, and your next action.
   ```bash
   bash /opt/founders-cabinet/cabinet/scripts/record-experience.sh <role> success "6h reflection" "Produced: [list]. Learned: [what]. Next: [action]." "Friction: [what]. Idea: [proposal]." "reflection"
   ```

7. **Record the reflection timestamp:**
   ```bash
   redis-cli -h redis -p 6379 SET "cabinet:schedule:last-run:<your-role>:reflection" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   ```

## Expected Outcome

Each Officer catches their own patterns before CoS's retro does. Tier 2 memory stays current. Draft skills emerge from repeated procedures. Officers proactively surface ideas for increasing their value — the Cabinet continuously improves from within, not just from Captain direction.

## Known Pitfalls

- Reflecting without reading the actual records — just doing it from memory is unreliable
- Writing "everything went well" when records show friction — be honest with yourself
- Not updating Tier 2 notes — next session starts with stale context
- Forgetting to record the timestamp — leads to double-running or skipping
- Skipping the value maximization step — this is how the Cabinet grows smarter

## Validation Scenarios

- Scenario 1: Officer notices a 3-time failure pattern → writes draft skill → CoS picks it up in next retro
- Scenario 2: Officer updates Tier 2 with new codebase knowledge → next session starts faster
- Scenario 3: Reflection finds no patterns → records timestamp → moves on (not every reflection produces output)
- Scenario 4: CRO realizes specs are shipping without research input → proposes tighter CPO integration → CoS approves

## Origin

Foundation skill — evolved per Captain directive to add proactive value maximization.
