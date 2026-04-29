# Safety Boundaries — Step Network Preset Addendum

*Loaded by the preset loader on top of `framework/safety-boundaries-base.md` AND `presets/work/safety-addendum.md` patterns. Step Network preset extends the work preset's external-integration list + adds project-specific boundaries.*

---

## Approved External Integrations (Step Network Preset)

Inherits the `work` preset's integration list. Step Network adds:

| Service | Purpose | Officer Access | Notes |
|---------|---------|---------------|-------|
| Monday.com API | Tasks provider for stephie-mcp project + portfolio-tier task management | CTO (write), CPO+CoS (read) | Per-project `tasks_provider: monday` flag in project YAML |
| External political-ad data sources (TBD per politiske-annoncer Captain greenlight) | Data analysis for politiske-annoncer | data-analyst archetype only | Captain-authorized list maintained per project; default deny-by-list |

## Step Network Preset Prohibited Actions

Beyond the framework + work preset prohibitions, Step Network adds:

- **Cross-project data write without explicit handoff.** Officer in project A must NOT write to project B's repo, library spaces, tasks, or env files without an officer-to-officer notify-officer.sh handoff naming the target project explicitly. Pool architecture isolates contexts; officer discipline preserves it.
- **Hard-coded project slugs in hook scripts.** All hooks read `$CABINET_ACTIVE_PROJECT` env (per-tmux-window). Hard-coding (e.g., `if [ "$slug" = "politiske-annoncer" ]`) is forbidden — breaks the pool's per-window context resolution.
- **Skipping per-(officer, project) cost counters.** Stop-hook MUST use `HINCRBY <role>_<project>_cost_micro` (Spec 034 v3 H11/S3 closure). Officers writing alternate cost-counter keys without project dimension corrupt portfolio cost-attribution.
- **Bypassing the active-project queue** (Spec 034 v3 AC #53). If the hook flags a reply target ≠ active project, route to the queue and surface dashboard indicator. Do NOT auto-send across the project boundary.
- **Mixing political-ad data into non-politiske-annoncer projects.** politiske-annoncer scope is regulatory-sensitive (Captain has reserved political-ad data handling for the data-analyst archetype + that project only). Other projects' officers read-only access denied unless Captain ratifies per case.

## Project-Specialized Archetype Safety Notes

- **data-analyst (politiske-annoncer):** sensitive data scope. Dataset writes require Captain ratification per source. No bulk export of political-ad data outside the project's dedicated workspace. Audit log every external API call.
- **mcp-publisher (stephie-mcp):** catalog publish is irreversible-at-public-MCP-registry-level. Captain-gate on first publish per Spec 034 v3 anchor A1; subsequent updates reversible-default per A1. Stage publishes to a private namespace before promoting.

## Pool-Mode Safety

Pool architecture introduces shared-tmux-stack safety surface:

- **Memory pressure threshold** (Spec 034 v3 AC #46): pool RSS ≥80% sustained 5min triggers LRU eviction. Officers should not pin every project window to "active" status in attempts to defeat eviction — pinning is for Captain-current-focus only.
- **Per-window env injection** (Spec 034 v3 AC #28): never override `$CABINET_ACTIVE_PROJECT` from within an officer session. Captain owns project switching via the dashboard or `/switch` slash command.
