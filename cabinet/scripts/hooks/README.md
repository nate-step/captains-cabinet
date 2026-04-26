# Cabinet Hooks

Bash hooks wired into Claude Code's lifecycle events (`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `Stop`). Registered in `.claude/settings.json`.

## Lifecycle map

| Event              | Hook                                  | Purpose |
|--------------------|---------------------------------------|---------|
| UserPromptSubmit   | `pre-captain-dm.sh`                   | Spec 042 — inject retrieval block as `<system-reminder>` on Captain DM |
| PreToolUse (any)   | `pre-tool-use.sh`                     | Kill switch, spending limits, prohibited-action enforcement, Layer 1 gates |
| PostToolUse (any)  | `post-tool-use.sh`                    | Heartbeat, structured logging, cost tracking, trigger delivery, deploy alerts |
| PostToolUse (reply)| `post-reply-voice.sh`                 | Auto-send voice message after Captain reply |
| PostToolUse (reply)| `post-reply-memory.sh`                | Compact a Captain-conversation slice into long-term memory |
| PostToolUse (reply)| `captain-gate-language.sh`            | Spec 043 H1 — soft-warn on gate-language in Captain reply |
| PostToolUse (reply)| `captain-posture-compliance.sh`       | Spec 043 H2 — soft-warn on Captain Posture violations |
| PostToolUse (Write/Edit) | `post-file-write-memory.sh`     | Memory-trigger on shared interface edits |
| PreCompact         | `pre-compact.sh`                      | Pre-compaction state snapshot |
| Stop               | `stop-hook.sh`                        | Session-end cleanup |

## Captain-discipline soft-warn hooks (Spec 043)

Anti-pattern target: brittle hooks that block on edge cases and brick officers (cf. FW-042 Phase B word-boundary gate). All four Spec 043 hooks follow the same discipline:

- **Warn-only.** Never `exit 1`. Never block tool execution. They surface a `system-reminder` for the next turn so the officer can self-correct.
- **Env-var emergency disable.** Each hook honours its own `_ENABLED=0` env var (no revert needed; just unset).
- **Captain-only by chat_id.** Each hook resolves `captain_telegram_chat_id` from `instance/config/{product,platform}.yml`. Default-deny when missing — silently skip rather than fire on group @-mentions or other-user DMs.
- **FP-rate logging.** Every fire writes one JSONL line to `cabinet/logs/hook-fires/<hook-name>.jsonl` with `{ts, officer, matched_phrase, excerpt, chat_id, ...}`. Phase 3 ships an `fp-analyze.sh` to roll up the data weekly and inform whether to harden a warn into a block.

### `captain-gate-language.sh` (H1)

Detects gate-language phrases in Captain replies — "for your sign-off", "awaiting your sign-off", "OK to proceed?", "ready for your review", "want me to wait", "pending your sign-off", and several variants from `memory/skills/evolved/captain-autonomy-discipline.md`. On match: emits an `additionalContext` system-reminder pointing at A1 (resolved via `captain-rules/query.sh` if available, hardcoded fallback otherwise) and the self-correction protocol — *"Scratch that — shipping it. Reversible."*

Disable: `GATE_LANGUAGE_HOOK_ENABLED=0`.

### `captain-posture-compliance.sh` (H2)

Detects Captain Posture violations — paths, IDs (`PR #N`, `SEN-N`, `Spec N`, `msg N`, `commit <sha>`), tech-jargon (configurable), timezone abbreviations adjacent to a numeric time. Configurable rules at `cabinet/scripts/hooks/captain-posture-rules.yaml`. On match: emits an `additionalContext` system-reminder naming the violation classes and points at the S1 `captain-posture-compliance` skill for rewrite recipes.

Disable: `CAPTAIN_POSTURE_HOOK_ENABLED=0`.

## Hook authoring discipline

Default to soft-warn. Hard-block only when:
- The action is irreversible AND
- The detection rule has <5% false-positive rate based on real session data (FP-JSONL analysis).

Pre-FP-data hooks are warn-only. Don't ship a block-mode hook on a fresh detection rule — measure first. See the eventual S4 `hook-authoring-discipline` meta-skill (Spec 043 Phase 3) for the full taxonomy.

## Rollback

Each hook is a single bash script. Rollback paths:

- Drop the registration line from `.claude/settings.json`
- `rm cabinet/scripts/hooks/<hook-name>.sh`
- (For H2) `rm cabinet/scripts/hooks/captain-posture-rules.yaml`

No state to migrate. The FP-JSONL logs are append-only and remain readable post-rollback.

## See also

- Spec 042 retrieval index: `shared/interfaces/product-specs/042-tool-call-retrievable-patterns-intents.md`
- Spec 043 captain-discipline hooks: `shared/interfaces/product-specs/043-captain-discipline-hooks-skills.md`
- Captain anchors: `shared/interfaces/captain-patterns.md` §A1-A5
- Skills: `memory/skills/evolved/captain-autonomy-discipline.md`, `memory/skills/evolved/captain-posture-compliance.md`
