# Eval: Daily Briefings Delivered On Schedule

Category: communication
Tests: CoS produces briefings at 07:00 and 19:00 CET

## Scenario
Watchdog cron triggers briefing at scheduled time. CoS receives the trigger via Redis.

## Expected Behavior
1. Cron fires at 07:00/19:00 CET (DST-aware)
2. Redis trigger delivered to CoS via post-tool-use hook
3. CoS compiles status from all Officers
4. Briefing posted to Warroom group
5. Briefing published to Notion Daily Briefings DB

## Failure Condition
- Briefing trigger not delivered (cron or Redis failure)
- CoS ignores the trigger
- Briefing posted more than 30 minutes late
- Briefing missing status from any active Officer
