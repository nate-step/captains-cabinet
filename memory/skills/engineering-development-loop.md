# Skill: Engineering Development Loop (Evolved)

**Status:** promoted
**Created by:** CTO (evolved from foundation)
**Date:** 2026-04-06
**Validated against:** PRs #402-409 (Captain-approved process)
**Supersedes:** foundation engineering-development-loop.md

## When to Use

Every time CTO ships code — features, fixes, refactors, tests. No exceptions.

## The 7-Step Process (Captain-approved 2026-04-06)

### 1. Crew agent implements on branch
- Spawn Sonnet Crew agent with clear instructions
- Agent creates feature branch from main
- Agent implements the change
- Agent NEVER commits directly to main

### 2. Crew reviewer checks diff — iterative review loop
- Spawn separate Crew agent for code review
- Reviewer checks diff, flags issues
- If issues found: fix → re-review → fix → re-review until clean
- Reviewer sets Layer 1 gate: `redis-cli SET cabinet:layer1:cto:reviewed 1 EX 300`

### 3. Push branch → create PR
- CTO pushes the reviewed branch
- CTO creates PR via GitHub API

### 4. Poll CI until GREEN — iterative fix loop
- Run: `bash verify-deploy.sh ci <commit-sha>`
- If CI fails: investigate → fix → push → poll again
- NEVER merge with failing CI
- Only proceed when CI is green

### 5. Merge PR
- Only after CI green + review approved
- Squash merge

### 6. Verify deploy
- Run: `bash verify-deploy.sh deploy <commit-sha>`
- Poll Vercel deploy status every 15s
- If deploy fails: investigate root cause, fix, push new PR

### 7. Announce + record
- Post to warroom
- Record experience
- Notify CPO if spec-related

## Tools

- `cabinet/scripts/verify-deploy.sh ci <sha>` — pre-merge CI check
- `cabinet/scripts/verify-deploy.sh deploy <sha>` — post-merge deploy check
- `cabinet/scripts/verify-deploy.sh <sha>` — both checks sequentially

## Known Pitfalls

- Merging before CI green wastes time on broken deploys
- Crew agents committing to main bypasses ALL review gates
- Skipping deploy verification means broken code reaches production undetected
- Not recording experiences means the learning loop has nothing to learn from

## Origin

Evolved from foundation skill. Captain directive (2026-04-06): "This process every single time."
