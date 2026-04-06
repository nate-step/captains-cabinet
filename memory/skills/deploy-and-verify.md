# Skill: Deploy and Verify

**Status:** draft
**Created by:** CTO (via CoS per Captain directive 2026-04-01)
**Date:** 2026-04-01
**Validated against:** pending — first use will validate
**Usage count:** 0

## When to Use

After every push to main branch. Before announcing anything as "shipped" or "live" to any Officer, the Captain, or the warroom.

## Procedure

1. **Push to main** — code auto-deploys via Vercel.

2. **Poll Vercel API** until deployment state is `READY` or `ERROR`:
   ```bash
   curl -s -H "Authorization: Bearer $VERCEL_TOKEN" \
     "https://api.vercel.com/v6/deployments?projectId=$PROJECT_ID&teamId=$TEAM_ID&limit=2&target=production" \
     | python3 -c 'import sys,json; [print(f"{d["state"]} {d.get("meta",{}).get("githubCommitSha","?")[:7]}") for d in json.load(sys.stdin).get("deployments",[])]'
   ```
   Poll every 30 seconds, up to 10 minutes max.

3. **If ERROR:** Fix the issue silently, re-push, re-poll. Do NOT message the Captain or warroom about the failure. Only notify COO if the fix takes more than 2 attempts.

4. **If READY:** Only NOW announce the deployment. Notify:
   - COO: "Deployed: SEN-XXX — [description]" (triggers validation)
   - Captain/warroom: include in status updates
   - Use "deployed" or "live" — never before READY state is confirmed

5. **Never say "shipped" or "live" without verified READY state.** This is the core rule. The Captain tests on the deployed site — announcing before deploy completes wastes his time.

## Expected Outcome

Every announcement of shipped code corresponds to a verified live deployment. The Captain never clicks a link to find stale code.

## High-Tempo Mode (5+ deploys in a session)

During design marathons or rapid iteration sessions with 5+ pushes to main:

1. **Per-deploy verification still required** — poll Vercel for each push. Don't announce anything mid-session.
2. **Batch the COO trigger** — instead of notifying COO per deploy, send ONE summary trigger at session end:
   ```
   notify-officer.sh coo "Session complete: N deploys. Key changes: [list]. Please run full validation."
   ```
3. **Session-end announcement** — only message Captain/warroom once, at the end, with the cumulative result. Not per-commit.
4. **COO does one comprehensive validation** covering all changes from the session.

This acknowledges that per-deploy triggers are impractical during design marathons while maintaining the quality gate.

## Known Pitfalls

- Announcing "shipped" from git push confirmation (not Vercel deployment)
- Assuming Vercel deploys instantly — build times vary
- Not checking if the deployment target matches (preview vs production)
- Silent fix loops exceeding retry limits — escalate after 3 failed deploys
- In high-tempo mode: forgetting the session-end trigger to COO

## Validation Scenarios

- Scenario 1: CTO pushes to main → polls Vercel → READY in 2 minutes → announces "deployed" → COO validates
- Scenario 2: CTO pushes to main → polls Vercel → ERROR → fixes build, re-pushes → READY → announces (no one knew about the error)
- Scenario 3: CTO pushes to main → polls Vercel → ERROR 3 times → escalates to CoS, does NOT announce
- Scenario 4: CTO does 15 pushes during design marathon → verifies each → sends ONE summary trigger to COO at end → COO validates all changes

## Origin

Captain directive 2026-04-01. Repeated failure: CTO announced features as "shipped" before Vercel deploy was confirmed. High-tempo variant added 2026-04-03 after retro #5 found 30+ deploy session with no COO triggers.
