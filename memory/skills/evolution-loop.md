# Skill: Evolution Loop

**Status:** promoted
**Created by:** foundation
**Date:** 2026-03-30
**Validated against:** skill promotion cycle, golden eval validation
**Usage count:** 0

## When to Use

CoS runs this every 24 hours, immediately after the cross-officer retro. Tracked via Redis: `cabinet:schedule:last-run:cos:evolution`

## Procedure

1. **Review draft skills:**
   - List all skills in `memory/skills/evolved/` with status `draft`
   - For each draft: has it been used enough to validate? Are the validation scenarios adequate?

2. **Validate candidate skills:**
   - Run each validation scenario mentally or via a test
   - Check: does the skill produce the expected outcome? Does it handle the known pitfalls?
   - If validated → update status to `validated`
   - If not → leave as `draft` with notes on what failed

3. **Promote validated skills:**
   - Skills that are `validated` AND Captain-approved → update status to `promoted`
   - Promoted skills are loaded by Officers when relevant tasks arise

4. **Review promoted skills for demotion signals:**
   - Search recent experience records for failures that cite a promoted skill ("followed X skill, failed because...")
   - Check: are there promoted skills that should have been used in recent work but weren't referenced? (unused in their domain)
   - Check: does any newly promoted skill supersede an older one?
   - If a demotion signal is found → mark the skill `under-review` and investigate:
     - Was the failure caused by the skill, or by the officer not following it correctly?
     - If the skill is broken: attempt to fix it first (update the procedure, re-validate)
     - If genuinely obsolete or superseded: mark as `archived` with a reason note
   - CoS can archive skills autonomously (unlike promotion, which needs Captain approval) — inform Captain in the next briefing

5. **Review pending improvement proposals:**
   - Check Notion Cabinet Operations for proposals awaiting Captain decision
   - For Captain-approved proposals: implement the change (update role definition, skill, or process)
   - For rejected proposals: archive with the Captain's reasoning

5. **Update golden evals:**
   - If new patterns warrant new test scenarios, add them to `memory/golden-evals/`
   - All promoted changes must still pass existing evals

6. **Record:**
   - Write an experience record for the evolution loop
   - If no improvements qualified for promotion, record that — it's a valid outcome
   - Record the timestamp:
   ```bash
   redis-cli -h redis -p 6379 SET "cabinet:schedule:last-run:cos:evolution" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   ```

## Expected Outcome

The skill library grows with validated procedures. Golden evals expand to cover new patterns. Changes that don't improve outcomes are not promoted. The system gets measurably better over time.

## Known Pitfalls

- Promoting skills without validation — that's improvement drift, not improvement
- Skipping the evolution loop when there's "nothing to do" — still record it so the pattern is visible
- Promoting changes that haven't been tested against golden evals
- Letting the draft skills pile up without reviewing them
- Never demoting skills — a library that only grows becomes noisy and contradictory
- Demoting a skill because one officer failed to follow it — that's a training issue, not a skill issue
- Deleting archived skills — keep them with reason notes so the Cabinet doesn't re-invent them

## Validation Scenarios

- Scenario 1: Draft skill has 3+ successful usage records → validated → Captain approves → promoted
- Scenario 2: Draft skill fails validation → stays as draft with notes → revisited next cycle
- Scenario 3: No drafts or proposals ready → evolution loop records "no changes" and completes in under 5 minutes
- Scenario 4: Promoted skill cited in 2 failure records → marked `under-review` → CoS finds the procedure is outdated → updates and re-validates → stays promoted with fixes
- Scenario 5: New skill supersedes old one → old skill archived with "superseded by X" note

## Origin

Foundation skill — ships with the Founder's Cabinet.
