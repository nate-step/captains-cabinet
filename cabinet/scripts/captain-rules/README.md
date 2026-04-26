# Captain Rules — Retrieval Index

Spec 042 implementation. Replaces always-loaded `captain-patterns.md` +
`captain-intents.md` with on-demand keyword retrieval into the officer's
context window.

## Layout

```
cabinet/scripts/captain-rules/
  index.sh           — builds shared/interfaces/captain-rules-index.yaml
  scaffold-entry.sh  — interactive helper for new <!-- index: --> blocks
  query.sh           — score + return top-N entries for an incoming DM (Phase 2)
  eval.sh            — golden-eval regression harness (Phase 3, pending)
  README.md          — this file
```

The runtime hook lives at `cabinet/scripts/hooks/pre-captain-dm.sh` (UserPromptSubmit) and is wired in `.claude/settings.json`. It reads the incoming user prompt, detects a Captain Telegram DM, calls `query.sh`, and injects the structured block as a `<system-reminder>` via `additionalContext` — landing in the model's tier-1 attention zone for that turn only.

## Authoring a new entry

Every new pattern or intent in `shared/interfaces/captain-patterns.md` /
`captain-intents.md` ships with a paired `<!-- index: ... -->` block.
The block is the source of truth for retrieval — markdown body remains
human-readable but is not parsed.

Run the helper to scaffold:

```bash
bash cabinet/scripts/captain-rules/scaffold-entry.sh > /tmp/block.txt
cat /tmp/block.txt    # paste into the source file directly above your entry body
```

Or hand-write the block directly:

```
<!-- index:
id: A1
section: anchor
title: "Reversibility-gated autonomy"
trigger_words: ["sign-off", "approve", "OK to proceed", "awaiting", "want me to wait", "reversible", "irreversible"]
scope: all_officers
added: 2026-04-26
added_by: cos
excerpt: "Default = SHIP, not GATE. If the action is reversible in <5 min, CoS owns the call. Only gate Captain on genuinely irreversible actions."
-->
```

### Field semantics

| Field            | Required | Notes |
|------------------|----------|-------|
| `id`             | yes      | Short identifier; must be unique across both source files. Convention: `A1..A5` for anchors, `P-...` for patterns, `I-W-...` for intents. |
| `section`        | yes      | One of: `anchor`, `pattern`, `intent`. Controls retrieval behavior — anchors are always returned; patterns/intents are scored. |
| `title`          | yes      | Short imperative phrase. Should match (or summarize) the markdown heading. |
| `trigger_words`  | yes      | YAML list literal of 4-8 lowercase phrases. The floor for keyword retrieval — pick distinctive phrases the Captain would actually use in a DM where this rule should fire. If you cannot enumerate trigger words, the rule is too vague to retrieve. |
| `scope`          | yes      | `all_officers` by default; or a single slug (`cos`, `cto`, ...). The query script bumps score for officer-relevant scope. |
| `added`          | yes      | YYYY-MM-DD (UTC). |
| `added_by`       | yes      | Officer slug (`cos`, `cto`, `cpo`, `cro`, `coo`, ...). |
| `excerpt`        | yes      | One-paragraph distilled rule body — what to do, not the full evidence trail. 1-2 sentences. This is what the officer sees in context; the full rule body + evidence stays in the source file. |

### Anti-patterns

- **Vague trigger words** (e.g., `["help", "do"]`) — they will fire on
  every DM. Pick distinctive phrases.
- **Long excerpts** — the excerpt is the in-context summary, not the
  entry body. If you need 4 sentences, the rule is too compound; split it.
- **Mismatched IDs** — IDs must be unique. The indexer fails fast on
  duplicates.

## Building the index

```bash
bash cabinet/scripts/captain-rules/index.sh
```

Output: `shared/interfaces/captain-rules-index.yaml`. Determinism per
Spec 042 AC #2 — re-running on unchanged input produces byte-identical
output.

A pre-commit hook (`cabinet/scripts/git-hooks/pre-commit`) regenerates
the index when either source file is staged and fails the commit if
the index is out of date.

## Querying the index

```bash
bash cabinet/scripts/captain-rules/query.sh <officer_slug> <dm_text> [<context_hint>]
```

Emits a structured markdown block (or empty if no anchors and no scored hits).
Anchors always present; non-anchors scored by trigger-word substring match
(threshold ≥1, top-5 default). Officer-relevant scope bumps score by 0.5.

Env knobs:
- `INDEX_FILE` — override index path
- `QUERY_TOP_N` — top-N non-anchor entries (default 5)
- `QUERY_THRESHOLD` — minimum score (default 1)

The runtime hook (`cabinet/scripts/hooks/pre-captain-dm.sh`) wraps the query
output in `<system-reminder>` and injects it via Claude Code's
UserPromptSubmit hook → `additionalContext`. 60s identical-DM dedup prevents
reminder fatigue when Captain bursts. Per-officer opt-in via the
`captain_rules_retrieval` capability in `cabinet/officer-capabilities.conf`.

## Rollback

The artifacts are pure files; reversibility is `rm` + revert.

```bash
rm -rf cabinet/scripts/captain-rules/
rm shared/interfaces/captain-rules-index.yaml
rm cabinet/scripts/hooks/pre-captain-dm.sh
# revert .claude/settings.json (drop the UserPromptSubmit entry)
# revert cabinet/scripts/git-hooks/pre-commit (drop the freshness gate)
# revert cabinet/officer-capabilities.conf (drop captain_rules_retrieval lines)
```

Patterns + intents fall back to always-loaded behavior. No DB column
to drop, no schema migration.

## Spec reference

`shared/interfaces/product-specs/042-tool-call-retrievable-patterns-intents.md`.
Phase 1 (this directory's index.sh + retro-fit) ships the indexer + index file.
Phase 2 ships query.sh + the pre-captain-dm hook + the capability flag.
Phase 3 ships eval.sh + the golden-eval fixture set + pre-/post-comparison.
