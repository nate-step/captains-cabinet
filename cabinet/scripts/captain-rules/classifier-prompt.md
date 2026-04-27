# Captain-rule classifier prompt template (Spec 048 v2 AC #5)

Pinned at `cabinet/scripts/captain-rules/classifier-prompt.md` to prevent
drift. Loaded at runtime by `cabinet/scripts/captain-rules/classify-rule.sh`
and sent to Sonnet alongside the rule body for operationalizable-vs-values-only
classification + trigger-signal extraction.

---

You are classifying a Captain-encoded behavioral rule for the cabinet's
4th-loop pattern encoder. The rule has just been written to either
`captain-patterns.md` or `captain-intents.md` based on a "remember /
always / never / encode" signal in a Captain DM.

Your job: decide whether this rule is **operationalizable** (has detectable
trigger phrases or actions an automated hook could match) or **values-only**
(a principle without a clean trigger surface).

**Operationalizable examples**
- "no IDs in Captain replies" → trigger phrases: "PR #", "Spec ", "FW-", "msg ", "commit "
- "always set due_at on coach tasks" → trigger action: officer_tasks INSERT/UPDATE without due_at
- "build-our-own over deps" → trigger: `npm install`, `pip install`, etc.
- "no timezone abbreviations adjacent to time" → trigger: regex `\d{1,2}:\d{2}\s*(UTC|CET|CEST|...)`

**Values-only examples**
- "be honest about uncertainty" — no clean trigger
- "respect Captain's time" — no clean trigger
- "trust the model with the principle" — meta-rule, not enforceable
- "think holistically" — abstract

**Anti-over-hooking floor (AC #4)**
If you can extract fewer than 3 distinctive trigger phrases (each ≥4 chars,
each meaningfully different from the others), classify as **values-only**.
A hook with 1-2 vague triggers fires on every reply and pollutes the warn
surface. Better to leave the rule as memory-only.

**Confidence calibration**
- 0.9-1.0: rule has 5+ distinctive triggers AND clear action surface (Bash command, Telegram reply text, file edit path).
- 0.7-0.9: rule has 3-4 distinctive triggers AND a clear surface.
- 0.5-0.7: borderline — triggers exist but are common words OR surface is fuzzy.
- <0.5: values-only territory.

The cabinet's runtime threshold for auto-drafting a hook is **confidence ≥ 0.7**.
Below that, the entry stays memory-only with a "candidate-for-hook" tag for
periodic CoS retro re-evaluation.

**Output format (strict JSON, no chit-chat)**
```json
{
  "class": "operationalizable" | "values-only",
  "trigger_signals": ["phrase 1", "phrase 2", ...],
  "trigger_surface": "Bash" | "Reply" | "Write" | "Edit" | "UserPromptSubmit" | null,
  "confidence": 0.0,
  "reasoning": "<one short sentence on why>"
}
```

If `class == "values-only"`, return `trigger_signals: []` and
`trigger_surface: null`.

**Rule input format**
You will be given the rule body (the new entry text from
captain-patterns.md / captain-intents.md). Read it, decide, return JSON.

Return ONLY the JSON object. No preamble. No markdown fences.
