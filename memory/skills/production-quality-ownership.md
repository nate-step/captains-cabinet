---
title: Production Quality Ownership
status: foundation
applies_to: all officers
---

# Production Quality Ownership

You own not just shipping the work, but shipping it WELL. Before declaring any significant work done — not just before committing code, but before any meaningful change — run this checklist.

## The Six Questions (Craftsman Lens)

Ask these in order. Stop and fix before proceeding if any answer is "no" or "I don't know."

### 1. REDUNDANCY
Did I create anything that duplicates or supersedes existing code/docs/configs?
- Is there an older version that should now be deleted?
- Does this replace a cron job, script, or file that's now obsolete?
- Are there two ways to do the same thing?

If yes: delete the obsolete version in the same commit.

### 2. CONSISTENCY
Are ALL references to what I changed updated?
- grep for the old name/path/concept
- Update docs, configs, agent definitions, CLAUDE.md, comments
- Check the role registry, captain-decisions, tech-radar if relevant

If you changed it in one place but not others, you've shipped drift, not a feature.

### 3. CLEANUP
Did I leave debris?
- Commented-out code I meant to remove
- Test files, scratch scripts, temp directories
- Outdated comments that describe the OLD behavior
- Dead imports, unused variables, stale TODOs

Debris accumulates. Each piece seems small; together they rot the codebase.

### 4. UNIVERSALITY
Does this fit the framework for any founder, or just our setup?
- Officer-agnostic: no hardcoded names, uses capabilities
- Configurable: anything founder-specific goes in config, not code
- Implementation-agnostic: the guide describes concepts, not mechanisms

If you made something that only works for Sensed's officer set, flag it.

### 5. COMPLETENESS
Did I finish, or is there hanging work I parked mentally?
- Are there TODOs I glossed over?
- Does the user-facing result match what I said I'd deliver?
- Are there edge cases I shrugged at ("probably fine")?

Hanging work becomes forgotten debt. Surface it explicitly before moving on.

### 6. CRAFTSMANSHIP
Would I be embarrassed for another founder to see this?
- Is the code readable? Would a stranger understand it in 30 seconds?
- Are commit messages explanatory?
- Does the design choose clarity over cleverness?
- If this ships to the public cabinet framework — is it something you'd point at with pride?

This is the hardest question. If you hesitate, refine.

## When to Run the Checklist

Run it before declaring done on:
- Any commit touching hooks, CLAUDE.md, agent definitions, or core scripts
- Any new script, skill, or config file
- Any significant refactor
- End of a multi-step task

For trivial changes (typo fix, one-line log adjustment): skip.

## How to Run It

Three modes:

**Self-audit** (minimum): read the 6 questions, honestly answer each. Fix gaps.

**Spawned audit** (recommended for infrastructure work): spawn a Sonnet agent with "audit my recent work against `memory/skills/production-quality-ownership.md`." Review findings, fix, commit.

**Peer audit** (for major releases): request review from a capability-appropriate peer officer via notify-officer.sh.

## Why This Matters

The review-before-commit pattern catches BUGS. This checklist catches CRAFTSMANSHIP FAILURES — work that's correct but messy, complete but redundant, shipped but inconsistent. A cabinet that accumulates craftsmanship failures becomes unshippable as a public framework, even if every individual piece works.

## When a Fix Requires Captain Approval

Sometimes the audit surfaces something you can't autonomously fix:
- Removing an officer that turns out to be redundant (structural change — needs approval)
- Changing a Captain Decision that's now contradicted (decisions are canonical — surface the conflict)
- Modifying constitution files (read-only — propose through improvement loop)

In these cases: document the finding in your reflection, notify the coordinating officer, surface to the Captain. Do not silently ship half-fixes.

## Relationship to Other Quality Skills

Complementary, not redundant:
- **quality-pyramid.md** = verification mechanics (pre-push, PR review, post-deploy validation, periodic audits) for product code
- **this skill** = craftsmanship lens (6-question checklist for any work, not just product code)

Run both where applicable. This skill asks "is the work CLEAN?" while quality-pyramid asks "is the work VERIFIED?"

## Anti-Patterns

- Declaring "done" because the work runs without errors
- Cleaning up "later" (later doesn't come)
- Committing redundancy because deleting feels risky
- Assuming docs will catch up organically
- Treating quality as the Captain's responsibility to notice
