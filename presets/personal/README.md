# Personal Preset (placeholder)

Empty until Phase 2 of the Cabinet v2 arc populates it (per `cabinet-v2.md`).

## Planned shape

- Coaching agents: Physical Coach, Mindfulness Coach, (more TBD)
- Terminology: "Captain" → "Captain" still; "officer" → "coach"
- Additional schemas: longitudinal_metrics, coaching_narratives, consent_log, coaching_experiments
- Constitution addendum: Coaching Principles (consent, privacy-first, non-directive prompts)
- Default autonomy: consent-gated (lower than work preset)
- Default hooks: privacy redaction + explicit consent checks

## Why it exists empty now

Phase 0 (current) establishes the preset infrastructure. Phase 2 populates this directory with real content when the Captain (or any deployer) is ready to stand up a personal Cabinet alongside their work Cabinet.

Do not populate this directory during Phase 0 work. Do not `echo personal > instance/config/active-preset` — the loader will fail cleanly (preset not populated) but that is Phase 2's payload.
