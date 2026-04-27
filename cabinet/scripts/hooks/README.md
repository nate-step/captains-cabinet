# Cabinet Hooks

Bash hooks wired into Claude Code's lifecycle events (`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `Stop`). Registered in `.claude/settings.json`.

## Lifecycle map

| Event              | Hook                                  | Purpose |
|--------------------|---------------------------------------|---------|
| UserPromptSubmit   | `pre-captain-dm.sh`                   | Spec 042 — inject retrieval block as `<system-reminder>` on Captain DM. Spec 046 — when DM carries a voice attachment, transcribe via Telegram Bot API + ElevenLabs Scribe, cache by message_id at `cabinet/cache/voice-transcripts/<id>.txt` (24h TTL), inject transcript before retrieval. Disable: `VOICE_TRANSCRIBE_HOOK_ENABLED=0`. |
| PreToolUse (any)   | `pre-tool-use.sh`                     | Kill switch, spending limits, prohibited-action enforcement, Layer 1 gates |
| PostToolUse (any)  | `post-tool-use.sh`                    | Heartbeat, structured logging, cost tracking, trigger delivery, deploy alerts |
| PostToolUse (reply)| `post-reply-voice.sh`                 | Auto-send voice message after Captain reply |
| PostToolUse (reply)| `post-reply-memory.sh`                | Compact a Captain-conversation slice into long-term memory |
| PostToolUse (reply)| `captain-gate-language.sh`            | Spec 043 H1 — soft-warn on gate-language in Captain reply |
| PostToolUse (reply)| `captain-posture-compliance.sh`       | Spec 043 H2 — soft-warn on Captain Posture violations |
| PreToolUse (Bash)  | `build-vs-buy-precheck.sh`            | Spec 043 H4 — soft-warn on dependency install (npm/pip/cargo/etc.) |
| PostToolUse (Write/Edit) | `post-file-write-memory.sh`     | Memory-trigger on shared interface edits |
| PostToolUse (Write/Edit) | `personal-work-parity.sh`       | Spec 043 H3 — soft-warn on Work-tree shared-infra edit without recent Personal counterpart |
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

### `personal-work-parity.sh` (H3)

Detects Work-tree edits to shared-infra paths (`cabinet/sql/*`, `cabinet/scripts/*`, `framework/*`, `presets/*`, `memory/skills/*`) without a corresponding Personal-tree edit within 5 minutes. Per-officer tracker file `/tmp/.cabinet-parity-tracker-<officer>` records edits per tree. On match: emits a system-reminder with the canonical Personal-side counterpart path and pointer to the S2 `personal-work-parity-checklist` skill.

Disable: `PARITY_HOOK_ENABLED=0`.

### `build-vs-buy-precheck.sh` (H4)

Detects dependency install commands as PreToolUse on Bash — `npm install`, `npm i`, `yarn add`, `pnpm add/install`, `pip install`, `pip3 install`, `cargo add`, `gem install`, `composer require`, `go get`, `bundle add`, `poetry add`, `brew install`. Captures scoped packages (`@scope/pkg`). On match: emits a system-reminder with the package name, A3 reference, and pointer to the S3 `build-vs-buy-quickdraw` skill for the 90-second decision template.

The install command still proceeds (warn-only). The cue is the forcing function for the 90-second pause.

Disable: `BUILD_VS_BUY_HOOK_ENABLED=0`.

## Hook authoring discipline

Default to soft-warn. Hard-block only when:
- The action is irreversible AND
- The detection rule has <5% false-positive rate based on real session data (FP-JSONL analysis).

Pre-FP-data hooks are warn-only. Don't ship a block-mode hook on a fresh detection rule — measure first.

The full taxonomy lives in the **`hook-authoring-discipline`** meta-skill at `memory/skills/evolved/hook-authoring-discipline.md` (Spec 043 S4). It enumerates:
- The default soft-warn shape (template)
- The four conditions that earn hard-block status
- FP-rate measurement methodology
- The FW-042 anti-pattern as canonical regression
- Authoring checklist

## FP-data analysis

Each soft-warn hook writes one JSONL line per fire to `cabinet/logs/hook-fires/<hook-name>.jsonl`. Roll up weekly via:

```bash
bash cabinet/scripts/hooks/fp-analyze.sh                                  # last 7 days, all hooks
bash cabinet/scripts/hooks/fp-analyze.sh --days 30
bash cabinet/scripts/hooks/fp-analyze.sh --hook captain-gate-language
bash cabinet/scripts/hooks/fp-analyze.sh --officer cto
bash cabinet/scripts/hooks/fp-analyze.sh --json                           # JSON for scripting
```

Reports per-hook + per-officer fire counts, top matched phrases, captain-posture violation classes, daily fire-rate trend, and harden-or-not heuristic signals. Final harden decisions need labeled FP-rate data (manual review of session transcripts) — fp-analyze.sh is the surface, not the verdict.

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
- Skills: `memory/skills/evolved/captain-autonomy-discipline.md`, `memory/skills/evolved/captain-posture-compliance.md`, `memory/skills/evolved/personal-work-parity-checklist.md`, `memory/skills/evolved/build-vs-buy-quickdraw.md`, `memory/skills/evolved/hook-authoring-discipline.md`
