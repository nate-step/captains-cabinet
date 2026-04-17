# Cabinet Framework Backlog

> Maintained by CoS. Framework-level improvements to the Cabinet itself — infrastructure, officer system, meta-features. **Not product features** (those live in Linear) and **not Sensed product backlog** (that lives in `shared/backlog.md`).
>
> GH Issues on nate-step/founders-cabinet are the canonical home for framework items; this file is the Cabinet's local mirror and catches items when `gh` CLI isn't configured inside officer containers.

---

## Paused / blocked

### FW-001 — Auto-provision Telegram bots on new-Cabinet creation
- **Status:** Paused. Blocked on upstream.
- **Problem:** Each new Cabinet (Personal, additional Work, future scaffolds) requires manual BotFather taps per officer. Captain ends up tapping 5-8 times per Cabinet.
- **Desired end state:** `provision-cabinet.sh <preset> <id>` auto-creates all bots and writes tokens to the new Cabinet's `.env`.
- **Blocker:** Telegram Bot API 9.6 (Apr 2026) introduced Managed Bots, but bot *creation* still requires a human tap — no programmatic endpoint. Verified via https://core.telegram.org/bots/api and CRO research 2026-04-17.
- **Watch for:** Bot API changelog entries referencing `createBot` / `provisionBot` / similar. Avoid third-party bot-farm APIs (ToS risk) and MTProto user-bots (different trust model) unless Captain explicitly requests.
- **Revisit trigger:** (a) Bot API release with programmatic creation, OR (b) Captain provisions a 3rd Cabinet and manual tax becomes painful.
- **Owner:** CoS (file), CTO (implement when unblocked)
- **Source:** Captain msg 1447 (2026-04-17) — "file bot creation for later"

---

## In flight

_(none)_

---

## Proposed / awaiting prioritization

### FW-005 — Cross-Cabinet stdio transport is architecturally broken in containers
- **Status:** Proposed (discovered 2026-04-17 smoke-testing Work↔Personal after Captain's provisioning).
- **Problem:** Phase 2 Cabinet MCP designed inter-Cabinet comms as stdio subprocess — spawn the target Cabinet's `server.py` directly from the calling Cabinet. That assumes both Cabinets share a filesystem. In the current containerized deployment each Cabinet runs in its own Docker stack with its own volume mount:
  ```
  /opt/founders-cabinet:/opt/founders-cabinet   # Work's mount only
  ```
  Work's officers cannot see `/opt/founders-cabinet-personal/cabinet/mcp-server/server.py` — the subprocess spawn fails with "no such file or directory." Personal's officers, once provisioned, will have the opposite problem.
- **Three fix options:**
  1. **Dual-mount both containers** (simplest, ~30 min): add `/opt/founders-cabinet-personal:/opt/founders-cabinet-personal` to Work's compose, and `/opt/founders-cabinet:/opt/founders-cabinet` to Personal's compose. Stdio subprocess spawn then works. Containers become aware of each other's filesystems. Trade: containers now share OS-level access to both cabinets, weakening the isolation argument for two-Cabinet setup.
  2. **Phase 3 HTTP transport** (proper): transition inter-Cabinet from stdio to HTTP per `peers.yml`'s `endpoint: http(s)://...` schema. Requires `cabinet/mcp-server/server.py` to expose an HTTP listener (it's already stdio-first but signatures are HTTP-ready) + Docker compose network exposing port for inter-Cabinet + shared_secret_ref bearer auth. ~1-2 days.
  3. **Defer inter-Cabinet comms entirely** (pragmatic): the primary Personal-Cabinet value (separate capacity, separate memory, separate coaching) works WITHOUT cross-Cabinet calls. Cross-Cabinet was a Phase 2 nice-to-have. Leave `consented_by_captain: true` in peers.yml but acknowledge the stdio path fails silently at subprocess spawn. Revisit with Phase 3 HTTP.
- **Recommendation:** Option 3 for today. Personal Cabinet works standalone. File stdio limitation clearly. Option 2 when Phase 3 Federation work begins (and when a concrete use case forces the issue). Option 1 as escape hatch if a use case arrives before Phase 3.
- **Owner:** CoS (decision framework), CTO (implement chosen option)
- **Source:** Smoke-test discovery 2026-04-17 16:25 UTC; msg 1457 Captain confirmed Personal yaml done.

---

### FW-004 — Rename filesystem paths `founders-cabinet` → `captains-cabinet`
- **Status:** Proposed (Captain caught inconsistency 2026-04-17 msg 1455 during Personal Cabinet provisioning).
- **Problem:** Captain Decision 2026-04-16 rebranded the product name "Founder's Cabinet" → "Captain's Cabinet" and renamed the GitHub repo, CLAUDE.md references, and taglines. But filesystem paths — `/opt/founders-cabinet`, `/opt/founders-cabinet-personal`, the Docker volume names, every script's hardcoded path — still carry the old name. When Captain stood up Personal Cabinet today he naturally asked "shouldn't this be captains-cabinet?" — yes, it should, and the inconsistency will confuse every forker who follows the provisioning playbook.
- **Scope of the rename sweep:**
  1. Directory: `/opt/founders-cabinet` → `/opt/captains-cabinet` (+ `-personal` variants)
  2. Docker volume + compose file names
  3. Every hardcoded path in `cabinet/scripts/**/*.sh` (including hooks, record-experience, load-preset, start-officer, notify-officer, reply-to-captain, etc.)
  4. `cabinet/.env` references + any shell rc exports
  5. Docs: `docs/provisioning-personal-cabinet.md`, `README.md`, CLAUDE.md comments
  6. `/home/cabinet/.claude/projects/-opt-founders-cabinet/` project slug (Claude Code auto-generates this from path, so it'll self-update on rename)
  7. `/tmp/cabinet-*` cache files — path-independent, no rename needed
- **Migration plan:**
  1. Announce window (no officer restarts during)
  2. Stop all officer containers
  3. `mv /opt/founders-cabinet /opt/captains-cabinet` (+ `-personal`)
  4. `sed -i 's|/opt/founders-cabinet|/opt/captains-cabinet|g'` across repo
  5. Update Docker compose volumes + restart containers
  6. Smoke test: officer startup, tool calls, inter-officer triggers, Cabinet MCP stdio
  7. Commit + tag as framework migration
- **Risk:** medium — lots of paths, but grep-able and scriptable. Bigger risk is forgetting the `.claude/projects/` slug refresh (auto-regenerates; verify on first session post-rename).
- **When:** coordinate with Captain for a quiet window (no active PR work). Not urgent; cosmetic. Pair with the next framework reorg pass.
- **Owner:** CoS (plan), CTO (execute migration script), COO (validate post-rename)
- **Source:** Captain msg 1455 — "which btw should be captains-cabinet?"

---

### FW-003 — Captain-DM cap adjustment (natural-language → platform.yml edit)
- **Status:** Proposed (Captain-directed 2026-04-17 msg 1453 as follow-on to FW-002).
- **Problem:** FW-002 gives us clean per-cabinet caps in `instance/config/platform.yml`, but raising them still requires host-shell access. A Captain on the road with Telegram-only access can't raise caps for a blocked officer — even though FW-002's whitelist ensures the officer can reach them to ask.
- **Desired pattern:** Captain DMs a whitelisted phrase like "raise cos cap to $200" or "pause captain caps for 24h". CoS parses, validates, edits the receiving Cabinet's `platform.yml`, cache auto-rebuilds (FW-002 mtime watcher), block resolves within one tool call.
- **Design constraints:**
  1. **Whitelisted grammar only.** Free-form LLM interpretation of a cap-change request is too attack-surface-y (a malicious officer that compromised a bot token could forge a raise). Phrase grammar like `raise <officer> cap to $<amount>[ for <duration>]` + `pause cap[ for <officer>][ for <duration>]` + `show caps` covers 90% of use cases and is parseable by a small regex set.
  2. **Captain-only sender.** Verify `from.user_id == captain_telegram_chat_id` before acting. Reject from any other sender with a quiet log (don't echo to group; don't echo to Captain).
  3. **Per-raise audit log.** Every cap mutation writes a line to `shared/interfaces/cap-audit.md` with timestamp + Captain's phrasing + resulting yaml diff. Survives restarts.
  4. **Duration-bound raises auto-revert.** `raise cpo cap to $150 for 24h` sets the value + a Redis TTL key `cabinet:cap-raise:expire:cpo`; a cron at :00 every hour scans for expirations and reverts platform.yml back. Matches spending_limits mental model.
  5. **`/cap-status` DM command.** Captain types `cap status` → CoS replies with current caps + today's per-officer spend table.
- **Owner:** CoS (implement), CTO (code review)
- **Source:** Captain msg 1453 — "So a captain can just reply to expand cap and the cap will be raised?"

---

### FW-002 — Spending-cap enforcement: per-cabinet config + stderr-on-block + Telegram whitelist
- **Status:** Proposed (Captain-directed 2026-04-17 after silent-block incident).
- **Problem:** The `pre-tool-use.sh` hook enforces a flat `$75/officer` + `$300/cabinet-wide` daily cap hardcoded in-script. When the cap bites, the hook exits non-zero **silently** (no stderr), so every tool call for the over-cap officer starts returning `PreToolUse: No stderr output` with zero diagnostic info. A coordinating officer (CoS) hit this first because of trigger-routing overhead, was bricked for ~15 min until Captain manually commented out the block from his host shell.
- **Three fixes required:**
  1. **Per-cabinet override.** Caps read from `instance/config/platform.yml` → `spending_limits.{daily_per_officer, daily_cabinet_wide}`. Captain's own Cabinet sets both to `0` (unlimited / no enforcement). Framework default values remain sane (~$75 / $300) so forkers get a safety net out of the box.
  2. **Stderr-on-block.** When the cap blocks, print a clear one-line reason: `pre-tool-use: BLOCKED — officer=<name> today=$<spent> cap=$<cap> (set spending_limits in platform.yml to override)`. Silent exits are never acceptable from a production hook.
  3. **Telegram whitelist.** Over-cap officer still needs to tell Captain they're stuck. Allow `mcp__plugin_telegram_telegram__{reply, react, send-to-group}` through the cap gate with a 10-msg/hour sub-cap so an over-budget officer can DM "I've hit my cap, need raise/pause" rather than silently brick.
  4. **CoS carve-out.** Coordinating officer always has 3× per-officer cap because trigger routing / inter-officer coordination is structural overhead the other officers don't pay. Values configurable per-Cabinet.
- **Golden eval:** pipe a synthetic JSON (officer=cos, today=$76, cap=$75) into the hook, assert (a) non-zero exit, (b) stderr contains the blocked-reason line, (c) Telegram tools still return 0 exit; repeat with platform.yml cap=0 and assert all tools pass.
- **Owner:** CoS (spec + golden eval), CTO (implement)
- **Source:** Captain direct reply 2026-04-17 15:50 UTC after CoS bricked ~15 min by silent cap; `captain-decisions.md` row same date.
