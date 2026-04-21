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

### FW-005 — Inter-Cabinet HTTP transport (Phase 2 completion) ✓ SHIPPED
- **Status:** DONE — PR #25 merged 2026-04-17 17:17 UTC (sha 7f3f09b6). HTTP transport live alongside stdio; 691 LOC / 5 files, 20/20 smoke tests, 2 Opus-reviewer fixes pre-commit (ThreadingHTTPServer + OSError catch).
- **Was:** Phase 2 stdio subprocess assumed shared filesystem; containerized deployments break that. Captain caught the phase-conflation in my first framing ("inter-Cabinet is Phase 2, Federation is Phase 3"): fixing this is Phase 2 completion, not Phase 3.
- **Shipped pattern:** set `CABINET_MCP_TRANSPORT=http` + `CABINET_MCP_HTTP_PORT=7471` + configure `shared_secret_ref` in peers.yml per Cabinet. Peer's `.env` holds the referenced secret. Peers.yml endpoint format: `http://<host>:<port>/mcp`. Stdio still available for local-only setups.
- **Deferred tech-debt (CTO):** mtime-cache for peers.yml disk reads (parsed on every hook invocation; low-traffic today, optimize when it matters).
- **Phase 3 downstream:** federation adds captain_id + external flag + cryptographic auth + bidirectional consent handshake on top of this transport. No schema conflict — the `endpoint: http(s)://...` field already accommodates external hosts.
- **Source:** Smoke-test discovery 2026-04-17 16:25 UTC (Work container couldn't see `/opt/founders-cabinet-personal/` mount); Captain phasing correction msg 1459; CTO merge 17:17 UTC.

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

---

### FW-019 — Checkpoint-review pre-commit hook ✓ SHIPPED
- **Status:** DONE — commit 84632d1 on master 2026-04-19. `cabinet/scripts/git-hooks/pre-commit` gates commits >300 LOC without a review artifact; `cabinet/scripts/install-git-hooks.sh` activates for forkers. Golden eval 9/9 pass. Skill at `memory/skills/evolved/checkpoint-review.md`.
- **Source:** Captain msgs 1531+1532+1535 — checkpoint-based review during build not end-of-build, enforced via hook not skill, eat-our-own-dog-food starting with Phase A.
- **Framework impact:** every Cabinet fork that runs install-git-hooks.sh once post-clone inherits the gate. Applies to all officers + Crew agents equally.
- **Override:** `COMMIT_NO_REVIEW=1` env var for docs-only / trivial fixes.
- **Dogfooded:** FW-019 commit itself (318 LOC) passed through with self-review at `shared/interfaces/reviews/master-fw-019-cp1.md`.

---

### FW-018 — Host-agent + admin bot (CoS gets operator-level access; Captain gets dead-man switch)
- **Status:** Spec drafted (Spec 035), Captain approved direction 2026-04-19, routed to CoO adversary + CRO pressure-test, CTO after that.
- **Problem:** Officers run in Docker containers with no path to the host. Every container-boundary-crossing op (rebuild dashboard, restart a wedged officer, edit .env, docker compose up) currently falls to Captain's manual shell work. Non-tech captains shouldn't have to ever touch a terminal.
- **Solution:** Host-agent daemon on host (root, Unix socket, peer-cred auth); host MCP exposed only to CoS; append-only audit log; Captain-only admin bot running on host OUTSIDE the Cabinet failure domain (four cmds: pause/restart/rollback/show-recent); dangerous-pattern watcher pushes Telegram alerts on rm -rf / or similar; GitOps auto-rebuild on master push. CoS gets operator-level access; other officers route through CoS.
- **Trust model:** CoS = operator with privilege. Safety is audit log + alerts + dead-man switch, not privilege allowlist.
- **Spec:** `shared/interfaces/product-specs/035-host-agent-admin-bot.md` v1.
- **Review chain:** CoO adversary → CRO pressure-test → CTO tech-review → Captain ack of Q1–Q4 → CTO Phase A implementation.
- **Effort estimate:** ~2 days CTO + 1 day CoS golden eval. ~1100 LOC.
- **Bundles:** a secondary fix to pre-tool-use.sh Section 3 (prohibited-actions) — make it platform.yml-configurable and propagate FW-002 stderr-on-block fix to remaining 22 exit-2 paths. Without this, host MCP calls would be blocked by the existing hardcoded substring match on "docker|systemctl|sudo".
- **One-time Captain cost:** BotFather tap for the admin bot (FW-001 upstream-blocker still unresolved; no programmatic bot creation from Telegram).
- **Owner:** CoS (spec + golden eval), CTO (implement).
- **Source:** Captain msg 1513+1515+1516 (2026-04-19) — "How can you get access to host... access to everything would make it frictionless... restart and reset switch somewhere in case you mess up and become unresponsive."

---

### FW-007 — Force-push refusal pre-push hook on master (shared-tree safety)
- **Status:** Proposed (retro 2026-04-19 P-008).
- **Problem:** On 2026-04-17, CTO ran `git reset --hard origin/master` in the shared working tree, wiping 4 unpushed CoS commits (FW-002, FW-002.1, FW-004, FW-005, constitution rules). CoS re-applied, but the structural hazard remains: any officer in the shared tree can destroy another officer's unpushed work with one command. Also captured in `feedback_git_staging_shared_tree.md` but that's vigilance, not a gate.
- **Desired end state:** `.git/hooks/pre-push` refuses `git push --force` (and `--force-with-lease`) to `master` unless an env var + announcement exists. Something like: require `FORCE_PUSH_ANNOUNCED=<ISO-timestamp-within-5min>` AND a matching line in a shared log `shared/interfaces/force-push-log.md`. Without both, hook exits non-zero with clear stderr.
- **Also cover:** `git reset --hard` in the working tree — harder to gate (no pre-reset hook), but we can:
  - Add a wrapper `git-reset-hard` in PATH that verifies no uncommitted work across any officer's uncommitted-changes marker (Redis key `cabinet:uncommitted:<officer>`), refusing if any marker present
  - Each officer's pre-tool-use hook writes `cabinet:uncommitted:<officer>` marker when it detects `git add` or `git commit` to local-only ref; clears on push
- **Owner:** CTO implement, CoS golden-eval.
- **Risk:** false-positive refusing legitimate `--force-with-lease` after a rebase. Mitigation: `--force-with-lease` still refuses, but the announcement requirement is one-command (`echo "rebase push $(date -u +%FT%TZ) <reason>" >> shared/interfaces/force-push-log.md && FORCE_PUSH_ANNOUNCED=$(date -u +%FT%TZ) git push --force-with-lease`).
- **Source:** CTO session 2026-04-17; CoS retro 2026-04-19 P-008.

---

### FW-020 — Library MCP Python adapter (replace Spec 039 JSONL-on-disk archive)
- **Status:** Proposed (deferred from Spec 039 PR-3 scope, 2026-04-21).
- **Problem:** Spec 039 archive strategy (§7.4) originally targeted Library MCP for Linear + GH snapshots. PR-3 shipped a JSONL-on-disk fallback at `instance/archive/039-migration-snapshots/` because the Library MCP is TypeScript-only; Python ETL can't call it. On-disk JSONL works but: (a) fragmented from other archives (briefs, specs) that DO live in Library, (b) no full-text search, (c) manual cleanup when wet-run superseded by Gate 4 prod cutover.
- **Desired end state:** Python shim (`cabinet/scripts/lib/library-mcp-client.py`) that speaks the same MCP stdio protocol as the TS client. ETL `archive_to_library` calls `library.create_record(space='etl-snapshots', body=...)` instead of writing JSONL. Existing on-disk snapshots migrate via one-time backfill script.
- **Out of scope:** Replacing the Library MCP entirely. Keep TS server; add Python client.
- **Effort:** ~1 day CTO. Small surface (stdio JSON-RPC, 3-4 methods needed).
- **Owner:** CTO.
- **Source:** Spec 039 PR-3 ship debrief 2026-04-21 — L-1 carve-out in runbook §1.2 flagged JSONL as interim.

---

### FW-021 — Gate-3 idempotency hash-basis drift fixture test
- **Status:** Proposed (2026-04-21 PR-3 lesson-learned).
- **Problem:** `cabinet/scripts/gates/gate-3-idempotency.py` hand-codes the 15-col hash basis per Spec 039 §5.9 M-5. Adversary review caught initial divergence (missing cols, wrong algorithm) that would have silently passed idempotency on mutated rows. No test fixture asserts Python hash output equals Postgres `md5(concat_ws('|', …))` on a known row.
- **Desired end state:** `cabinet/scripts/gates/tests/test_gate_3_hash.py` — pytest-style: insert a canned officer_tasks row, compute Python hash + Postgres hash, assert equal. Run in CI (when CI lands) or as pre-PR check.
- **Guard scope:** Any future addition to `_HASH_COLS` requires spec amendment (already in module docstring) AND test-fixture update. The two in lockstep catches drift.
- **Effort:** ~2 hr (fixture row + pytest scaffold).
- **Owner:** CTO.
- **Source:** Spec 039 PR-3 adversary B-1 finding; folded into FW backlog for post-wet-run work.

---

### FW-022 — Pre-tool-use hook CI green gate stderr routing
- **Status:** Proposed (2026-04-21 re-validated during PR-3 self-merge).
- **Problem:** `cabinet/scripts/hooks/pre-tool-use.sh` lines 369-381 block `curl .../pulls/[0-9]+/merge` until `cabinet:layer1:cto:ci-green` Redis key is set. The hook echoes instructions to stdout, not stderr. Claude Code's hook engine treats stdout as tool-stdout (not operator-visible on block) — manifests as silent "No stderr output" rejection. Per memory `feedback_silent_hook_exits.md`, this was supposed to be fixed in FW-002 for all 22 exit-2 paths; the CI green gate path still stdout-echoes.
- **Desired end state:** All hook rejection paths use stderr so operators see the required action. Pattern: `>&2 echo "BLOCKED: <reason>. Run <fix>."; exit 2`. Audit the whole hook for stdout→stderr migration; bundle with FW-018 pre-tool-use Section 3 changes.
- **Also:** Consider a `.claude/hook-help.txt` pointer the engine surfaces automatically on exit 2 instead of shell-level echoes.
- **Effort:** ~1 hr audit + diff.
- **Owner:** CTO.
- **Source:** PR-3 merge attempt 2026-04-21; same-day re-encounter of the hook-silence pattern.

---

### FW-023 — Spec 039 test-fixture coverage expansion
- **Status:** Proposed (deferred from PR-3, 2026-04-21 per COO observation).
- **Problem:** `cabinet/scripts/lib/test_etl_fixtures.py` shipped 8 fixtures covering representative paths (LINEAR queue/wip/done/cancelled, epic synthesis, GH FW-marked + closed + no-marker). Non-blocking gaps flagged by COO: (a) no GH fixture with `state_reason='not_planned'` to validate AC #52 (closed-not-planned → cancelled) end-to-end, (b) no `captain_decision=TRUE` fixture (Linear label-based flag).
- **Desired end state:** 2 additional fixtures added + corresponding asserts in test_etl.py (once test harness lands — currently no pytest setup exists in repo; fixture file is type-only for now).
- **Coupled to:** Standing up pytest in cabinet/scripts/lib/tests/ — larger hygiene work. FW-021 overlaps.
- **Effort:** 30 min for fixtures; ~half day for pytest harness.
- **Owner:** CTO.
- **Source:** COO PR-3 code-review 2026-04-21 15:26 UTC — flagged non-blocking, cleared for self-merge with deferral understood.

---

### FW-016 — Delete byte-count cost-write path in post-tool-use.sh (partially-applied fix)
- **Status:** Proposed (discovered 2026-04-17 23:00 UTC by CTO).
- **Problem:** A prior session's summary claimed the byte-count cost-tracking path was removed from `post-tool-use.sh`, but git log shows no such commit. Lines 66-88 still write `COST_CENTS = wc -c-derived garbage` to three legacy keys:
  - `cabinet:cost:daily:$DATE` (plain integer via INCRBY)
  - `cabinet:cost:officer:$OFFICER:$DATE`
  - `cabinet:cost:monthly:$MONTH`
- **Actual state:** `pre-tool-use.sh` was correctly switched to read from `cabinet:cost:tokens:daily:$DATE` HSET (stop-hook writes real costs there). So the spending-cap gate is safe. But:
  - `cost-dashboard.sh`, `dashboard/src/lib/redis.ts`, `test-escalation.sh`, and `run-golden-evals.sh` all still read from the legacy keys → display/test values are ~3.44x under-reality
  - `HGETALL cabinet:cost:daily:$TODAY` returns `WRONGTYPE` because the key is a plain integer (from INCRBY), not a hash
- **Fix:**
  1. Delete lines 66-88 of `cabinet/scripts/hooks/post-tool-use.sh` (the whole "COST TRACKING (rough estimate)" block). Keep the activity-string block below it intact.
  2. Update `cost-dashboard.sh` + `dashboard/src/lib/redis.ts` to read from `cabinet:cost:tokens:daily:$DATE` HSET and sum `officer_cost_micro` fields (divide by 10000 to get cents).
  3. Update `test-escalation.sh` and `run-golden-evals.sh` to write/read HSET format.
  4. Verify no other consumer reads the legacy keys after removal.
- **Golden eval:** after fix, `HGETALL cabinet:cost:tokens:daily:$DATE` returns real values; legacy keys return nil; dashboard daily total matches `SUM(*_cost_micro) / 10000 / 100 = $X`.
- **Owner:** CTO (implement, small diff, ~40 LOC across 4 files). Safe to self-merge per Captain meta-rule if CoS pre-acks.
- **Source:** CTO session 2026-04-17 23:00 UTC, observed `WRONGTYPE` on HGETALL + grep for `cabinet:cost:daily` showed live write path still active.
