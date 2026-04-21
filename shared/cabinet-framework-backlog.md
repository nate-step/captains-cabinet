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
- **Status:** DONE 2026-04-21 — push-side gate shipped. Reset-hard wrapper parked as follow-up.
- **Problem:** On 2026-04-17, CTO ran `git reset --hard origin/master` in the shared working tree, wiping 4 unpushed CoS commits (FW-002, FW-002.1, FW-004, FW-005, constitution rules). CoS re-applied, but the structural hazard remains: any officer in the shared tree can destroy another officer's unpushed work with one command. Also captured in `feedback_git_staging_shared_tree.md` but that's vigilance, not a gate.
- **Fix shipped (push half):**
  - `cabinet/scripts/git-hooks/pre-push` (new, ~135 LOC). Blocks any push to `refs/heads/master` where `remote_sha` is non-zero AND `git merge-base --is-ancestor $remote_sha $local_sha` fails (would discard remote commits). Also blocks master ref deletion (local_sha all zeros). Fast-forward pushes to master and all non-master pushes pass untouched.
  - Announcement protocol: `TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)` + append line to `shared/force-push-log.md` + `FORCE_PUSH_ANNOUNCED=$TS git push --force-with-lease`. Hook requires env var + well-formed ISO + age ≤ 300s + exact timestamp string in log + log path is not a symlink.
  - `shared/force-push-log.md` seeded with protocol doc and entry format.
  - `install-git-hooks.sh` header comment updated to list both hooks; no activation logic change required (FW-019 `core.hooksPath` mechanism auto-picks up new files).
  - Tested: 7 manual cases all pass (non-master push, fast-forward, force-push no-announce, force-push with-announce, master delete, stale announce, malformed TS, future TS, symlink log). `bash -n` clean.
  - Sonnet adversary review: H1 (multi-ref clearing) confirmed false positive on re-read — BLOCK_REASON is only set, never cleared. H2 (--mirror) handles correctly. M2 (negative age) + L4 (symlink) fixed pre-commit. M3 (GNU date-d portability) documented in header.
- **Follow-ups parked:**
  - **FW-007.1 — `git-reset-hard` wrapper:** per original scope, reset-hard in the working tree has no pre-reset hook. Plan: wrapper in PATH that reads Redis `cabinet:uncommitted:<officer>` markers (written by post-tool-use on `git add`/`git commit` without push, cleared on push) and refuses if any markers present. Not urgent — push-side is the higher-traffic risk.
  - **FW-007.2 — Timestamp-reuse hardening:** Sonnet M1 — the belt-and-suspenders check (env var + log line) doesn't prevent Officer B from copy-pasting Officer A's valid timestamp within the 300s window without writing a new log entry. Threat model requires hostile bots; low severity. Possible hardener: require log line tail-1 freshness, or require `FORCE_PUSH_ANNOUNCED` to include officer-role hash. Deferred.
- **Owner:** CTO. Closed during 5m-loop quiet period 2026-04-21 per captain's standing "never report idle" directive.
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
- **Status:** DONE 2026-04-21 — 23 exit-2 echo paths migrated to stderr.
- **Problem:** `cabinet/scripts/hooks/pre-tool-use.sh` had 22 `exit 2` block paths; only 3 redirected to stderr (spending caps from FW-002). The remaining 19 echoed to stdout. Claude Code's hook engine suppresses stdout on exit 2 and only shows stderr, so blocks manifested as "No stderr output" silent rejections with zero diagnostic surface. Re-validated today: I hit this on the PR-4 self-merge against BOTH Section 6 (Layer 1 reviewed gate) and Section 7 (CI green gate), and had to read the hook source to discover what the gate wanted.
- **Desired end state:** Every exit-2 echo path uses stderr so operators see the required action immediately.
- **Fix shipped:**
  - 23 echo lines migrated: KILL SWITCH, 5 prohibited-actions blocks, 3 codebase-ownership blocks, 4 constitution-protection blocks, LAYER 1 GATE, CI GREEN GATE, 2 context_slug blocks (including the two-line `Known slugs:` continuation), capacity_check, MCP scope, and 4 Cabinet-MCP peer-trust blocks.
  - Updated file-header comment (lines 2-7): made "stderr, not stdout" load-bearing with a one-line why + explicit instruction for future contributors adding new exit-2 paths.
  - `bash -n` passes; final counts: 29 `>&2` redirects (6 pre-existing + 23 new), 25 real `exit 2` statements all preceded by stderr echoes.
  - Sonnet adversary review: LGTM with 1 optional LOW (inline `# TEMPLATE:` near each gate section — deferred as ergonomic nice-to-have; header comment is sufficient).
- **Follow-up parked:** `.claude/hook-help.txt` auto-surfacing pointer — engine-level capability, not required for this fix.
- **Owner:** CTO.
- **Source:** PR-3 merge attempt 2026-04-21; PR-4 merge re-hit same day. Closed during 5m-loop quiet period 2026-04-21 per captain's standing "never report idle" directive.

---

### FW-023 — Spec 039 test-fixture coverage expansion
- **Status:** DONE 2026-04-21 — both halves landed (fixtures `e793059`, pytest harness this commit).
- **Problem:** `cabinet/scripts/lib/test_etl_fixtures.py` shipped 8 fixtures covering representative paths (LINEAR queue/wip/done/cancelled, epic synthesis, GH FW-marked + closed + no-marker). Non-blocking gaps flagged by COO: (a) no GH fixture with `state_reason='not_planned'` to validate AC #52 (closed-not-planned → cancelled) end-to-end, (b) no `captain_decision=TRUE` fixture (Linear label-based flag).
- **Progress 2026-04-21 — fixtures (commit `e793059`):** `LINEAR_ISSUE_CAPTAIN_DECISION` (SEN-251 pricing-pivot), `GH_ISSUE_CLOSED_NOT_PLANNED` (FW-013, AC #52), `GH_ISSUE_CAPTAIN_DECISION` (FW-010, GH parity). `ALL_LINEAR_ISSUES` / `ALL_GH_ISSUES` bundles updated.
- **Progress 2026-04-21 — pytest harness:** `cabinet/scripts/lib/tests/{__init__.py, conftest.py, test_etl_transforms.py}`. 24 pure-function tests covering `_map_state` (5 Linear fixtures + 2 edge cases for Spec 038 §4.5 started→queue + On Hold), `_map_status` (AC #52 grid: open / closed+completed / closed+not_planned / closed+None), `_extract_fw_marker` (positive, trailing-content H1-regression guard, absent, empty/None, mid-line-rejected `^`-anchor guard, closed-not-planned fixture), `_extract_priority` (positive, absent, case-insensitive), and captain-decision label parity (Linear + GH, positive + negative). `conftest.py` stubs `requests`/`yaml` in sys.modules so the harness runs under plain `python3` today without FW-024; stubs become dead weight once FW-024 lands real deps (noted in comment). Runnable two ways: `python3 cabinet/scripts/lib/tests/test_etl_transforms.py` (today, 24 pass) and `python3 -m pytest cabinet/scripts/lib/tests/` (when FW-024 + python3-pytest ships). Sonnet adversary review passed (1 MEDIUM + 1 LOW both resolved pre-commit).
- **Coupled to:** FW-021 (Gate 3 hash parity test) — now has scaffolding to plug into. FW-024 will migrate the sys.modules stubs to real deps.
- **Owner:** CTO.
- **Source:** COO PR-3 code-review 2026-04-21 15:26 UTC — flagged non-blocking, cleared for self-merge. Both halves completed during 5m-loop quiet period 2026-04-21 per captain's standing "never report idle" directive.

---

### FW-024 — Dockerfile.officer Python deps (Spec 039 ETL durable fix)
- **Status:** Captain founder-action — pending 2026-04-21.
- **Problem:** Officer containers built from `cabinet/Dockerfile.officer` off `ubuntu:24.04` lack `pip3` / `psycopg2` / `requests` / `yaml`. Spec 039 Phase A Gate 1 (`migrate-sources-to-officer-tasks.sh`) fails preflight in officer containers. Officers cannot edit Dockerfile.officer themselves — pre-tool-use.sh hook line 338 blocks Edit/Write on paths containing `Dockerfile` (hard block, all officers, no bypass).
- **Interim mitigation:** `bootstrap-host.sh` now installs the three Python modules on HOST so wet-run scripts can execute from a host shell (commit `0433733`, 2026-04-21). Unblocks tonight but does not help in-container operators.
- **Captain founder-action:**
  1. Edit `cabinet/Dockerfile.officer` — add to existing apt-get line: `python3-pip python3-psycopg2 python3-requests python3-yaml`.
  2. Rebuild: `docker compose -f cabinet/docker-compose.yml build` (or `up -d --build`).
  3. Restart: `docker compose -f cabinet/docker-compose.yml up -d --force-recreate`.
  4. Verify: `docker exec officer-cos python3 -c 'import psycopg2, requests, yaml'` returns exit 0.
- **Unblocks:** CoS Gate 1 dry-run (currently halting at preflight), container-shell wet-run replays.
- **Owner:** Captain (Nate) — only role with Dockerfile edit authority per hook policy.
- **Effort:** ~5 min edit + ~2-3 min rebuild.
- **Source:** CoS blocker trigger 2026-04-21 15:48:01 UTC; CTO confirmation that in-session Dockerfile edit was blocked by pre-tool-use hook.

---

### FW-016 — Delete byte-count cost-write path in post-tool-use.sh
- **Status:** DONE 2026-04-21 — 5 files, 99+/77-. Sonnet adversary review caught one BLOCKER pre-commit (EVAL-003 false-fail when `daily_per_officer_usd=0`) and one L nit (display-drop migration note); both fixed. Legacy keys (`cabinet:cost:daily:*`, `cabinet:cost:officer:*:*`, `cabinet:cost:monthly:*`) will expire naturally via their 48h/32d TTLs — no flush needed.
- **What shipped:**
  - `cabinet/scripts/hooks/post-tool-use.sh` — deleted byte-count INCRBY block (section 2), replaced with an explanatory comment pointing to the wrapper + HSET.
  - `cabinet/scripts/cost-dashboard.sh` — reads tokens:daily HSET, awk-sums `*_cost_micro` fields, micro→cents conversion, SCAN across YYYY-MM-* for monthly. Smoke-tested against real Redis: realistic numbers ($66.72/day, $524.79/month, plausible per-officer splits).
  - `cabinet/dashboard/src/lib/redis.ts` — `getCostHistory` rewritten to read HSET, drops legacy mockStore seeding, mock HSET loop extended 7→30 days to cover `getCostHistory(30)`.
  - `cabinet/scripts/test-escalation.sh:156` — swaps `GET` on legacy key for `HGETALL` on tokens:daily.
  - `cabinet/scripts/run-golden-evals.sh` EVAL-003 — was silently broken on two counts (wrote legacy key that pre-tool-use no longer reads; greppped stdout for a stderr message). Now: HSET writes `cos_cost_micro=999999999`, captures stderr via `2>&1 >/dev/null`, greps `BLOCKED.*officer=cos`. Skips gracefully when platform.yml cap=0.
- **Why this mattered:** byte-count INCRBY under-reported by ~100× (byte length ≠ tokens) AND double-counted alongside the cost-aware Anthropic wrapper. Dashboard showed inflated-but-wrong numbers. More dangerous: EVAL-003 was quietly passing as a no-op for an unknown stretch — golden evals must not silently rot.
- **Source:** CTO session 2026-04-17 23:00 UTC discovered drift; CTO session 2026-04-21 19:00 UTC shipped the fix during /loop proactive work.
