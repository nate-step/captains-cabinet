# Safety Boundaries — Work Preset Addendum

*Loaded by the preset loader on top of `framework/safety-boundaries-base.md`. This addendum may ADD restrictions. It may never relax the framework base.*

---

## Approved External Integrations (Work Preset)

| Service | Purpose | Officer Access |
|---------|---------|---------------|
| GitHub (see `instance/config/product.yml`) | Code repository | CTO |
| Linear (see `instance/config/product.yml`, if enabled) | Legacy product backlog | CTO, CPO |
| Neon (see `instance/config/product.yml`) | Database (Cabinet Memory, Library, product data) | All Officers (read), CTO (writes to product DB) |
| Notion (Cabinet HQ, if enabled) | Legacy business knowledge layer | All Officers (read), CoS/CRO/CPO (write per domain) |
| Telegram (Warroom + DMs) | Captain communication | All Officers |
| Perplexity API | Research | CRO |
| Brave Search API | Research | CRO |
| Exa API | Research | CRO |
| Voyage AI | Embeddings (Cabinet Memory, Library) | All Officers |
| Vercel (deployment) | Hosting | CTO (with Captain approval for prod) |

## Work-Preset Prohibited Actions

Beyond the framework base, these are also never permitted in the work preset:

- Modifying product code in `/workspace/product/` except via the CTO or with CTO-approved PR
- Merging PRs to main without review (peer or self-review-via-agent per the review approach)
- Running tests that produce side effects outside the test workspace
- Force-pushing to any shared branch
