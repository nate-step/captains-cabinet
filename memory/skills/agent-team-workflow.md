# Skill: Agent Team Workflow

**Status:** promoted
**Created by:** foundation
**Date:** 2026-04-05
**Validated against:** feature implementation, bug fixes, quick patches
**Usage count:** 0

## When to Use

When the CTO needs to make any code changes to the product codebase (`/workspace/product/`). All code changes go through Agent Teams -- never edit product code directly.

## Procedure

**Use Agent Teams, NOT sub-agents.** These are fundamentally different:
- **Sub-agents:** Run within YOUR context, report back to you, can't talk to each other. Uses your token budget.
- **Agent Teams:** Independent sessions with their own context, communicate directly via SendMessage, self-coordinate via shared task list. Preserve your context.

`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is already set in the environment.

### Why Agent Teams
1. **Context management:** Sub-agents and direct editing load content into your context, causing session death. Agent Teams have independent context windows.
2. **Self-coordinating review:** Worker and reviewer teammates iterate directly without going through you. Faster, cleaner.
3. **Parallel execution:** Multiple teammates work simultaneously on different tasks.

### Standard Team Pattern (use this for every feature/fix)

```
TeamCreate: "SEN-XXX: [feature description]"
  - worker (Sonnet 4.6): "Implement [feature]. Files: [list]. Tests: [list]. When done, notify reviewer."
  - reviewer (Sonnet 4.6): "Review worker's output. Check: correctness, tests pass, no regressions. Message worker with issues. Iterate until clean."
```

Worker implements -> reviewer reviews -> worker fixes -> reviewer approves -> you push/merge/deploy.

**You only handle:** reading specs, planning architecture, creating the team, then push -> CI -> merge -> deploy after the team is done.

### For quick fixes (< 5 lines, single file)
Use a single Agent with `isolation: worktree`:
```
Agent tool:
- prompt: "Fix [description] in [file]. Run tests."
- model: sonnet
- isolation: worktree
```

### Team rules
- Use Sonnet 4.6 model for all teammates
- Workers use `isolation: worktree` for code changes
- Define clear scope: which files to touch, which tests must pass
- Include relevant context in team prompt: spec path, captain decisions, prior experience records
- Teammates inherit your boundaries -- they cannot deploy, delete data, or modify infra
- Teammates must record experiences via `record-experience.sh` with tag "crew"
- After team completes, review the output before creating a PR
- **Your role is architect + deployer, not coder.** Plan -> delegate to team -> review -> ship.

## Expected Outcome

Code changes are implemented by Agent Teams with built-in review, preserving CTO context for architecture and deployment decisions.

## Known Pitfalls

- Forgetting to include spec paths and captain decisions in team prompts leads to rework.
- Not defining clear file scope causes teammates to touch unrelated code.
- Skipping the reviewer teammate means bugs slip through to PR.

## Validation Scenarios

- Scenario 1: Feature implementation -> TeamCreate with worker + reviewer, worker implements, reviewer catches issues, iteration produces clean code.
- Scenario 2: Quick fix (< 5 lines) -> Single Agent with worktree isolation, fix applied, tests pass.
- Scenario 3: Multi-file refactor -> TeamCreate with scoped worker prompts per area, reviewer validates cross-file consistency.

## Origin

Extracted from CTO role definition (`/.claude/agents/cto.md`) Agent Teams section. Moved to skill file per framework guidelines that procedural content belongs in skills, not role definitions.
