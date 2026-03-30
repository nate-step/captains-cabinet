# Skill: Individual Reflection

**Status:** promoted
**Created by:** foundation
**Date:** 2026-03-30
**Validated against:** experience record review, pattern detection
**Usage count:** 0

## When to Use

Every Officer runs this every 6 hours. Tracked via Redis: `cabinet:schedule:last-run:<role>:reflection`

## Procedure

1. **Read your recent experience records:**
   ```bash
   ls -lt memory/tier3/experience-records/$(date -u +%Y-%m-%d)-<your-role>-*.md | head -10
   ```
   Also check yesterday's if the 6h window spans midnight.

2. **Self-assess against your quality standards:**
   - "Am I following my foundation skills? Where did I deviate?"
   - "Am I seeing the same failure or friction point more than once?"

3. **Detect patterns:**
   - Same failure 2x → note it in `memory/tier2/<your-role>/patterns.md`
   - Same failure 3+ times → write a draft skill to `memory/skills/evolved/`

4. **Update Tier 2 working notes:**
   - Any new knowledge about the codebase, product, or domain
   - Any corrections to existing notes

5. **Record the reflection timestamp:**
   ```bash
   redis-cli -h redis -p 6379 SET "cabinet:schedule:last-run:<your-role>:reflection" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   ```

## Expected Outcome

Each Officer catches their own patterns before CoS's retro does. Tier 2 memory stays current. Draft skills emerge from repeated procedures.

## Known Pitfalls

- Reflecting without reading the actual records — just doing it from memory is unreliable
- Writing "everything went well" when records show friction — be honest with yourself
- Not updating Tier 2 notes — next session starts with stale context
- Forgetting to record the timestamp — leads to double-running or skipping

## Validation Scenarios

- Scenario 1: Officer notices a 3-time failure pattern → writes draft skill → CoS picks it up in next retro
- Scenario 2: Officer updates Tier 2 with new codebase knowledge → next session starts faster
- Scenario 3: Reflection finds no patterns → records timestamp → moves on (not every reflection produces output)

## Origin

Foundation skill — ships with the Founder's Cabinet.
