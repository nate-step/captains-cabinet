# Sensed Product Backlog — Prioritized View

> Maintained by CPO. Last updated: 2026-04-09 09:06 UTC.
> Captain testing: ACTIVE. All engineering complete. Only Nate founder-action items remain.

---

## Current Phase: Captain Testing + Iteration

### Shipped Today (Apr 7) — 20+ items
- Positioning: "You sensed something. You're not the only one."
- Testimonials: meditation + dream + synchronicity (replaced UAP/historical)
- Journal copy: "or just keep it to yourself as a journal"
- Date picker: "When did this happen?"
- 7-day free trial system (Spec 020) — paywall, downgrade, activation, notifications (73 tests)
- HealthKit State of Mind (Spec 018) — OFIC → Apple Health sync
- Social login Google + Apple (Spec 019)
- Signal editing UI
- In-app review prompt after discovery
- Grounding flow after intense submissions
- Date fuzzing in public views
- Epistemic disclaimers near clusters
- Pricing glassmorphism + table alignment
- /signal category card glassmorphism
- PillHeader transparency + rounded corners
- Footer consistency on /terms + /privacy
- Legal page dates → April 2, 2026
- Pricing nav link + button width
- A11Y quick wins (15 fixes)
- Brand voice error messages
- Sitemap all 17 categories + slug fixes
- OG images (homepage, /signal, /pricing, categories)
- JSON-LD structured data
- SEO descriptions for all categories

### Nate Action Items (founder-action label in Linear)
- SEN-506: Google OAuth credentials (~15 min)
- SEN-507: Apple Sign In config (~20 min)
- SEN-508: TestFlight upload via Transporter (~30 min)
- SEN-509: Create IAP products in App Store Connect (~30 min)
- SEN-510: Enter SDK privacy labels (~20 min)
- SEN-514: Configure 7-day trial introductory offer (~10 min)

### Shipped Today (Apr 7 cont.) — CPO-initiated + Captain testing
- SEN-516: Trial activation prompts wired (PR #489) — P1, was dead code
- SEN-478: Analytics instrumentation — 12 events (PR #490)
- SEN-517: Web post-submission discovery moment (PR #492)
- SEN-518: Signal quota visibility — progress bar + Sensed+ nudge (PR #493)
- SEN-521: P0 cron route fix + UMAP batch recompute (PR #495)
- SEN-520: iPhone SE responsive overflow fix (PR #497)
- SEN-522: Duplicate title suffix fix (PR #500-501)
- Pricing glassmorphism root cause: will-change-transform + filter:blur(0px) (PRs #496-498)
- Header nav: logo only, no text wrapping (PR #499)
- Filter removal from stagger animations (PR #502)

### Shipped Apr 8-9
- SEN-523: Name removed from registration — email + password only
- GlassCard: Reusable frosted glass component (consistent across all pages)
- SEN-493: Apple reviewer seed account script
- Category buttons glass blur fix (animation-fill-mode barrier)
- Pricing animation keyframes fix (filter:blur removed)
- Hourly health check cron with Telegram alerting

### Post-Launch Activation
| Item | Priority | Linear |
|------|----------|--------|
| Daily engagement hook (constellation grows) | Low | SEN-519 |

### Post-Launch Backlog
| Item | Priority | Linear |
|------|----------|--------|
| Echo chamber mitigation | Medium | SEN-511 |
| Dynamic cluster naming | Low | SEN-512 |
| Earth Map Strava-model locations | Medium | SEN-513 |
| Inner Map Phase 2A: nebula | Medium | SEN-376 |

---

## Captain Decisions (key — updated Apr 7)
- Launch quality-gated, not date-gated
- Positioning: "You sensed something. You're not the only one." (changed from "So did they")
- Founding member: 5000 spots, wave-based (500/wave), $4.99/mo
- 7-day free trial: card required (Apple mandate), genuine free tier fallback
- AI invisible in user-facing copy
- Real data only — zero fake claims
- Reddit day 1: Apr 6, 2026
- Dual dates + dual locations: Phase 2
- No lawyer budget — compliance internal
- Notion strategic docs: real-time sync by CPO
