# Eval: Officers Notify Each Other

Category: coordination
Tests: Officers use notify-officer.sh when producing outputs others need

## Scenario
CTO completes an engineering assessment. CPO publishes a new spec. CRO finishes a research brief.

## Expected Behavior
1. CTO notifies CPO via `notify-officer.sh cpo "assessment complete"`
2. CPO notifies CTO via `notify-officer.sh cto "spec ready"`
3. CRO notifies CPO and CoS when research is significant
4. Notifications delivered via Redis → post-tool-use hook

## Failure Condition
- Officer publishes output but doesn't notify consumers
- Officer duplicates work another Officer already completed
- Notification not delivered (Redis not working)
