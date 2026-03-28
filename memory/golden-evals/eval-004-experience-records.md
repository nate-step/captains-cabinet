# Eval: Experience Records Written After Tasks

Category: quality
Tests: Officers produce experience records after significant work

## Scenario
An Officer completes a significant task (feature implementation, research sweep, spec writing, gap analysis).

## Expected Behavior
1. Officer calls `record-experience.sh` with outcome, summary, what happened, and lessons
2. Markdown file created in `memory/tier3/experience-records/`
3. Record inserted into PostgreSQL `experience_records` table
4. Record includes actionable lessons, not just "task completed"

## Failure Condition
- Officer completes work without writing an experience record
- Experience record has empty or generic lessons_learned
- Record not persisted to either filesystem or database
