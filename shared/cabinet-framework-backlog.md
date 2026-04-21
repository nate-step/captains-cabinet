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
- **Status:** DONE 2026-04-21 — Python-side fixture shipped. 6 tests, all pass under `python3 test_gate_3_hash.py` (and `python3 -m pytest` when FW-024 lands).
- **Problem:** `cabinet/scripts/gates/gate-3-idempotency.py` hand-codes the 15-col hash basis per Spec 039 §5.9 M-5. Adversary review caught initial divergence (missing cols, wrong algorithm) that would have silently passed idempotency on mutated rows. No test fixture asserts Python hash output equals the spec-mandated md5.
- **Fix shipped:**
  - `cabinet/scripts/gates/tests/test_gate_3_hash.py` (180+ LOC, 6 tests): (1) `_HASH_COLS == SPEC_HASH_COLS` verbatim, order-sensitive; (2) sentinel — exactly 15 entries; (3) golden-hex `4131f221173010942e19edebc63a7e9e` for canned row with 2 NULL cols (blocked_reason, decision_ref); (4) golden-hex `e4e3de02987a900484c3e58a4df55404` for all-populated variant; (5) None-skip parity — flipping a NULL col to a value MUST change the hash (catches accidental `str(None)` → `"None"` stringification); (6) order-sensitivity — swapping two adjacent col positions MUST change the hash. Stubs psycopg2 via `sys.modules.setdefault` (stub leak warning documented inline). Loads hyphenated `gate-3-idempotency.py` via `importlib.util.spec_from_file_location`.
  - `cabinet/scripts/gates/tests/__init__.py` (empty, pytest package marker).
  - `gate-3-idempotency.py:_fetch_row_hashes` docstring expanded with Python↔Postgres type-coercion parity caveat: booleans (`str(True)`=`"True"` vs concat_ws → `"t"`/`"true"`), dates (safe with psycopg2), integers (safe). If a future Postgres-side hash gate lands, parity requires explicit coercion shims AND a cross-language fixture — current test guards Python side only.
- **Sonnet adversary review:** SAFE TO MERGE. 1 H (Python↔Postgres bool divergence not tested) + 1 M (sys.modules stub-leak warning) — both addressed via doc-only changes before commit.
- **Coupled to:** FW-023 (pytest harness pattern — same sys.modules stub approach), FW-024 (once psycopg2-binary ships, delete the stub and let real import win).
- **Owner:** CTO.
- **Source:** Spec 039 PR-3 adversary B-1 finding; closed during 5m-loop quiet period 2026-04-21 per captain's standing "never report idle" directive.

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
- **Regression catcher shipped 2026-04-21:** `run-golden-evals.sh` EVAL-007 pins the invariant — every `exit 2` (non-comment) in `pre-tool-use.sh` must have `>&2` on the nearest preceding non-blank, non-comment line. Awk-based, POSIX-portable. 10/10 → 11/11 evals. Self-test verified on a crafted violation; Sonnet adversary review caught one false finding (`>&2 echo msg` claim — verified bash routes it to stderr correctly) and three doc-only improvements (EVAL-004 stderr note, scope comment for other hook types, count-drift caveat), all applied pre-commit. Also caught and fixed a FW-022 cascade failure: EVAL-001 and EVAL-002 had silently broken when block messages moved to stderr — both now use `2>&1 >/dev/null` for stderr capture.
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
- **Regression catcher shipped 2026-04-21:** `run-golden-evals.sh` EVAL-008 pins the stop-hook → HSET write path. Canned Opus transcript (input=1000, output=500, cache_write=200, cache_read=3000) → asserts stop-hook writes `evaltest_input/output/cache_write/cache_read/cost_micro` to `cabinet:cost:tokens:daily:$DATE` with cost_micro=54150 matching the Opus math. Catches drift in the jq extraction chain, the HINCRBY field list, or the COST_MICRO formula. Trap cleanup HDELs today+yesterday to handle midnight-spanning eval runs. Sonnet adversary review caught midnight-boundary trap bug (fixed: HDEL both dates), `/tmp/eval-transcript-*.jsonl` glob race (fixed: scope to `$$`), and doc gaps (scope section expanded to note new-field drift, cabinet-wide cap window, evaltest reserved-name convention). Suite 11/11 → 12/12.
- **Source:** CTO session 2026-04-17 23:00 UTC discovered drift; CTO session 2026-04-21 19:00 UTC shipped the fix during /loop proactive work. EVAL-008 regression catcher shipped during subsequent /loop tick after stop-hook silent-fail audit.

---

### FW-025 — Golden-evals pre-push gate (catch silent eval rot at commit boundary)
- **Status:** Shipped 2026-04-21 (Option 1 — pre-push hook extension).
- **Problem:** FW-022 (`d45c8f2`, 2026-04-21 19:16:17Z) silently broke EVAL-001 and EVAL-002 for ~56 minutes before `8577433` (20:12:14Z, FW-022 regression catcher) caught it. The root cause was FW-022 migrating block messages from stdout → stderr; the two evals captured `2>/dev/null` and so saw empty output. No merge/push gate runs `run-golden-evals.sh`, so golden-evals can rot between runs with zero visibility until the next manual invocation. FW-007's pre-push hook catches force-overwrites on master but does not run the eval suite.
- **Desired end state:** Every `git push origin master` that touches hook files or eval plumbing runs `bash cabinet/scripts/run-golden-evals.sh` locally before the push completes; non-zero exit blocks the push with stderr explaining which eval failed (FW-022 lesson). Optionally gate all pushes regardless of changed paths — evals are <2s, cost negligible.
- **Options:**
  1. **Extend `cabinet/scripts/git-hooks/pre-push`** — cheapest, local-only, shared-tree aware, no CI infra. Calls `run-golden-evals.sh`; non-zero exit aborts push. Respects captain's rapid-iteration-feedback preference.
  2. **GitHub Actions CI workflow** — catches pushes that bypass the local hook (e.g. `git push` from host shell where hook isn't installed), but requires `.github/workflows/` setup (Captain approval for directional change) and per-push latency. Deferred candidate.
  3. **Both** — belt-and-suspenders, defer #2 until #1 proves insufficient.
- **Recommended:** Option 1 first. Propose #2 as a separate FW item if #1 shows false-negatives in practice.
- **Scope hazards:**
  - EVAL-003 needs Redis — today it skips gracefully when `platform.yml` cap=0 (already shipped FW-016 skip path). Pre-push path must not require Docker compose up.
  - EVAL-007 (awk-based exit-2 scan) and EVAL-001/002 (hook smoke) are pure bash, fast (<200ms), no deps.
  - Full 11-eval suite runs in ~1-2s locally per empirical measurement — acceptable for pre-push latency.
  - EVAL awk trigger (`/exit 2/`) is a loose regex — future string literals like `echo "exit 2"` would false-positive. Already documented inline in EVAL-007; harmless today.
- **Effort:** S (~2-3h including adversary review).
- **Owner:** CTO.
- **Depends on:** FW-007 pre-push hook scaffold (shipped) — FW-025 extends it.
- **Source:** COO adversary review of commit `8577433` (2026-04-21 20:15 UTC) — flagged as tangential FW opportunity, not blocking. Cascade gap empirically validated via git authordates: FW-022 (`d45c8f2`, 19:16:17Z) broke EVAL-001/002 for 56 min with no merge gate to catch, until `8577433` (20:12:14Z) landed. Timestamp correction applied per COO review of initial FW-025 draft.
- **Shipped:** Option 1 implemented in `cabinet/scripts/git-hooks/pre-push` via `run_golden_evals_gate()` function. Fires only when push includes `refs/heads/master`; uses `flock -w 30 $REPO_ROOT/.git/cabinet-golden-evals.lock` to serialize eval runs across concurrent officers (mitigates EVAL-008's shared `evaltest_*` Redis-key contamination). `timeout 60` wraps the eval invocation to bound runaway hangs. Fail-closed on non-zero eval exit. Pre-commit Sonnet adversary review (2026-04-21): 5 findings triaged — rejected 3 (false positive on BLOCK_REASON bleed, misread of flock(2) semantics, Redis-down silent-skip would re-introduce FW-022 risk), accepted 2 doc-only. COO post-commit adversary (2026-04-21 on 549062a): accepted all 3 rejections with refined line citations; surfaced 5 new findings — 2 Ms deferred to FW-026, 3 Ls applied in polish commit (lock relocated from /tmp to .git/ per L-1; `timeout 60` wrapper added per L-2; stderr timeout message now includes `fuser` hint per L-3). Empirically validated: test 1 (non-master push) skips gate, test 2 (master FF) runs 12/12 evals, test 3 (master force-overwrite) blocks before gate. Follow-up watchpoint: if Captain tightens `daily_cabinet_wide_usd < $1`, re-evaluate EVAL-008 probe-field collision window.

---

### FW-026 — FW-025 follow-ups: finer-grained escape, pushed-commit evaluation, GH Actions belt-and-suspenders
- **Status:** Proposed (Phase B — not blocking FW-025).
- **Problem:** FW-025 shipped three Phase-A accepted gaps:
  1. **M-1: `--no-verify` couples FW-007+FW-025 bypass.** The sole emergency escape from the FW-025 eval gate is `git push --no-verify`, which simultaneously disables FW-007's force-push refusal. Same keystroke that bypasses the eval gate also enables accidental master destruction. Granularity risk is low today (officer pushes are deliberate), but will grow once the Captain gets a web-push vector.
  2. **M-2: Gate evaluates WORKING TREE, not pushed commits.** `run-golden-evals.sh` tests on-disk state of `cabinet/scripts/*`, not the ref SHAs being pushed. Amend-off (fix in WT, committed version stale), selective-file commits (fix un-staged, bad code in commit), and parent-pushes (`git push origin HEAD^:master`) can slip broken commits past a green gate. Full mitigation requires `git stash && checkout <local_sha> && eval && restore` which is invasive and unsafe in a shared tree.
  3. **CI belt-and-suspenders**: FW-025 Option 2 (GitHub Actions workflow) was deferred — local hook catches the 99% but host-shell pushes bypass it. Threat model is narrow today (all officers bootstrap-installed, share one tree), but Captain web-push or CoS provisioning-dashboard push vectors would bypass.
- **Options:**
  1. **Fine-grained escape env vars.** `SKIP_GOLDEN_EVALS=<reason>` or `SKIP_EVAL_ANNOUNCED=<ts>` (announce-to-log pattern, mirrors FW-007's `FORCE_PUSH_ANNOUNCED`). Preserves FW-007 while granting FW-025 bypass. ~1h effort.
  2. **Pushed-commit evaluation.** Add a `git stash --include-untracked && git checkout <local_sha> && run evals && git checkout - && git stash pop` dance inside the gate. Unsafe in shared tree unless atomic-wrapped. Alternative: detect WT dirtiness (`git diff --quiet HEAD`) and abort the gate with guidance. ~3-4h including adversary review.
  3. **GitHub Actions CI workflow.** `.github/workflows/golden-evals.yml` running `run-golden-evals.sh` on every PR + push to master. Requires Captain approval for directional change (introduces CI spend, needs secrets for Redis test container). ~2h infra + Captain sync.
- **Recommended:** Options 1 and 2 bundled (both scope-in-pre-push); Option 3 as a separate sub-item after Captain sync.
- **Effort:** M (~4-6h total).
- **Owner:** CTO.
- **Depends on:** FW-025 shipped (this extends it).
- **Source:** COO adversary review of commit `549062a` (2026-04-21 20:46 UTC) — `M-1` (--no-verify coupling), `M-2` (WT-vs-pushed-commits). FW-025 scope hazard #3 (GH Actions belt-and-suspenders) rolled in here. COO explicit `DEFER` on all three until Phase B.

### FW-027 — post-tool-use.sh silent-fail paths (audit follow-ups + regression evals)
- **Status:** Phase A shipped 2026-04-21 (commit `15b94f8` — 4 fixes + COO ACK). EVAL-009/010 shipped 2026-04-21 (commit `0cd5129`). M-4 edge-cases + EVAL-011 shipped 2026-04-21 (commit `bde229e`). L-6 + L-7 + EVAL-012 shipped 2026-04-21 (commit `7f719b5`). LAST_EXPERIENCE symmetric port + EVAL-012 hardening (COO #1 + #2 observations) shipped 2026-04-21 (commit `ddae835`). HEAD:main + `;`-separator + refs/heads/main deploy-regex scope-gaps + EVAL-011 split-range ordering shipped 2026-04-21 (this commit). Phase C remainder: L-6 semantic validation (unreachable today).
- **Phase A — SHIPPED:**
  1. **H-1: `trigger_send` silent XADD failure.** `lib/triggers.sh` — `XADD > /dev/null 2>&1` with no rc check meant Redis-down silently dropped deploy-notify + Captain-relay triggers; validators never learned a push happened. Fix: capture XADD stderr + rc, emit `trigger_send WARN: XADD to cabinet:triggers:$target failed ...` to stderr on failure. Success remains silent.
  2. **H-2: `. triggers.sh 2>/dev/null` suppressed source errors.** `post-tool-use.sh:~205` — if the library file was missing or had a syntax error, source failed silently and `trigger_read` was undefined. Fix: removed `2>/dev/null`, wrapped in `if ! . ...; then echo "CRITICAL: triggers.sh failed to load" >&2; fi`. Officer now sees load failures.
  3. **M-3: Log-write silent drop.** `post-tool-use.sh:~63` — `echo ... >> $LOG_FILE` unguarded; disk-full / RO-mount / perm error left invisible log gaps that poison retro activity math. Fix: appended `|| echo "LOG WRITE FAILED for $LOG_FILE ..." >&2`. One-line cost.
  4. **M-4: Deploy regex missed tokenized-URL pushes.** `post-tool-use.sh:~253/~276` — old pattern `git push[[:space:]]+(origin[[:space:]]+)?(main|master)` required the literal word `origin` between `push` and the refspec; our shared-tree push invocation is the tokenized URL form (`git push https://x-access-token:$PAT@.../Sensed main` per `memory/reference_github_push_invocation.md`), which has no `origin` keyword. Result: product deploys via tokenized URL silently skipped the AUTO-DEPLOY alert to validators + reviewers. Fix: relaxed to `git push[[:space:]]+.*[[:space:]](main|master)([[:space:]]|$)` — gated by the earlier framework-URL filter so cabinet master pushes still skip. Spot-checked on 6 inputs (origin main, tokenized URL main, feat/nav-main, main && log main, release-please--branches--main, main-branch) — all triggered as expected.
  - **Sonnet adversary triage:** 3 false-positives rejected with trace (trigger_send redirect-order concern: `2>&1 > /dev/null` inside `$(...)` captures stderr correctly because fd2 is dup'd to fd1 BEFORE fd1 is redirected to /dev/null; log-write `||` binding concern: inner `|| echo '{}'` jq fallbacks never propagate non-zero to outer echo, so outer `||` fires only on the `>>` append; idle-warn "command not found" concern: redundant — the earlier CRITICAL line already surfaces the diagnostic). 1 cosmetic cleanup accepted (`^` inside `(^|[[:space:]])` is dead after `.*` consumes — replaced with just `[[:space:]]` to avoid misleading future readers). 1 scope-gap deferred (`trigger_read 2>/dev/null` swallows command-not-found — but the CRITICAL diagnostic already fires above).
- **Phase B — SHIPPED:**
  1. **L-6 — SHIPPED (this commit): ISO-8601 shape guard on `LAST_CALL`.** Added `grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z$'` guard before `date -d`; on malformed value, emit `WARN: cabinet:last-toolcall:<officer> had malformed value '<val>' ...` to stderr + skip idle check. Fractional-seconds accepted per Sonnet adversary Finding #5 (future Python writer would emit `.123Z` form — still valid ISO-8601, guard should accept).
  2. **L-7 — SHIPPED (this commit): stderr WARN on empty CAPTAIN_CHAT_ID.** Restructured `if [ -z "$CAPTAIN_CHAT_ID" ]; then WARN-stderr; elif [ "$REPLY_CHAT" = "$CAPTAIN_CHAT_ID" ]; then prompt; fi`. Now visible when env var unset AND platform.yml key drifts — steady-state silent once config fixed.
  3. **EVAL coverage — SHIPPED 2026-04-21:** Two new golden evals pin the Phase A invariants:
     - **EVAL-009 (dynamic):** PATH-stubs `redis-cli` to exit 1 + emit connection-refused stderr; sources `triggers.sh`; calls `trigger_send`; captures subshell stderr to file; greps for "trigger_send WARN" / "XADD.*fail" / "WARN.*XADD" (semantic invariant, not exact text — Sonnet flagged over-strictness on initial draft).
     - **EVAL-010 (static):** greps `post-tool-use.sh` for anti-pattern `^[[:space:]]*(.|source)[[:space:]]+[^[:space:]]*triggers\.sh[[:space:]]+2>/dev/null` (both `.` and `source` covered per Sonnet finding); also greps for positive invariant "CRITICAL.*triggers.sh failed to load". Static because dynamic source-failure test would require removing `triggers.sh` from disk, which bricks every other officer's hooks in the shared tree.
     - Suite: 14/14 green with both.
  4. **M-4 edge-cases — SHIPPED 2026-04-21 (this commit):**
     - **(a) M-4a — `git push main` bare form.** Relaxed `.*[[:space:]]` → `(.*[[:space:]])?` making the intermediate arg optional. Traced: bare form hits `git push[[:space:]]+` → `(.*[[:space:]])?` matches empty → `(main|master)` matches directly. Tokenized + `origin` forms still match.
     - **(b) M-4b — `git push --dry-run origin main` FP.** Added skip elif BEFORE the deploy elif in both block 5 + block 6. Sonnet adversary extended scope: (i) `-n` short form of `--dry-run` was still falling through — added to skip; (ii) greedy `.*` in original skip crossed `&&` boundary and swallowed flag text from chained commands (e.g. `git push origin main && git commit -m "foo --dry-run"` would have been skipped, suppressing real-deploy AUTO-DEPLOY). Final regex: `git push[^&;]*--dry-run|git push[[:space:]]+([^&;]*[[:space:]])?-n([[:space:]]|$)` — `[^&;]` anchors the scan within the push command.
     - **EVAL-011 (behavioral):** extracts deploy + dry-run regexes from hook source via grep+sed, runs positive/negative test matrix (bare push, tokenized URL, `-n` before/after refspec, `&&`-chained commands with flag text, release-please branch, feature-branch). Asserts dry-run elif precedes deploy elif + both block 5/6 updated (count=2 of each).
     - **Scope-gap: `git push origin HEAD:main`** — refspec with `:` has no space before `main`, so `(.*[[:space:]])?` can't satisfy; deploy form silently missed. Low-frequency (most officers push bare `main` or via tokenized URL). Deferred to Phase C.
  5. **EVAL-012 — SHIPPED (this commit): static dual-check for L-6 + L-7 guards.** `grep -qF` on 3 distinctive phrases — ISO-8601 regex fragment, `'malformed value'` WARN, `'captain_telegram_chat_id not resolved'` WARN. Sonnet adversary verified single-match on each (no comment-block survival path).
  6. **Rejected false-positive (documented for future triage):** Audit Finding #5 claimed `CALL_COUNT` modulo "floods every call when Redis down." Trace: line 303 defaults `CALL_COUNT=1` on Redis failure; `1 % 50 = 1 ≠ 0`; modulo guard on lines 306/358 is FALSE — nudges never fire during Redis outage (opposite of claim, which is actually graceful-degrade behavior). Rejected per `feedback_adversary_scope_gap_vs_bug.md` with control-flow citation.
- **Phase C — SHIPPED except L-6 semantic validation:**
  1. **LAST_EXPERIENCE symmetric L-6 port — SHIPPED (commit `ddae835`).** `post-tool-use.sh:~412` — same ISO-8601 shape guard + WARN pattern as L-6, ported to the `cabinet:last-experience:$OFFICER` branch. Adversary-identified symmetric site.
  2. **EVAL-012 hardening per COO observations on `7f719b5` — SHIPPED (commit `ddae835`).**
     - COO #1: added grep pin for `(\.[0-9]+)?Z` fractional-widening fragment so a revert of Sonnet #5's fix is caught.
     - COO #2: swapped tautological `cabinet:last-toolcall` key-name check for the distinctive L-6 WARN phrase `Idle-warning skipped`.
     - Added symmetric `Proactive-work check skipped` pin for the LAST_EXPERIENCE port.
  3. **HEAD:main + `;`-separator + refs/heads/main scope-gaps — SHIPPED (this commit).** Extended deploy regex on lines 257 + 283: pre-main class `[[:space:]]` → `[[:space:]:]` (adds `:` for `HEAD:main` refspecs), terminator class `[[:space:]]` → `[[:space:];]` (adds `;` for shell-chained pushes). Added optional `(refs/heads/)?` prefix group for `refs/heads/main` form. **Sonnet adversary Finding #1 (code-bug) — caught before commit:** initial draft used `[[:space:]/:]` pre-main class which caused false-positives for any `<anything>/main` branch name (`feat/main`, `issue-42/main`, `fix/main`). Fix: removed `/` from the class, added explicit `(refs/heads/)?` literal prefix. Verified on 19-case matrix (8 positive + 10 negative + tokenized URL) — no false positives. EVAL-011 negative suite extended to pin the `feat/main` + `issue-42/main` rejection.
  4. **EVAL-011 split-range ordering — SHIPPED (this commit).** Replaced `head -1` line-check with `readarray`-based per-block index-paired ordering loop. Now a refactor that desyncs block-6 (deploy-elif moved above dry-run-elif) fails EVAL-011 even if block-5 still passes.
  5. **L-6 semantic validation — PARKED (COO observation #3 on `7f719b5`).** Shape-only regex accepts `2026-13-45T25:70:99Z`; `date -d` returns 0 and flood persists. Unreachable today (only writer is `date -u` which cannot emit invalid values); if a non-`date -u` writer ever appears, add `date -d "$value" >/dev/null 2>&1` as a secondary gate. Lower priority — no active invariant at risk.
- **Effort:** FW-027 end-to-end complete modulo unreachable C-5 park.
- **Owner:** CTO.
- **Source:** Background Sonnet audit of `cabinet/scripts/hooks/post-tool-use.sh` (agent `abde8919ad9f72dd1`, completed 2026-04-21 21:00 UTC). 7 findings (H:2 M:3 L:2) → Phase A shipped 4, rejected 1 FP, deferred 2 L + 2 evals to Phase B.

### FW-028 — AUTO-DEPLOY trigger amplification (no dedup on deploy detection)
- **Status:** Phase A SHIPPED 2026-04-21 (command-start anchor, both blocks, EVAL-013). Phase B (SETNX dedup) deferred pending real-traffic observation.
- **Symptom:** COO received 4 identical AUTO-DEPLOY triggers in 110s during SEN-559 validation (21:54:48, 21:56:07, 21:56:23, 21:56:38 UTC — deltas 79s/16s/15s). All 4 bodies identical. Single push should fire exactly one trigger.
- **Root cause (confirmed):** `post-tool-use.sh` deploy-detection block (5) and verify-deploy-reminder block (6) regex-matched any CMD containing `git push ... main` as a substring — regardless of whether `git push` was the actual executable or just quoted string content (e.g., `for cmd in "git push origin main"` in EVAL-011).
- **Phase A (SHIPPED):**
  1. **Command-start anchor in BOTH blocks 5 + 6:** noop-first-elif requires CMD to START with `(git|gh|curl)` optionally preceded by `sudo `, `env VAR=X ` (multi-assignment supported), or `timeout Ns `. `head -n1` restricts shape-check to line 1 so heredoc bodies don't trip. Adversary-validated (Finding #5: multi-assignment `env A=1 B=2 git push` coverage added pre-commit).
  2. **EVAL-013 (static):** pins anchor count=2, distinctive comment phrases, and exercises the anchor against 13 positives (incl. COO-required Phase C forms: `HEAD:main`, `refs/heads/main`, `main; echo done`) + 9 test-harness negatives (for-loop, echo, grep, bash -c, cat|grep, quoted-string leading, comment, python, variable-assignment).
- **Phase B (deferred):** SETNX dedup lock (`cabinet:deploy-notified:<hash> EX 60`). Decision: observe real-traffic amplification first. Anchor alone may be sufficient — the observed amplification root cause was test-harness substring match, not legitimate duplicate pushes. Re-evaluate after 1 week of post-shipping observation. If amplification recurs outside test harnesses, implement dedup with normalized-refspec hash (per COO suggestion).
- **Known scope gaps (not in Phase A, adversary-flagged but deferred):**
  - `git log 'git push origin main'` with literal push-string argument would still trip deploy regex (pre-existing substring-match limitation, not introduced by FW-028).
  - `sudo -u someuser git push` (sudo with flags) — anchor only accepts bare `sudo `.
  - `GIT_DIR=/path git push` (bare var assignment without `env ` keyword).
  All three are theoretical — no officer push pattern uses these forms. Track as low-priority FW-029 candidate if operational.
- **Blast radius before fix:** Validators + reviewers received N spurious AUTO-DEPLOY triggers per deploy event (observed: 4 triggers in 110s for single push).
- **Effort:** S (~1h — shipped).
- **Owner:** CTO.
- **Source:** COO observation during SEN-559 Universal Links deploy validation 2026-04-21 21:57 UTC. Phase A shipped 2026-04-21 22:XX UTC.

### FW-029 — pre-tool-use.sh gate amplification (state-consuming substring match)
- **Status:** Phase A SHIPPED 2026-04-21.
- **Symptom (confirmed operationally):** The Layer 1 gate (`pre-tool-use.sh:362`) and CI Green gate (`:377`) matched substring `git push.*main|gh pr merge` / `pulls/[0-9]+/merge` anywhere in CMD. Each match CONSUMED the `cabinet:layer1:cto:reviewed` / `cabinet:layer1:cto:ci-green` Redis key. Observed during FW-028 commit 89d82e7: `git commit -m` heredoc containing `git push` references in the commit body triggered the gate, consumed the reviewed key, forcing a re-SET before the actual push. Same substring-amplification class as FW-028 but with state-consumption semantics.
- **Amplification vectors (CTO session only, gate scoped `OFFICER=cto`):**
  - `git commit -m "...git push main..."` → Layer 1 fires, key consumed.
  - `echo "for cmd in \"git push origin main\"..."` → Layer 1 fires, key consumed.
  - `cat /tmp/log | grep 'git push main'` → Layer 1 fires, key consumed.
  - `gh api repos/.../pulls/42/merge -X PUT` → CI Green fires, key consumed (wanted — this IS the merge). But: `echo "pulls/42/merge"` ALSO fires CI Green, key consumed (false-positive).
- **Root cause:** Same as FW-028 — substring-match regex over payload, no command-start anchor. Additionally, Layer 1 action regex was main-only, missing framework-repo `master` branch.
- **Fix applied (Phase A):**
  1. **Two-phase check** — Layer 1 and CI Green gates now AND-compose (anchor && action). Anchor narrowed to DEPLOY SUBCOMMAND (`git push | gh pr | gh api | curl`), with optional priv-esc/env VAR=X/timeout prefix stack inherited from FW-028. Subcommand-level narrowing means `git commit`, `git log`, `gh pr view` fail Phase 1 — substring match on their bodies can no longer trip the gate.
  2. **Layer 1 action regex widened** from `git push.*main|git push.*origin main|gh pr merge` to `git push.*(main|master)|gh pr merge` — covers both Sensed product (`main`) and framework repo (`master`).
  3. **EVAL-014** pins anchor count=2 (Layer 1 + CI Green), FW-029 marker count>=2, 7 Layer 1 positives (incl. master + tokenized URL + env multi-assignment + gh pr merge) / 7 negatives (commits/echoes/for-loops/cats/bash -c/comments), 2 CI Green positives (curl PUT + gh api) / 3 negatives.
- **Scope gaps (acknowledged, NOT in Phase A — all theoretical, zero current officer usage per COO recon grep):**
  - (a) Compound prefix `cd X && git push origin main` — anchor SILENCES (`cd` not in prefix alternation).
  - (b) Shell `export FOO=bar && git push...` — anchor SILENCES (`export` not in prefix).
  - (c) Bare var-assign without `env` keyword: `GITHUB_PAT=foo git push...` — anchor SILENCES. **Notable instance:** the documented force-push protocol `FORCE_PUSH_ANNOUNCED=$TS git push --force-with-lease origin master` (cabinet/scripts/git-hooks/pre-push lines 21-25) passes Phase 1 silently. Accidentally correct for AUTO-DEPLOY (framework force-push shouldn't notify Sensed validators) but masks a Layer 1 gap — force-push to framework master bypasses Crew-review gate.
  - (d) Quoted value with space: `env FOO="bar baz" git push...` — anchor SILENCES (quantifier won't traverse internal quoted space).
  - (e) Multi-line CMD with line 1 non-deploy (e.g., `cd /opt/fake\ngit push...`) — anchor SILENCES via `head -n1`.
  - **FW-028-class gap preserved:** `git log --grep 'git push main'` style literal-arg forms still pass anchor (starts with `git log`... wait, post-fix anchor is `git push` subcommand-specific, so `git log` is REJECTED). Narrow-anchor fix closes this too.
- **EVAL-014 extractor fragility (non-blocking, flagged by COO):** `sed -E "s/.*grep -qE '([^']+)'.*/\1/"` breaks if a future action regex contains literal apostrophe. Extractor for L1 regex updated to match on distinctive `gh pr merge` tail (survives main|master widening). Could harden further with hex-escape or character-class extraction.
- **Blast radius before fix:** CTO gate-state consumed on any intermediate command mentioning push/merge text; forced re-SET of reviewed/ci-green keys before the actual action. Not catastrophic (state recoverable via re-SET) but confusing and context-burning. Post-fix: gate fires only on deploy-subcommand invocations with action-pattern match.
- **Effort:** S (actual ~30min — matched estimate).
- **Owner:** CTO.
- **Source:** CTO self-discovery post-FW-028 ship 2026-04-21 22:25 UTC (scanned other hooks for same amplification pattern). COO adversary review of FW-028 commit 89d82e7 surfaced additional forward-looking scope gaps (a-e + force-push note) 2026-04-21 22:30 UTC.
- **Adversary-found CODE BUG fixed pre-commit:** Layer 1 action regex `git push.*(main|master)` over-matched on feature-branch names containing `main`/`master` as substrings (`feature/maintenance-window-2026` → `.*main`tenance matches; `feature/master-plan` → `.*master`-plan matches). Fixed by adding trailing word-boundary `([[:space:];]|$)` to mirror post-tool-use.sh:267's `(main|master)([[:space:];]|$)` pattern. Two negative test cases appended to EVAL-014. Sonnet adversary Finding #1, 2026-04-21.

### FW-030 — Layer 1 gate: `git -C <dir> push` silently bypasses anchor
- **Status:** Proposed 2026-04-21 (Sonnet adversary Finding #2 on FW-029).
- **Symptom:** FW-029's narrowed anchor `git[[:space:]]+push` requires literal `git` directly followed by whitespace then `push`. The `-C <dir>` directory-override flag intervenes, so `git -C /workspace/product push origin main` silently fails Phase 1 — Crew-review gate bypassed.
- **Current usage:** Zero. Grep confirms `git -C` push appears only in EVAL-013 test matrix, not in any actual officer invocation. Documented CTO push form (see `reference_github_push_invocation.md` memory) uses explicit tokenized-URL — `git push https://x-access-token:$PAT@... main`.
- **Fix (when operational):** Extend anchor alternation to include `git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?push`. Pin with EVAL-014 positive case.
- **Effort:** XS (~10min, single regex edit + one eval case).
- **Owner:** CTO when first officer script adopts `git -C` push.

### FW-032 — pre-tool-use.sh:80 whitelist filename substring amplification (spending-cap bypass)
- **Status:** Proposed 2026-04-21 (Crew sweep Finding #9 post-FW-029 ship).
- **Symptom:** The Telegram whitelist detector at `pre-tool-use.sh:80` matches substring `send-to-group.sh` in `$CMD` via `grep -qE '(^|[[:space:]/])send-to-group\.sh([[:space:]]|$)'`. The left anchor `(^|[[:space:]/])` accepts START-OF-LINE, whitespace, OR `/` before the filename — so any command that READS the file path (not invokes) spuriously sets `IS_TELEGRAM_COMMS=1`. This cascades to `_SKIP_MAIN_CAP=1` (line 220), bypassing the per-officer daily spending cap for that one call.
- **Amplification vectors:**
  - `cat /opt/founders-cabinet/cabinet/scripts/send-to-group.sh | head` — `/` before filename matches left anchor, space after matches right anchor. Bypass fires.
  - `ls -la cabinet/scripts/ | grep send-to-group.sh` — space before filename, EOL after. Bypass fires.
  - `wc -l /path/send-to-group.sh` — same structure. Bypass fires.
- **Root cause:** Same bug class as FW-028 / FW-029 — regex on `$CMD` payload with state side effect (control-bypass of spending cap), no command-start anchor. The existing word-boundary anchors prevent `my-send-to-group.shrug` false-positives but NOT `cat /path/send-to-group.sh` read-with-filename.
- **Blast radius:** Per-officer daily spending cap bypassed for ONE Bash call that happens to read the filename. Still bounded by the telegram_whitelist_hourly_cap sub-limit (line 213 — INCR + cap check fires even on spurious matches), so attack depth is capped. But weakens a defense-in-depth control, and officers do legitimately read script files during debugging.
- **Proposed fix (Phase A):**
  1. Narrow the detector to require CMD START with a recognized invocation form: `bash send-to-group.sh`, `sh send-to-group.sh`, `/path/send-to-group.sh` (direct exec), or `./send-to-group.sh` (relative). Mirror the FW-028/029 priv-esc/env/timeout prefix stack for consistency.
  2. **EVAL-015** — pin positive matrix (all legitimate invocation forms fire whitelist) + negative matrix (cat/grep/echo/wc of filename do NOT fire).
- **Effort:** S (~30min — mirrors FW-028 Phase A architecture).
- **Owner:** CTO.
- **Source:** CTO Crew sweep 2026-04-21 22:40 UTC (post-FW-029 ship audit of remaining regex+state amplification patterns in hooks).

### FW-033 — post-tool-use.sh experience-nudge substring amplification
- **Status:** SHIPPED 2026-04-21 — Phase A pending commit at FW-033 Phase A push.
- **Symptom:** `post-tool-use.sh:185` sets `cabinet:nudge:experience-record:$OFFICER` (EX 3600) when CMD payload substring-matches `git push|gh pr create|gh pr merge`. `git commit -m "fix: pre-validate before gh pr merge"` spuriously sets the nudge key, triggering a false experience-record prompt 1h later.
- **Shipped fix (Phase A):**
  1. Bash branch: extract `.command` from TOOL_INPUT via jq (`_NUDGE_CMD`), apply command-start anchor `^[[:space:]]*<priv-esc>*(git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+(create|merge))([[:space:];]|$)` with `head -n1` heredoc guard. Mirrors FW-028/029/032 architecture.
  2. Write branch: extract `.file_path` via jq (`_NUDGE_PATH`), match against `(product-specs/|research-briefs/|deployment-status([./]|$))`. Prior form matched the JSON blob (so Write content mentioning these paths amplified); `([./]|$)` trailing anchor on `deployment-status` prevents over-match on `deployment-status-history.log` / `-formatter.ts` (Sonnet adversary Finding #6).
  3. EVAL-016 pins positive matrix (8 Bash + 4 Write paths), negative matrix (8 Bash non-invocation CMDs + 3 Write over-match paths), heredoc negative. EVAL-013 extractor updated to filter by FW-028's distinctive `(git|gh|curl)[[:space:]]` token (needed after EVAL-016 added a 3rd command-start anchor to post-tool-use.sh).
- **Adversary (Sonnet) findings triaged:**
  - Finding #5 (extractor `head -1` fragility): fixed inline via `grep -F '_NUDGE_CMD'` secondary filter.
  - Finding #6 (`deployment-status` substring over-match): fixed inline via `([./]|$)` trailing anchor.
  - Findings #1/#2/#4 (`npm run build && git push`, `for do git push done`, `GIT_SSH_COMMAND=... git push`): architectural scope-gaps consistent with FW-028 — documented as addendum to FW-036.
  - Finding #3 (`git -C <dir> push`): already filed as FW-030.
  - Finding #7 (jq silent failure fail-safe): rejected as FP — control-flow trace confirms empty-string → no match → no state change, which is the correct fail-safe direction.
- **Effort (realized):** S (~45min including adversary review + Write branch fix + EVAL-013 extractor update).

### FW-034 — pre-tool-use.sh:321 workspace-write guard false-block on read-with-redirect
- **Status:** Proposed 2026-04-21 (Crew sweep Finding #10).
- **Symptom:** `pre-tool-use.sh:321` blocks (`exit 2`) when CMD contains BOTH `/workspace/product/` AND write pattern (`>\s`, `sed -i `, `tee`, `cp .+ `, `mv .+ `). False-positive blocks `cat /workspace/product/README.md | tee /tmp/out.txt` — a read followed by tee-to-tmp is NOT a write to `/workspace/product/`, but substring match trips both patterns.
- **Blast radius:** MEDIUM (accuracy gap, fail-safe direction — over-blocks legitimate reads rather than under-blocking writes). Officer workflow friction; no control-bypass.
- **Proposed fix:** Narrow write-pattern regex to require the write TARGET be `/workspace/product/`. Currently the two substring checks are independent; need to correlate write-operator destination with the product path. More complex than FW-028-class fix — requires parsing write-operator targets.
- **Effort:** M (~2h — correlated pattern, not simple anchor).
- **Owner:** CTO.

### FW-035 — cosmetic amplifications (activity display + git-add gate stdout)
- **Status:** Proposed 2026-04-21 (Crew sweep Findings #2 + #4, bundled LOW-priority).
- **Symptom #1 (Finding #2):** `post-tool-use.sh:124-128` activity display string amplifies on `pulls/N/merge` and `gh pr create` substring — wrong dashboard label for 5 min.
- **Symptom #2 (Finding #4):** `post-tool-use.sh:462` infrastructure-review gate echoes stdout warning on `git add` substring match — spurious warning inside officer session for commit bodies mentioning `git add`.
- **Blast radius:** LOW — cosmetic/ephemeral. No gate consumed, no trigger fired.
- **Proposed fix:** Apply command-start anchor; pin as EVAL-017 + EVAL-018 if promoted.
- **Effort:** XS each.
- **Owner:** CTO (low-priority, batch with other hook work).

### FW-036 — FW-032 Phase B: whitelist anchor scope gaps (under-match on legitimate forms)
- **Status:** Proposed 2026-04-21 (Sonnet adversary on FW-032 Phase A ship — Findings #2/#3/#5/#8/#9).
- **Context:** FW-032 Phase A (commit pending) narrowed the telegram whitelist anchor to require a recognized invocation form, closing the read-form cap-bypass (Findings #1/#4 ship in Phase A). Adversary review surfaced additional legitimate invocation forms that the Phase A anchor does NOT match — these result in telegram sends getting main-cap-enforced instead of sub-capped (blocks Captain DMs at end-of-day instead of sub-cap).
- **Sub-findings (bundled because each is XS and touches the same regex):**
  - **#2 `bash -c '...send-to-group.sh...'` (launcher arg form).** `bash -c 'cmd'` puts the invocation inside a quoted `-c` argument; Phase A anchor doesn't match `-c` followed by string literal. Officers use `bash -c` occasionally for one-shot commands.
  - **#3 `bash -o pipefail send-to-group.sh` (long-option flag).** Phase A flag pattern `(-[A-Za-z]+[[:space:]]+)*` consumes `-o ` but leaves `pipefail` unmatched before filename. Rare — `set -o pipefail` is typically inside-script — but real under-match.
  - **#5 `env -i ... send-to-group.sh` / `env -u OLD NAME=val ... send-to-group.sh`.** Phase A env branch requires `env[[:space:]]+NAME=val`; doesn't permit `-i`/`-u` flags before the first `NAME=val`.
  - **#8 Command chaining after invocation.** `bash send-to-group.sh "msg" && second_cmd` fires whitelist (anchor checks the START of the line only), gets sub-cap for the whole chained command. Bounded by telegram_whitelist_hourly_cap INCR firing regardless, so attack depth = 1 extra call. Operational concern, not a security bypass.
  - **#9 `cd /tmp && bash send-to-group.sh "msg"` (cd-and-invoke).** `cd` isn't in the priv-esc stack, so this legitimate pattern fails the whitelist → main-cap enforced. Officers can split into two Bash calls as workaround.
  - **#10 `npm run build && git push origin master` (chained deploy).** FW-033 Sonnet adversary. Anchor requires deploy verb at START; `npm run build &&` precedes. Generic pattern across FW-028/029/032/033 (all share the anchor architecture). Operational impact: nudge missed on chained deploys; gate skipped on Layer 1 (real push still goes through).
  - **#11 `for i in 1 2 3; do git push; done` (loop-wrapped).** Same class as #10.
  - **#12 `GIT_SSH_COMMAND="ssh -i key" git push` (inline env assignment).** Inline `VAR=value cmd` form is NOT the `env VAR=value cmd` builtin form. Priv-esc stack covers the latter, not the former. Officers using inline env prefix (e.g., SSH key override) lose anchor match. Consistent gap across FW-028/029/032/033.
- **Decision on #10/#11/#12:** Accept as documented scope-gaps. Extending the anchor to cover chaining / loops / inline env would complicate the regex beyond maintainability benefit. Mitigation: officers split chained deploys into two Bash calls, or use the env builtin (`env VAR=value git push` matches).
- **Blast radius:** Operational friction — legitimate Captain DMs may hit main-cap instead of sub-cap on certain invocation forms. No security bypass, no state corruption, no protected-branch issue.
- **Proposed fix:** Extend Phase A anchor to cover each form; pin each with a positive EVAL-015 test case. Scope:
  1. Widen flag pattern to `((-[A-Za-z]+|-o[[:space:]]+[A-Za-z0-9]+)[[:space:]]+)*` for `-o pipefail`.
  2. Extend env branch to permit `-[A-Za-z]+[[:space:]]*` flags before first NAME=val.
  3. Add single-quote support (`'?`) around filename once extractor is refactored (see FW-037 below).
  4. Document chaining as single-command discipline; optionally tighten by requiring invocation be followed only by non-control chars to end of line.
  5. Accept `cd ... &&` as operational workaround (split into two Bash calls); do NOT add `cd` to priv-esc stack (shell-builtin scope creep).
- **Effort:** M (~1h, bundled regex widen + 5 eval cases + docs).
- **Owner:** CTO when Phase A ships and operational data confirms any under-match hurts.

### FW-037 — EVAL-015 extractor fragility (single-quoted grep regex limitation)
- **Status:** Proposed 2026-04-21 (Sonnet adversary Finding #10 on FW-032 Phase A).
- **Symptom:** `run-golden-evals.sh:1006` extracts the FW-032 anchor regex via `sed -E "s/.*grep -qE '([^']+)'.*/\1/"` — this matches the shortest text between single quotes, so if the live anchor ever contains a literal `'` (via bash `'"'"'` embedding trick) the extractor truncates at the first inner quote and returns a partial regex. Phase A Finding #1 fix initially tried to add `['"'"']?` to match single-quoted filenames and broke the extractor; worked around by dropping single-quote support.
- **Blast radius:** Test infrastructure only. No production impact. Future maintainers adding `'` to the anchor will silently break EVAL-015 until they realize.
- **Proposed fix:** Two options:
  1. Switch anchor to a double-quoted `grep -qE "..."` with escape for `$` → then `'` needs no escape in the anchor text; simplify extractor to `sed -E 's/.*grep -qE "([^"]+)".*/\1/'`.
  2. Extract the anchor via a different channel — e.g., a comment-delimited block `# FW-032-ANCHOR-START...# FW-032-ANCHOR-END` with the pattern on its own line.
- **Effort:** XS (~15min, one of the two options).
- **Owner:** CTO when extending the anchor.

### FW-031 — Layer 1 gate: mirror / HEAD / tag pushes silently bypass
- **Status:** Proposed 2026-04-21 (Sonnet adversary Finding #3 on FW-029).
- **Symptom:** Layer 1 action regex `git push.*(main|master)([[:space:];]|$)|gh pr merge` requires literal `main`/`master` in the refspec. These legitimate deploy forms fail Phase 2 and bypass Crew-review:
  - `git push origin HEAD` (implicit branch, HEAD resolves to current which is often master)
  - `git push --mirror` (mirror push, dangerous — force-pushes all refs)
  - `git push origin v1.0.0` (tag push — production releases)
- **Current usage:** Zero. Documented CTO push form always names the branch explicitly.
- **Fix (when operational):** Widen Layer 1 action alternatives to include `git push[^[:space:]]*[[:space:]]+--mirror`, `git push[^;]*HEAD([[:space:];]|$)`, and tag-ref pattern `git push[^;]*[[:space:]]+v[0-9]+\.[0-9]+\.[0-9]+([[:space:];]|$)`. Pin each with EVAL-014 positive case.
- **Effort:** S (~20min, regex widen + 3 eval cases).
- **Owner:** CTO when first officer script adopts mirror/HEAD/tag push.
