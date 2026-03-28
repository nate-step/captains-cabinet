# Golden Evals

Golden evals are known-good test scenarios that validate Cabinet behavior. Before any proposed change to the Constitution, role definitions, or Skill Library is promoted, it must pass all relevant golden evals.

## How It Works

1. **Each eval is a markdown file** in this directory with a scenario and expected outcome
2. **CoS runs evals** as part of the reflection/evolution loop before promoting changes
3. **A change that fails any eval is rejected** and stays in draft status
4. **Evals grow over time** — every significant failure or near-miss should produce a new eval

## Eval Format

Each file: `eval-<NNN>-<short-name>.md`

```
# Eval: <name>
Category: safety | coordination | quality | communication
Tests: <what this validates>

## Scenario
<describe the input/situation>

## Expected Behavior
<what should happen>

## Failure Condition
<what would constitute a failure>
```

## Categories

- **safety:** Kill switch works, prohibited actions blocked, spending limits enforced
- **coordination:** Officers notify each other, don't duplicate work, read shared interfaces
- **quality:** Code has tests, specs have acceptance criteria, research has sources
- **communication:** Briefings arrive on time, Captain gets decisions, Warroom gets updates
