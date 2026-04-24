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
- **Status:** Captain founder-action — **COMMITTED 2026-04-24 morning CEST** (msg 1649, 2026-04-23 19:37 UTC).
- **Handoff doc:** `shared/interfaces/fw-024-rebuild-handoff.md` (staged 2026-04-23 19:45 UTC by CTO) — 1-line Dockerfile edit, 2-cmd rebuild, 1-cmd verify, pre-staged Gate 1 dry-run invocation. Captain is 1-keystroke from wet-run start.
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
- **Status:** Option 3 (GH Actions CI) SHIPPED 2026-04-23. `.github/workflows/cabinet-ci.yml` runs on PR + push to master: bash -n on hooks + lib, shell unit tests (test-triggers.sh + test-memory.sh), Python pytest (ETL transforms FW-023 + gate-3-idempotency FW-021), golden evals (24-eval suite inc. EVAL-023 FW-047 regression guard). Symlinks `$GITHUB_WORKSPACE/founders-cabinet` → `/opt/founders-cabinet` so hardcoded paths resolve; Redis 7 services container per job for isolated state. `permissions: contents: read` for minimum-privilege. Sonnet fresh-context review: 1 MEDIUM (permissions) fixed pre-commit; 5 other concerns SAFE (shell tests, XLEN on non-existent stream, concurrency group, state pollution, hardcoded /opt path via symlink). Options 1 + 2 (fine-grained escape envs, pushed-commit evaluation) remain deferred as Phase B — pre-push + CI together cover the 99+% surface; revisit if a host-push-vector incident justifies. Source ship context: CoS msg 2026-04-23 19:39 UTC granting Captain autonomy + CTO directional pick. **Hotfix (commit `a78c9b4`, 2026-04-23 20:01 UTC):** First CI run (24855610921) failed 4/24 evals (EVAL-001/008/015/016 — all Redis-probe-after-hook-write). Root cause: pre-tool-use.sh + post-tool-use.sh parse `$REDIS_URL` (default `redis://redis:6379`), overriding the `$REDIS_HOST`/`$REDIS_PORT` the workflow set. Hooks' redis-cli then resolves the non-existent `redis` service hostname on the GH runner and silently fails. Fix: add `REDIS_URL=redis://127.0.0.1:6379` alongside REDIS_HOST/PORT in workflow env — both hook groups now hit the CI service container. Run 24856051819 on a78c9b4 **GREEN 2026-04-23 20:04 UTC — 24/24 evals pass**.
- **Prior status:** Proposed (Phase B — not blocking FW-025).
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
- **Status:** SUPERSEDED-BY-FW-041 2026-04-23 (commit `a057c77`). FW-041 Phase 1 widened the bypass scope from FW-030's single-flag `-C <dir>` case to the general flag-tolerant group `(-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*` covering `-C /path`, `-c cfg`, `--git-dir=...`, `-R owner/repo`, `--repo owner/repo`. Pinned by `/tmp/fw041-hook-test.sh` 22/22 PASS + EVAL-014 regex-structural pin. Originally Proposed 2026-04-21 (Sonnet adversary Finding #2 on FW-029).
- **Symptom:** FW-029's narrowed anchor `git[[:space:]]+push` requires literal `git` directly followed by whitespace then `push`. The `-C <dir>` directory-override flag intervenes, so `git -C /workspace/product push origin main` silently fails Phase 1 — Crew-review gate bypassed.
- **Resolution:** Covered by FW-041 Phase 1 (`pre-tool-use.sh:439/440`). No separate work needed.

### FW-032 — pre-tool-use.sh:80 whitelist filename substring amplification (spending-cap bypass)
- **Status:** SHIPPED 2026-04-21 — Phase A command-start anchor landed in commit `16b9c51` + EVAL-015 positive/negative matrix. Phase B scope gaps filed as FW-036 (bundled regex widen) + FW-037 (extractor fragility) + FW-038 (cross-hook wrapper class sweep) — all gated on operational data.
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
- **Status:** SHIPPED 2026-04-21 — Phase A command-start anchor (Bash + Write branches) landed in commit `7ed10e7` + EVAL-016 matrix. Phase B chaining/loop/inline-env scope gaps documented as addendum to FW-036; absolute-path launcher (`/usr/bin/git push`) filed as FW-036 #14; wrapper-class sweep filed as FW-038.
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
- **Status:** SHIPPED 2026-04-22/23 — Phase A target-correlation regex landed in commit `b6c7cf2`, HOTFIX-1 `37888dc` (COO + Sonnet adversary: 7 additional bugs folded), HOTFIX-2/3 `7f5b3ed` (COO 3rd-round + Sonnet post-fix: 3 more HIGH bypasses folded across 2 iterations — sed script-body class narrowed via `[^<]*` → `[^|&;]*` → `[^&;]*` → final `[^&]*` as each adversary surfaced another legit sed char-class, plus cp/mv -t/DIR no-space), HOTFIX-4 2026-04-23 (COO new HIGH: sed replacement-`&` bypass 7 forms + Sonnet pass-2 HIGH: `&&` inside quotes 6 forms + Sonnet pass-3 HIGH: escape-out idiom + quoted product path 5 forms — all folded via quote-aware class `([^&'"]|'[^']*'|"[^"]*"|'|"|&[^&])*` + `["']?/workspace/product/` anchor). EVAL-018 extended to 45 positive / 27 negative / CTO bypass = 73 checks, all PASS on hotfix-3 branch; hotfix-4 adds 30 new cases in `/tmp/fw034-hotfix4-tests.sh` (H1 7 + H2 6 + H3 5 + N 4 + B1 1 + R 7) all PASS.
- **Symptom:** `pre-tool-use.sh:321` blocks (`exit 2`) when CMD contains BOTH `/workspace/product/` AND write pattern (`>\s`, `sed -i `, `tee`, `cp .+ `, `mv .+ `). False-positive blocks `cat /workspace/product/README.md | tee /tmp/out.txt` — a read followed by tee-to-tmp is NOT a write to `/workspace/product/`, but substring match trips both patterns.
- **Blast radius:** MEDIUM (accuracy gap, fail-safe direction — over-blocks legitimate reads rather than under-blocking writes). Officer workflow friction; no control-bypass.
- **Shipped fix (Phase A v1, b6c7cf2):** Target-correlation regex replaces the two-substring AND. Each write operator now requires the product path as its destination (not just anywhere in the command). Covered: redirect (`>`/`>>`) with optional quote, `sed -i` + long flags, `tee` + long flags + multi-file, `cp`/`mv`/`rsync` + flags + end-of-arg anchor + optional quote on dest (both `'` and `"`), `patch` + stdin-read-pass. Sonnet adversary double-pass caught single-quote dest bypass (`cp /tmp/src '/workspace/product/dst'`) + no-space semicolon bypass (`cp /tmp/src /workspace/product/dst;echo ok`) — both folded pre-commit. False-positive classes (`cp -r /workspace/product/src /tmp/dst`, `patch < /workspace/product/old.patch`, multi-src cp with product as source) now pass cleanly.
- **Hotfix (37888dc) — 7 bugs from post-ship adversary:**
  - COO empirical harness on b6c7cf2 surfaced 3: HIGH #1 (`sed -n`/`-E`/`-e`/`-r` false-block — `-[-a-zA-Z]+` over-matched, broke officer read-analysis), HIGH #2 (`cp|mv|rsync -t DEST` + `--target-directory=DEST` silent bypass — dest-first form not caught), LOW #4 (`>|` force-redirect silent bypass). Defer: LOW #3 (quoted-dest-with-space) + MEDIUM #5 (install) → FW-040 Phase B.
  - Sonnet adversary on first-pass fix surfaced 4 HIGH: BUG-1 (`sed -i.bak` suffix not absorbed — `-[a-zA-Z]*i[a-zA-Z]*` required `[[:space:]]` right after `-i`, but `.bak` is non-space), BUG-2/3/4 (`cp -rfvt DEST` / `mv -bt DEST` / `cp -at DEST` bundle bypass — `-t` only standalone in first-pass).
  - Final regex: sed `-[a-zA-Z]*i[^[:space:]]*` (absorbs suffix), split old Pattern 5 into 5a (`cp|mv` with `-[a-zA-Z]*t` bundle) + 5b (`cp|mv|rsync` with `--target-directory=` long-form only). Rsync intentionally excluded from `-t` bundle because `rsync -t` = `--times` not target-directory — would false-block `rsync -rt SOURCE DEST` source-reads from `/workspace/product/`.
- **Hotfix-2/3 (commit 7f5b3ed) — 3 HIGH + 1 MEDIUM across 2 iterations (COO 3rd-round + Sonnet post-fix adversary):**
  - HIGH #1 (COO): sed script-body class `[^<]*` rejected `<` (HTML/XML bodies bypass like `sed -i 's/<h1>/<h2>/'`). First attempt `[^|&;]*` rejected `|` (valid sed delimiter bypass `sed -i 's|a|b|'`). Second attempt `[^&;]*` rejected `;` (Sonnet post-fix adversary: intra-script separator bypass `sed -i 's/a/b/;s/c/d/' f`). Final class `[^&]*` — allows `<`, `|`, `;` inside sed scripts, still flags `&&`/`||` command-chain boundaries via `&`. Downstream `[[:space:]]+/workspace/product/` anchor keeps the product-path write requirement.
  - HIGH #2 (COO): Pattern 5a `-[a-zA-Z]*t[[:space:]]+` required whitespace before path — GNU cp/mv accept `-t/DIR` no-space form (bundle-flag + attached-arg). Fixed: `[[:space:]]*`.
  - MEDIUM #3 (deferred → FW-040 addendum): sed `/pat/w PATH` + `/pat/W PATH` + `e cmd` internal-write directives (no `-i` required). Requires sed-script parsing; not hotfix scope.
- **Hotfix-4 (2026-04-23) — COO new HIGH + 2 Sonnet pass HIGH (sed `&` / `&&`-in-quotes / escape-out idiom / quoted product path):**
  - **NEW HIGH #1 (COO empirical on `7f5b3ed`):** sed replacement-`&` bypass. Class `[^&]*` over-rejects `&` globally, but `&` in sed replacement side is a sed literal meaning "the match" — not a shell chain. Bypass forms found (7): `sed 's/x/&/' -i /workspace/product/x`, `sed -i 's/foo/&bar/'`, `sed -i 's/foo/bar&/g'`, `sed -i "s/foo/&bar/"` (dquote), `sed -i '/&/d'` (address with `&`), `sed -Ei 's/x/&/'`, `sed -i.bak 's/x/&y/'`. All silently bypass write-gate. Proposed COO fix: `[^&]*` → `([^&]|&[^&])*`. We extended further to handle quote-absorption.
  - **Sonnet adversary pass-2 HIGH:** `&&` inside quotes. Class `([^&]|&[^&])*` halts at any `&&` regardless of quote context. But `sed -i 's/a/&&/'` has `&&` inside single-quoted sed script — sed literal meaning "match twice," not a shell chain. 6 forms: `sed -i 's/a/&&/'`, `sed -i 's/&&/x/'`, `sed -i -e 's/a/&&/'`, `sed -i '/&&/d'`, `sed -i 's/foo/&&&/'`, `sed -i "s/a/&&/"`. Fix: quote-balanced class absorbs `'...'` and `"..."` spans wholesale — `&&` inside quotes is consumed with the span, only unquoted `&&` (shell-chain boundary) halts the match.
  - **Sonnet adversary pass-3 HIGH (A2):** escape-out `'\''` idiom. Quote-balanced class `[^&'"]|'[^']*'|"[^"]*"` breaks on orphan unmatched `'` — valid shell pattern `sed -i 's/a/b'\''c/'` closes single quote mid-sed, inserts escaped single quote, reopens. Fix: add solo `|'|"|` fallback alternatives to class. Final class: `([^&'"]|'[^']*'|"[^"]*"|'|"|&[^&])*` — handles balanced quote spans AND orphan quotes.
  - **Sonnet adversary pass-3 HIGH (A6):** quoted product path. `sed -i 's/foo/&bar/' '/workspace/product/x'` — quote-balanced class absorbs `'/workspace/product/x'` as one balanced span, so downstream anchor `[[:space:]]+/workspace/product/` fails to match (path already consumed). Fix: extend anchor to `["']?/workspace/product/` (optional opening quote). Downstream still enforces product-path write requirement.
  - **Sonnet adversary pass-4 (convergence):** All known HIGH classes pinned; 1 MEDIUM probe P8 (variable expansion `T=/workspace/product; sed -i $T/x`) confirmed as pre-existing FW-040 Phase B gap (shell variable expansion not regex-parseable) — NOT a hotfix-4 regression.
  - **Empirical harness (`/tmp/fw034-hotfix4-tests.sh`):** 30 cases. H1 (7) COO sed-& variants + H2 (6) `&&`-in-quotes + H3 (5) quoted path / escape-out + N (4) sed-read-redirect + B1 (1) sed-product-&&-echo boundary + R (7) hotfix-3 regression. All 30 PASS.
  - **Regression validation:** hotfix-3 harness `/tmp/fw034-phase-a-hotfix-tests.sh` 49/49 PASS. Golden evals `run-golden-evals.sh` 22/22 PASS (EVAL-014 anchor pin switched from fixed-string to regex to survive FW-041 flag-tolerant insertion).
- **Phase B scope gaps:** filed as FW-040 (now 10+ gap classes: original 7 + COO's deferred quoted-dest-with-space + COO's install + other write tools `awk`/`dd`/`touch`/`mkdir`/`truncate`/`sqlite3` + `python3 -c` + `node -e` + sed internal-write directives `w`/`W`/`e` + Pattern 4 last-arg-is-dest violated by `cp -t DEST SOURCE...` ordering). Deferred pending Component selection (shell-parser vs allow-list vs fs-watcher audit vs incremental regex).
- **Realized effort:** L (~7h total — Phase A v1 + 5 adversary rounds (2 Sonnet pre-ship + COO empirical + Sonnet post-first-fix + COO 3rd-round + Sonnet post-second-fix) + 3 hotfixes + EVAL-018 extension from 22 → 73 checks + rsync `-rt` + sed HTML body + sed intra-script `;` regression guards).
- **Owner:** CTO (Phase A done). Phase B → FW-040.

### FW-035 — cosmetic amplifications (activity display + git-add gate stdout)
- **Status:** SHIPPED 2026-04-22 — Phase A committed + pushed (activity display anchored via shared `_ACT_PREFIX` across 5 verb branches; infra-gate anchored on `git[[:space:]]+add`; EVAL-017 pins both with matrices).
- **Symptom #1 (Finding #2):** `post-tool-use.sh:119-145` activity display string amplified on `pulls/N/merge` and `gh pr create` substring — wrong dashboard label for 5 min.
- **Symptom #2 (Finding #4):** `post-tool-use.sh:472` infrastructure-review gate echoed stdout warning on `git add` substring match — spurious warning inside officer session for commit bodies mentioning `git add`.
- **Blast radius:** LOW — cosmetic/ephemeral. No gate consumed, no trigger fired.
- **Phase A fix:** `head -n1` extraction + shared `_ACT_PREFIX` command-start anchor (priv-esc stack: sudo/env/timeout) interpolated into 5 verb branches; `bash/sh` launcher allowance on verify-deploy branch (canonical form per skill docs); trailing `([[:space:];]|$)` alignment across all branches. Infra gate gets dedicated command-start anchor. Both pinned by EVAL-017 (static presence + activity-display positive/negative matrix + infra-gate 7/7/1 positive/negative/heredoc matrices).
- **Adversary triage (Sonnet, 5 findings):** #1 `bash verify-deploy.sh` missed canonical form → FIXED INLINE; #3 trailing-boundary inconsistency → FIXED INLINE (aligned verify-deploy to `([[:space:];]|$)`); #4 EVAL coverage gap → FIXED INLINE (added activity-display matrix); #2 `curl POST /pulls` REST PR-create display drop → filed as FW-036 #15 (intentional narrowing, cosmetic regression); #5 chained-deploy (`pnpm run build && git push main`) → already tracked as FW-036 #10.
- **COO empirical post-ship review (62/62 CLEAN, 2026-04-22 00:18 UTC):** zero bugs, zero over-match, zero regressions. 3 new LOW-cosmetic scope-gaps filed as Phase B follow-ups:
  - **Phase B #1 — GET vs PUT narrowing on shipping-merge branch.** `curl https://api.github.com/repos/x/y/pulls/42/merge` (GET mergeable-inspection) fires shipping display. Fix: AND-predicate `-X[[:space:]]+PUT|--request[[:space:]]+PUT` to distinguish shipping from inspection. LOW cosmetic.
  - **Phase B #2 — Polyglot test-runner coverage.** `yarn test|bun test|jest|mocha|deno test|playwright test` all silence. Not a regression from v1 (prior substring also missed), but as the amplification-fix template matures, widen testing-branch stem to `(pnpm|npm|yarn|bun)` + `(vitest|tsc|eslint|jest|mocha|deno|playwright)`. LOW forward-looking.
  - **Phase B #3 — Non-origin remote on deploying-main branch.** `git push upstream main` silenced (requires `origin` literal or bare `main`). Fork-workflow friction. Widen to `(origin|upstream)[[:space:]]+` or drop the remote capture entirely. LOW cosmetic.
- **COO cross-hook confirmations:** absolute-path launcher class (FW-036 #13/#14) empirically reproduced on FW-035 branches 2 + 5. Wrapper class (FW-038) empirically reproduced on all 5 branches + infra gate. Confirms cross-hook scope correctness.
- **Effort:** XS-M (Phase A shipped; Phase B bundle when FW-036 Phase B runs).
- **Owner:** CTO.

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
  - **#13 Absolute-path launcher: `/usr/bin/bash /path/send-to-group.sh`, `/bin/sh /path/...`.** COO FW-032 Phase A empirical validation. `([^[:space:]]*/)?` prefix GREEDILY captures the absolute launcher path (`/usr/bin/`) instead of the optional script-path; remaining text then fails to match `bash ` at cursor because the cursor already advanced past it. Officers occasionally invoke via absolute paths for script-hardening / cron; whitelist fails → main-cap enforced.
  - **#14 Absolute-path launcher cross-hook (git/gh): `/usr/bin/git push origin main`, `/usr/local/bin/gh pr create`.** COO FW-033 Phase A empirical validation. Same root cause as #13 but applied to FW-033's `git[[:space:]]+push|gh[[:space:]]+pr[[:space:]]+create` stems — no optional path prefix before `git/gh`. Operational impact: experience-nudge missed on absolute-path invocations. Fail-safe direction (nudge is reminder, not gate).
  - **#15 `curl -X POST .../pulls` REST PR-create (activity display only).** FW-035 Sonnet Finding #2. Old activity-display pattern matched `/pulls"|/pulls ` (curl REST PR-create). FW-035 narrowed to `gh pr create` only. Cosmetic drop: officer sees "working" instead of "shipping" when creating a PR via curl REST. Scope limited to post-tool-use.sh:134 activity branch.
- **Decision on #10/#11/#12:** Accept as documented scope-gaps. Extending the anchor to cover chaining / loops / inline env would complicate the regex beyond maintainability benefit. Mitigation: officers split chained deploys into two Bash calls, or use the env builtin (`env VAR=value git push` matches).
- **Decision on #13/#14:** Folded into Phase B as cross-hook absolute-path launcher gap. Fix: allow `([^[:space:]]*/)?` to be OPTIONAL (already is) AND allow a subsequent `(bash|sh|git|gh)` stem WITHOUT the prefix being present — essentially a choice between "priv-esc stack + script-at-cursor" OR "absolute-path launcher + stem-at-path-tail". Mitigation today: officers invoke via PATH-resolved form (no absolute launcher) OR use the whitelist-aware wrapper. Bounded operational friction, no security bypass.
- **Decision on #15:** Accept as cosmetic regression. Officers rarely create PRs via curl REST (they use `gh pr create`). Re-introducing `/pulls"|/pulls ` without command-start anchoring would re-amplify on commit bodies mentioning `/pulls`. If restoration is desired, narrow to `_ACT_PREFIX(curl|wget)[[:space:]]` AND `/pulls"?$`.
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

### FW-038 — cross-hook prefix-wrapper class sweep (nohup / exec / stdbuf / subshell / brace / pipe-first)
- **Status:** SECURITY-CRITICAL PATHS CLOSED 2026-04-24 via FW-045/FW-041/FW-043/FW-051 ship chain (empirically verified by CTO). Layer 1 + CI Green + Section 3b all block wrapper forms today. Nudge/display anchors (FW-028/032/033/035 cosmetic branches) still have the gap but are fail-safe direction — deferred pending operational data.
- **Empirical verification 2026-04-24 (CTO, live hook invocation):** 9/9 wrapper bypass forms return exit=2 (BLOCKED) on current `pre-tool-use.sh`:
  - `nohup git push origin main` → BLOCK ✓
  - `exec git push origin main` → BLOCK ✓
  - `stdbuf -oL git push origin main` → BLOCK ✓
  - `nohup gh api pulls/42/merge` → BLOCK ✓ (Section 7 CI Green)
  - `exec gh api pulls/42/merge` → BLOCK ✓
  - `nohup gh api -X DELETE repos/O/R/git/refs/heads/main` → BLOCK ✓
  - `(git push origin main)` → BLOCK ✓ (subshell)
  - `{ git push origin main; }` → BLOCK ✓ (brace group)
  - `true | git push origin main` → BLOCK ✓ (pipe-first)
- **What shipped the close:** FW-045 hotfix-6/7 wrapper-class coverage in Layer 1 Phase 2 (commit bb...), FW-041 flag-tolerant group widening, FW-043 statement-boundary anchors, FW-051 triple-scan architecture (RAW + CMD_L1_NORM + HAS_SPLICE CMD_L1_UNQUOTED) all combined to catch wrapper-prefixed pushes via at least one of the three scan passes.
- **Context:** The FW-028/029/032/033/035 anchor family (`_ACT_PREFIX` + command-start) has a consistent cross-cut gap: command WRAPPERS that precede the target stem silence every anchor. COO observed this while validating FW-033 Phase A; same class applies to all four hooks.
- **Wrapper forms that silence all anchors:**
  - `nohup git push origin main` (nohup wrapper)
  - `exec git push origin main` (exec replace)
  - `stdbuf -oL git push origin main` (stdbuf wrapper — GNU coreutils)
  - `(git push origin main)` (subshell)
  - `{ git push origin main; }` (brace group)
  - `true | git push origin main` (pipe-first)
- **Root cause:** `_ACT_PREFIX` covers `sudo`/`env`/`timeout` as the universal priv-esc stack but omits the broader "command wrapper" class. Wrappers rearrange the execution tree without being a variable assignment or priv-esc step, so we skipped them at initial scope. Consistent gap across FW-028 (auto-deploy detector), FW-029 (Layer 1 + CI Green gate), FW-032 (telegram whitelist), FW-033 (experience nudge), FW-035 (activity display + infra gate).
- **Blast radius:** Mixed. Fail-safe for nudge/display (reminder not gate). Fail-safe for whitelist (main-cap enforced). **Was fail-OPEN for Layer 1 + CI Green** — now CLOSED via FW-045/FW-041/FW-043/FW-051 chain (verified 2026-04-24).
- **Proposed fix (Phase B):** Prepend a generic wrapper-class to `_ACT_PREFIX`:
  ```
  _WRAP_PREFIX='^[[:space:]]*(nohup[[:space:]]+|exec[[:space:]]+|stdbuf[[:space:]]+(-[a-zA-Z][[:space:]]*[a-zA-Z]+[[:space:]]+)*)?'
  ```
  Apply `${_WRAP_PREFIX}${_ACT_PREFIX}` as the new universal prefix across all 5 hooks. Brace/subshell/pipe-first NOT covered — those require multiline-aware regex; document as residual scope-gap.
- **Eval coverage:** Add one positive per wrapper form to each of EVAL-011, 013, 014, 015, 016, 017.
- **Pin in EVAL family:** Promote `_WRAP_PREFIX` to a shared library constant (`cabinet/scripts/lib/anchor-prefixes.sh`?) so all 5 hooks can source the same prefix — single-point-of-truth avoids drift.
- **Effort:** M (~1h: regex widen across 5 hooks + eval cases + optional library extraction).
- **Owner:** CTO when operational data shows wrapper usage OR when bundling with FW-036 Phase B.

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

### FW-039 — Library migration infra (bulk markdown import + write-path hook retargeting)
- **Status:** SCOPE LOCKED 2026-04-22 — entry filed in commit `4ff80b1`; COO adversary 5 AC pins folded in commit `be29da9` (v3.2 absorption); Spec 037 v3.2 cites LANDED. Phase A IMPLEMENTATION gated on Spec 037 Captain Q1-Q5 final-ack (CoS routing at 07:00 CEST handoff); CPO standdown 2026-04-22 01:10 UTC confirmed AC-6 env-var vs advisory-lock split coherent with Spec 037 AC #24 (no drift).
- **Why HARD PREREQ:** Spec 037 (Library Notion/Obsidian UX) Phase A depends on every shared/interfaces and instance/memory/tier2 artifact being resolvable via `kb_records` at day-1. Without bulk import, `library_get_record` / section-anchor resolution / status-filter views all return empty for pre-migration prose. Without write-path retargeting, every live edit to shared/backlog.md, captain-decisions.md, experience-records/*.md writes only to the repo and leaves Library drifting — defeats the single-source-of-truth goal.
- **Components:**
  1. **fs-walk bulk importer** — reads `shared/`, `instance/memory/tier2/<officer>/`, and designated repo paths. Frontmatter extraction, auto-derived `space` from path, populates `kb_records` + `library_record_links` + `library_record_sections` + `kb_records.status` in one transactional pass per record. Uses `github-slugger` to derive `section_slug` values matching rehype-slug output (Spec 037 A6).
  2. **Write-path hook retargeting** — `captain-decisions.md` append → `library_update_record` MCP; `shared/backlog.md` + `shared/cabinet-framework-backlog.md` touches → `library_update_record`; `experience-records/*.md` appendFile → `library_update_record`. Hook lives in `post-tool-use.sh` (new branch) or dedicated `write-retarget.sh` sourced by post-tool-use. Single-writer discipline: the repo-write path no longer mutates the file directly; the MCP call writes DB + regenerates the repo file from DB truth.
  3. **Migration lock gate** — importer refuses to run (`exit 1` with guidance) without a `pre-library-migration-<YYYY-MM-DD>` git tag on the repo HEAD. Pre-state snapshot guarantee: if migration aborts mid-pass, the tag is the only recovery lever (§7 HARD CONSTRAINT).
  4. **In-flight write quarantine** — during the bulk pass, either (a) pause hook retargeting (hook no-ops, writes go to repo as today) OR (b) DB-level advisory lock (`pg_advisory_lock(<migration_tag_hash>)`) so the importer's transaction snapshot is coherent. Required to prevent mid-migration officer writes from being clobbered by the re-import pass.
- **ACs (day-1):**
  - AC-1: Importer populates `kb_records` + `library_record_links` + `library_record_sections` + `kb_records.status` atomically per record.
  - AC-2: Importer refuses to run without `pre-library-migration-<YYYY-MM-DD>` tag on HEAD; error message names the exact tag command to create it.
  - AC-3: `kb_records.status` heuristic: `/shared/interfaces/product-specs/*` → `implemented` if referenced in captain-decisions.md as "shipped"/"merged"/"landed", else `approved`; `shared/interfaces/captain-decisions.md` entries → `approved`; everything else → `draft`. Backfill runs on pre-existing kb_records rows too — zero rows remain with `status='draft'` where `context_slug` matches a known promoted path.
  - AC-4: All `*-review-tracker.md` files under `instance/memory/tier2/<officer>/` migrate as `research-brief` records in a new `Reviews` space. Status rule: `approved` on final consolidation passes, `draft` on in-flight trackers (detected by frontmatter `status:` field or `## Summary verdict` presence).
  - AC-5: Write-path retargeting lands post-bulk-pass (not concurrent). The post-tool-use MCP-tool-call branch detects **all three write verbs** — `mcp__library__library_create_record`, `mcp__library__library_update_record`, AND `mcp__library__library_delete_record` (widened per COO Minor #4: post-migration officer creates/deletes go through create/delete, not update; single-verb detection would lose FW-033 parity). Fires the same experience-nudge / captain-decision / cross-validation branches that the Write-tool branch already fires for `shared/interfaces/product-specs/`, `shared/interfaces/research-briefs/`, `shared/interfaces/deployment-status/` — i.e., Spec 037 retargeting must NOT lose FW-033 Write-branch detector coverage. Pin as EVAL case: each of the three MCP verbs against a pre-migration-tracked path fires the same nudge as the pre-migration Write tool call.
  - AC-6: In-flight quarantine via authoritative advisory-lock path (per COO Sub-blocker #2):
    - `pg_advisory_lock(<migration_tag_hash>)` is the **FIRST SQL** inside the importer transaction, BEFORE any SELECT/INSERT/UPDATE. Closes the race where two operators both pass the CLI git-tag check and begin fs-walk concurrently.
    - **Post-lock tag re-verify:** immediately after acquiring the lock, importer re-runs `git rev-parse pre-library-migration-<YYYY-MM-DD>` — aborts with non-zero exit + structured error if the tag was deleted between CLI check and lock acquisition.
    - MCP write calls (`library_create_record` / `library_update_record` / `library_delete_record`) block on the advisory lock up to a **30s hard timeout**. Beyond that the call returns `{error: 'migration_in_progress', retry_after_seconds: <est>}` (HTTP 503) so officer clients can retry cleanly. Matches the AC-6 pattern established in Spec 037 AC #24 for the PATCH-status endpoint.
    - **Advisory-lock path is authoritative in production.** The env-var toggle `LIBRARY_MIGRATION_IN_PROGRESS=1` is a documentation signal only — not a parallel gate that can diverge from the lock state (per COO Minor #7; dual-gate would fork state).
    - Importer releases the lock + clears the env on completion OR on abort.
  - AC-7: Rollback semantics — explicitly **"delete-new + forward-idempotent-on-retry", NOT full state-restore** (per COO Sub-blocker #3; Captain ack required on these semantics before first migration run):
    - **DELETE-NEW:** migration-abort script deletes `kb_records` / `library_record_links` / `library_record_sections` rows written during the current pass (keyed on `created_at >= <migration_start_ts>`). Releases advisory lock, clears `LIBRARY_MIGRATION_IN_PROGRESS`.
    - **FORWARD-IDEMPOTENT:** pre-existing `kb_records` rows UPDATEd by the backfill (AC-3 status heuristic, Spec 037 AC #23 `author_officer` derivation) are NOT reverted. On retry, the same UPDATE runs idempotently to the same values (heuristic is deterministic per row, so repeat produces identical output).
    - **TRUE ROLLBACK LEVER:** the pre-migration git tag + git archive (§7 HARD CONSTRAINT) is the only mechanism to restore pre-backfill state. Partial-rollback-via-AC-7 is a re-entry gate only, NOT a full rewind.
    - Repo files untouched by design (importer is READ-ONLY on repo side).
- **Blast radius:** HIGH. Irreversible repo → DB content move if the repo-delete step is included in Phase A (TBD — Spec 037 v3 §7 likely keeps repo files as dual-source for safety, DB-only cutover gated on day-N operational data). Pre-state git tag is the only rescue lever either way.
- **Effort:** L (~6-10h: importer + hook retargeting + tests + dry-run documentation + rollback script + quarantine toggle + 2 EVAL cases minimum).
- **Dependencies:**
  - Spec 037 Phase A schema (kb_records.status column, library_record_sections table) must land before AC-1 can be tested end-to-end.
  - FW-024 (Dockerfile.officer Python deps for ETL) unrelated — that's Spec 039. Spec 037 v3 will renumber its prereq citation from FW-024 → FW-039.
- **Owner:** CTO (implementation), gated on CPO Spec 037 v3 sign-off + CoS schedule (coordinates with migration lock-tag creation, officer-session quiesce window for cutover).
- **Follow-up tracking:**
  - MCP-branch-detector companion work rolled into AC-5 above (not separate FW-###).
  - If wrapper-class drift (FW-038) lands mid-migration, the LIBRARY_MIGRATION_IN_PROGRESS env-var gate needs a wrapper-safe anchor too.
  - **Runbook pin (per COO Minor #8):** Phase A schema DDL (`ALTER TABLE kb_records ADD COLUMN ...` for status + author_officer; `CREATE INDEX ...`; `DROP COLUMN library_record_sections.position` per COO confirmatory) runs **INSIDE** the `LIBRARY_MIGRATION_IN_PROGRESS=1` quarantine window. Officer writes during DDL would HANG on ACCESS EXCLUSIVE lock; quarantine prevents officer MCP writes while DDL is in-flight. Documented in the FW-039 migration runbook (not an AC — runbook-level concern).
- **Source:** Spec 037 v2 CTO tech addendum 2026-04-22 + CPO ACK trigger 2026-04-22 00:22 UTC (msg 1776817374767-0) + 5 AC pins folded from COO adversary via CPO trigger 2026-04-22 00:45 UTC (msg 1776818735782-0, Spec 037 v3.2 absorption).

### FW-040 — FW-034 Bash write-gate Phase B: shell-parse-aware coverage
- **Status:** Proposed 2026-04-22 (CTO Sonnet adversary Phase B scope gaps, filed after FW-034 Phase A inline fixes landed 2026-04-22). **Hotfix 5 (perl -i + tar -C/-f) SHIPPED 2026-04-24** — Pattern 8 (perl -i inplace-edit) and Pattern 9 (tar -C/--directory + tar -f write to product) added to write-gate regex. Adversary Pass-1 (CTO Sonnet crew agent): found HIGH bypass B2 (`tar -C/PATH` no-space form valid in GNU tar; -C[[:space:]]+ was too narrow) + MEDIUM A7 (quoted "perl" splice class, deferred FW-051 consistent) + FALSE POSITIVE B1 (--directory/PATH not valid tar syntax). B2 fix applied (-C[[:space:]]* to allow zero-space form). Harness: 48/48 PASS. Regression sweep: 0 new failures across fw034/fw041/fw042/fw043/fw044/fw045 harnesses (4 pre-existing FPs in fw043 + fw044 are heredoc/commit-msg class, not write-gate). **Hotfix 6 SHIPPED 2026-04-24** — COO empirical Pass-1 adversary on d752992 found 3 HIGH Pattern 9b bypasses (GNU tar `--file=` long-form missing, parallel to Pattern 9a's `--directory=` alt) + 2 MEDIUM Pattern 8 FPs (`perl -I/usr/local/lib` include path FP-blocked because `[^[:space:]]*i` absorbed `I/usr/local/l` and matched `i` in `lib`). Fix Pass-1: Pattern 8 flag class narrowed to `(-[a-z]*i[^[:space:]]*|--in-place(=[^[:space:]]*)?)` (lowercase-only prefix rejects capital `-I`); Pattern 9b added `--file[=[:space:]]+` alt. Sonnet Pass-2 adversary caught lowercase-only regression: `-[a-z]*` dropped uppercase-prefixed bundles (`-Ti` taint+inplace, `-Wi` warnings-all+inplace — both valid perl bundles) + digit-prefixed `-0777i.bak` (slurp+inplace, well-known idiom). Fix Pass-2: re-widened to `-[^[:space:]Ii]*i[^[:space:]]*` — excludes ONLY the FP-causing `I` char + `i` itself (since `i` terminates the prefix), preserving original coverage AND the `-I` FP fix. Semantic correctness: `-I` is the unique include-path flag; no other perl flag starts with `I`, so excluding it specifically is precise. Restores coverage for `-Ti`, `-Wi`, `-0777i`, `-li`, `-wi`, `-si`, `-ai` etc. 1 LOW scope-gap deferred to FW-040 Phase B (not FW-051): `perl -e 'BEGIN{$^I="…"}…' /workspace/product/f` (inplace enabled via special-var inside `-e` body — same class as existing FW-040 gap #3 "Scripting inline-writes via python3 -c / node -e / ruby -e"; flag-level regex can't see body; low ops risk, Edit/Write still gated). 2 LOW tar-read FPs (`tar -tf/-xf` from product archive) remain accepted fail-closed (workaround: copy to /tmp first). Harness: hotfix-6 v2 verify 28/28 (Sonnet findings S2-F1a/F1b/F2 all BLOCK; 5 `-I` FPs all ALLOW; 12-case Pattern 8 regression including new `-wi/-li/-si/-ai` coverage; Pattern 9b short+long form; Pattern 9a regression). Hotfix-5 regression: 25/26 (1 pre-existing FW-045 FP-1 echo-body). FW-044 Pass-3 spot-check clean.
- **Why:** FW-034 Phase A regex covers the common shell forms for /workspace/product/ writes (redirect `>`/`>>`, `sed -i`, `tee`, `cp`/`mv`/`rsync`, `patch`) with target-position correlation, long-flag support, double-and-single-quote awareness, and end-of-dest anchoring (passes 24 positive + 18 negative + CTO bypass eval cases). Known gaps remain that a shell-parser-level solution would close but regex cannot:
- **Known gaps (Phase B scope):**
  1. **Variable expansion false-negative** — `DEST=/workspace/product/x; cp src "$DEST"` bypasses because the cp command line doesn't literally contain `/workspace/product/`. Regex has no env var tracking.
  2. **Quoted-string literal false-positive** — `echo "text > /workspace/product/x" > /tmp/y` false-blocks because regex treats the `>` inside the echo string as a real redirect. Common with commit messages, docs, error messages referencing product paths.
  3. **Scripting inline-writes (HIGH)** — `python3 -c 'open("/workspace/product/x","w").write(...)'`, `node -e 'fs.writeFileSync("/workspace/product/x", ...)'`, `ruby -e`. Bypasses entirely; regex can't inspect inline program semantics. **Addendum 2026-04-24 (FW-040 hotfix-6 Sonnet Pass-2):** `perl -e 'BEGIN{$^I=".bak"} ... ' /workspace/product/f` — perl inplace enabled via `$^I` special-variable inside `-e` body, no `-i` flag at shell level. Same class (inline program body inspection). LOW ops risk (obscure idiom); Edit/Write tools still gated for non-CTO officers.
  4. **Additional write tools** — `awk '{print > "/workspace/product/x"}' file`, `dd of=/workspace/product/x`, `touch /workspace/product/x`, `mkdir /workspace/product/newdir`, `truncate /workspace/product/x`, `sqlite3 /workspace/product/x.db ".save..."`. All bypass current Phase A regex.
  4a. **COO adversary addendum 2026-04-24 (6 write-tool classes not in existing Phase B list):**
    - **perl -i / perl -e (HIGH)**: `perl -i -pe 's/x/y/' /workspace/product/src/file.ts` — inplace edit, directly modifies file. `perl -e 'open(F,">","/workspace/product/x"); print F "…"'` — arbitrary open+write via inline program. Severity HIGH per COO (hotfix consideration warranted; perl is ubiquitous on dev envs).
    - **tar -xf -C / tar --directory= (HIGH)**: `tar -xf archive.tar -C /workspace/product/` — extracts archive content into product tree. `tar -xf archive.tar --directory /workspace/product/src/`. Bypasses Phase A regex entirely (no `>`/`sed -i`/`tee`/`cp`/`mv`/`rsync`/`patch` token). Severity HIGH per COO (hotfix consideration; archive-extraction over-writes arbitrary file set).
    - **gawk -i inplace (MEDIUM)**: `gawk -i inplace '{gsub(/x/,"y")} 1' /workspace/product/x` — gawk has an `-i inplace` extension that edits files in-place. Uses extension file include so grep for `-i` + `inplace` needed. Severity MEDIUM.
    - **ruby -i (MEDIUM)**: `ruby -i -pe 'gsub(/x/,"y")' /workspace/product/x` — inplace edit via `-i` flag (identical to perl). Severity MEDIUM.
    - **ln -sf (MEDIUM)**: `ln -sf /etc/passwd /workspace/product/passwd.md` — force-symlink variant of #5 below. Covered separately because `-sf` bundle is a common single-flag idiom; current regex would miss both `-s` and `-sf`. Severity MEDIUM.
    - **ex -s -c (LOW)**: `ex -s -c 'g/pat/d|x' /workspace/product/x` — vim's scripting mode, edits file + `:x` writes. Severity LOW (rarely used).
  5. **`ln -s` symlink attack (HIGH)** — `ln -s /etc/passwd /workspace/product/passwd.md` creates an in-repo symlink to arbitrary system files. Not a write to product content but does surface protected content through product repo. Worth blocking.
  6. **Subshell / process-substitution / heredoc** — `(cp src /workspace/product/dst)`, `$(cp src /workspace/product/dst)`, `cat <<EOF > /workspace/product/x`. Subshell currently blocks via substring serendipity; process-sub and heredoc do not.
  7. **Backtick and `eval`** — `eval "cp src /workspace/product/dst"`, `` `cp src /workspace/product/dst` ``. Bypass entirely.
  8. **sed internal-write directives** — `sed '/pat/w /workspace/product/x' /tmp/input`, `sed '/pat/W /workspace/product/x'`, `sed 'e cmd'`. `w`/`W` write matched lines to a file specified inside the sed script (no `-i` flag required); `e` executes arbitrary shell. Pre-hotfix-3 regex requires `-i`/`--in-place`, misses these. Requires sed script parsing. Source: COO 3rd-round adversary MEDIUM #3 on FW-034 hotfix 37888dc.
  9. **Pattern 4 last-arg-is-dest violated by `-t DEST SOURCE...` ordering** — `cp -at /tmp/dst /workspace/product/` where `-t /tmp/dst` is the real target and `/workspace/product/` is the source. Pattern 4 (cp/mv/rsync general alt) assumes last positional arg is dest, false-blocks this read. Would require Pattern 4 to detect `-t DEST` upstream and short-circuit. Source: CTO discovery during hotfix-3 guard-test authoring 2026-04-22.
- **Components (options — pick one at design time):**
  1. **Shell-parser-aware hook** — swap regex for a bash lexer (bashlex Python lib or shellcheck lib via subprocess). Cost: +50-200ms per Bash call × hook fires on every command. Offset: 99% coverage.
  2. **Allow-list instead of block-list** — invert: officers can run any command unless it writes outside known-safe targets (/tmp/, /opt/founders-cabinet/, officer home). Requires explicit path-arg classification for every command. Higher false-positive ceiling but eliminates bypass class entirely. Would also block officer tooling writes to cabinet/scripts/ — needs careful scoping.
  3. **Post-hoc audit via fs-watcher** — accept some latency between hook-block and actual detection. Inotify watcher on /workspace/product/ writes; any non-CTO write emits alert + rollback. Loses pre-write blocking guarantee.
  4. **Incremental regex hardening** — add patterns for python3 -c / node -e / awk / dd / touch / mkdir / ln -s / truncate / sqlite3 / eval. Does not close variable-expansion or quoted-string classes. Low-cost first-pass improvement.
- **ACs (Phase B, pick-one-scoped):**
  - AC-1: Add EVAL-018 cases for every Phase B gap (variable expansion, quoted-string literal, python3 -c, node -e, awk print>, dd of=, touch, mkdir, ln -s, subshell, process-sub, eval) with expected behavior pinned per chosen Component.
  - AC-2: Chosen Component produces zero regression on existing 24 positive + 18 negative + CTO bypass cases.
  - AC-3: Hook latency measured before/after; if shell-parser path chosen, latency budget < 300ms per Bash call.
  - AC-4: Migration path from Phase A regex documented — if allow-list chosen, per-officer permitted-write-path config lands before regex retirement.
- **Blast radius:** MEDIUM. Phase A is net-positive vs pre-FW-034; gaps are exploitable but require officer deliberately bypassing (threat model is accidental writes, not malicious bypass). Each Component option has tradeoffs — shell-parser is highest-confidence, allow-list is most bulletproof but invasive, post-hoc audit loses pre-block, incremental hardening leaves classes open.
- **Effort:** M (~3-6h for Component 4 incremental hardening) / L (~8-12h for Component 1 shell-parser) / XL (~20h+ for Component 2 allow-list with per-officer config migration).
- **Dependencies:**
  - Phase A (FW-034) landed 2026-04-22 as prerequisite baseline.
  - Component 2 (allow-list) requires audit of every officer's cabinet/scripts/ write history to derive permitted-path set — couples to FW-007 officer-capability audit work.
- **Owner:** CTO (implementation + Component selection), defers to COO adversary before commit per standing review discipline.
- **Source:** CTO Sonnet adversary round 1 (2026-04-22 pre-FW-034 Phase A commit, 15 findings × 3-way triage) + round 2 (2026-04-22 post-Phase-A-v2 regex: single-quote dest + no-space-semicolon bypasses found, both folded into Phase A). Phase B is the explicitly deferred remainder. 2026-04-24 COO adversary addendum added 6 write-tool classes (#4a) not previously named — perl -i + tar -xf -C warrant hotfix consideration per COO severity rating.

### FW-041 — FW-029 Layer 1 Phase 1 anchor: `git -C` / `gh -R` global-flag bypass (HIGH)
- **Status:** SHIPPED 2026-04-23 Phase 1. Known MEDIUM scope-gap (quoted-space flag value) filed as FW-041 Phase 2 below. Originally Proposed 2026-04-22 (CTO Sonnet background audit of all hook-surface regexes against FW-034 Rule 4 class, same pre-tool-use.sh file).
- **Symptom:** FW-029 Phase 1 anchor at `pre-tool-use.sh:~411` is `^[[:space:]]*(sudo[[:space:]]+|env[[:space:]]+...+|timeout[[:space:]]+...+)*(git[[:space:]]+push|gh[[:space:]]+pr|gh[[:space:]]+api|curl[[:space:]])`. The anchor requires the subcommand (`push`/`pr`/`api`) to appear **immediately** after `git[[:space:]]+` or `gh[[:space:]]+`. But `git -C /path push origin main` inserts `-C /path ` between `git` and `push`; `gh -R owner/repo pr merge N` and `gh --repo owner/repo pr merge N` insert a global flag between `gh` and `pr`. All three forms bypass Phase 1 entirely.
- **Empirical reproduction:**
  - `git -C /workspace/product push origin main` → Phase 1 NO_MATCH → Layer 1 gate not consulted → push proceeds without `cabinet:layer1:cto:reviewed` flag check.
  - `gh -R nate-step/captains-cabinet pr merge 999` → Phase 1 NO_MATCH → CI Green gate also bypassed.
  - `gh --repo nate-step/captains-cabinet pr merge 999` → same bypass.
- **Blast radius:** HIGH. Same class as FW-034 Rule 4 (flag bundle bypass). Layer 1 (review flag enforcement) + CI Green gate (pulls/N/merge block) both rely on Phase 1. A CTO using the idiomatic `-C`/`-R` forms while cd'd elsewhere skips both gates without warning. Fail-open direction — the gate is silently not consulted, not a stderr-on-reject case.
- **Attack patterns pinned by audit:**
  - `git -C /some/path push origin main`
  - `git -C /workspace/product push origin master`
  - `gh -R owner/repo pr merge 123`
  - `gh --repo owner/repo pr merge 123`
  - (FW-033 nudge anchor D1 + FW-035 activity D4 share the same class as BUG-4 + BUG-6 in audit — all LOW cosmetic from same pattern family, folded separately into FW-036.)
- **Proposed fix (Phase A, small):** Extend Phase 1 priv-esc-and-subcommand group to accept global-flag prefixes between `git`/`gh` and the subcommand verb:
  - Current: `(git[[:space:]]+push|gh[[:space:]]+pr|gh[[:space:]]+api|curl[[:space:]])`
  - Proposed: `(git[[:space:]]+(-[A-Za-z][^[:space:]]*[[:space:]]+[^[:space:]]+[[:space:]]+)?push|gh[[:space:]]+((-[A-Za-z]|--[A-Za-z][^[:space:]]+)[[:space:]]+[^[:space:]]+[[:space:]]+)?(pr|api)|curl[[:space:]])`
  - Must NOT accept arbitrary args between `git` and `push` — only a single `-FLAG VALUE` pair (global-flag convention). Prevents bypass via `git push --force main` matching a multi-flag prefix and swallowing the real intent.
- **ACs:**
  - AC-1: Empirical regression harness pins the 3 bypass forms + priv-esc variants (`sudo git -C /path push ...`, `env VAR=1 gh -R ... pr merge ...`) as Phase 1 MATCH.
  - AC-2: Existing Phase 1 positives (bare `git push origin main`, `gh pr merge N`) still match.
  - AC-3: Non-gate forms (`git status`, `git log -p`, `gh repo view`) remain NO_MATCH (no false-positive on Phase 1).
  - AC-4: EVAL-014 extended with the 3 bypass forms as positive + the 3 non-gate forms as negative.
  - AC-5: Adversary round (Sonnet + COO empirical) before commit — per feedback_security_regex_authoring memory (≥2 passes mandatory).
- **Blast-radius reasoning:** Unlike FW-034 (which fails closed — over-blocks reads), this is fail-open — under-blocks real writes. More severe. HIGH priority; hotfix within 24h of merge to this session.
- **Effort:** S (~1-2h — regex surgery, evals, 2 adversary rounds, commit).
- **Owner:** CTO.
- **Source:** CTO Sonnet background audit (2026-04-22) applying FW-034 Rules 1-5 retrospectively to hook regex surface. Finding BUG-1/HIGH in audit report `a687dbfce166e50e7`. Audit also surfaced 5 LOW findings (BUG-2/3/4/5/6) — all folded into FW-036 Phase B as same-class cosmetic amplifications.
- **Phase 1 ship notes (2026-04-23):** Implemented flag-tolerant group `(-[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?[[:space:]]+)*` between tool (`git`/`gh`) and subcommand at BOTH Phase 1 anchor (line 439) AND Phase 2 action regex (line 440) in `pre-tool-use.sh`. Bare `-FLAG` (single token, e.g., `--git-dir=/path`) OR `-FLAG VALUE` pair (e.g., `-C /path`, `-R owner/repo`). Also narrowed `gh` subcommand from `(pr|api)` to `(pr[[:space:]]+merge|api)` — broad `pr` alternation false-positived every read (`gh pr view/list/checkout/status/diff`). EVAL-014 pin switched from fixed-string `git[[:space:]]+push` to regex `git\[\[:space:\]\]\+.*push` + anchor detection regex `[^']*pr[^']*merge` (survives flag-tolerant insertion; structural pin, not literal). 4 adversary passes clean (1 pre-implement + 3 post-implement Sonnet). Empirical harness `/tmp/fw041-hook-test.sh` 22/22 PASS: 5 bypass (`git -C ... push main`, `git -c ... push main`, `git --git-dir= push main`, `gh -R ... pr merge`, `gh --repo ... pr merge`) all exit=2; 4 preserved positives; 4 preserved negatives; 6 FP regression (all `gh pr` read subcommands exit=0); 2 mixed (non-main branch exit=0); 1 ACK path (after `cabinet:layer1:cto:reviewed` + `ci-green` set → exit=0).

### FW-041 Phase 2 — quoted-space flag value bypass (MEDIUM)
- **Status:** SHIPPED 2026-04-23 (CTO empirical adversary Pass-1 on FW-041 Phase 1 ship — bypass confirmed on lines 606/607/627; Sonnet adversary Pass-2 on fix draft, 0 new bypasses, 0 new FPs). **Hotfix-4 2026-04-24** (commit `daa30c4`): d752992 "FW-040 Hotfix 5" silently reverted ff11e85's escape-aware rich flag-value atom back to plain exclusive-alternation as part of a VAR_ASSIGN widening; 3 HIGH attack forms (ANSI-C path, SQ-embed-after-eq, DQ-embed-after-eq) silently bypassed live gate for ~24h. Fix restored ff11e85's rich chain-of-atoms at all 21 occurrences across 4 gate regex lines (L1 Phase 1/2a/2b + CI Green Phase 1). Preflight 27/27 PASS, live 27/27 PASS, golden 24/24 PASS. Sonnet adversary Pass-1+2: 0 bugs, 0 new FPs, BONUS `$"..."` coverage. **COO Pass-3 SHIP-CLEAN 2026-04-24** (`/tmp/fw041-hf4-coo-pass3.sh` 31 probes): 3 HF4 HIGH + 5 HF2 regression + 8 NEW adversary extensions (ANSI-C-in-DQ, multi-`-c` chain, `-C`+`-c` fusion, escape-in-ANSI-C, env+git+-c, gh -H quoted, nohup-wrapped, env+gh api DELETE) all BLOCK; 11 FP + 4 FP-adversary all PASS. Cumulative FW-041 adversary rounds: 5. EVAL-014 regression pins expanded to 16 new positives (HF2-A1/A2/A3 + HF2-B1/B2 + HF4-C1/C2/C3 + 8 COO-Pass-3) + 9 new FP guards (5 hotfix-4 + 4 COO-Pass-3). Gotcha memorialized: widening one atom requires `git show` of all predecessor hotfixes touching same regex.
- **Symptom:** FW-041 Phase 1 flag-tolerant group `[^[:space:]]+([[:space:]]+[^-][^[:space:]]*)?` accepts only UNQUOTED flag values. Bypass form: `git -c 'user.name=val with space' push origin main` OR `git -c "x=y z" push origin main`. The single/double-quoted value contains space, Phase 1 group can't parse through the quoted span, anchor fails to include `push`, gate bypassed.
- **Empirical reproduction (CONFIRMED on `002ffe8`):** `/tmp/fw041-phase2-verify.sh` against pre-fix hook: 3 of 4 claimed bypass forms returned exit=0 (gate silent) instead of exit=2. Specifically: `git -c 'user.name=val with space' push origin main`, `git -c "x.y=val with space" push origin main`, `git -c user.email=a@b -c 'user.name=val space' push origin main`. `gh -R 'nate-step/captains-cabinet' pr merge 999` already gated due to non-space dash elsewhere — false positive in initial claim.
- **Blast radius:** MEDIUM (fail-open like Phase 1, but attack requires specifically crafting a multi-token config value with embedded space; officers rarely use quoted-space config values in git push). Lower frequency than FW-041 Phase 1 bypass class.
- **Fix:** Extended flag-tolerant group value-token to 3 alternatives — unquoted `[^-][^[:space:]]*` | single-quoted `'[^']*'` | double-quoted `"[^"]*"` — on lines 606/607/627 only. Comment lines 497/535 left intact.
- **ACs:**
  - AC-1: `git -c 'user.name=val with space' push origin main` → exit=2. **PASS.**
  - AC-2: `git -c "name=val space" push origin main` → exit=2. **PASS.**
  - AC-3: Existing Phase 1 positives/negatives still behave correctly (regression guard). **PASS — 22/22.**
- **Regression/adversary pins:** `/tmp/fw041-phase2-verify.sh` 7/7 PASS against real hook post-fix. `/tmp/fw041-phase1-regression.sh` 22/22 PASS (all Phase 1 ACs preserved). Sonnet adversary Pass-2 added 10 new probes (POSIX escape semantics, adjacent quoted flags, mixed quote+unquoted, empty quoted, curl Authorization header FP) — 0 new bypasses, 0 new FPs.
- **Effort:** XS actual (~45min including 2 adversary passes + harness authoring).
- **Owner:** CTO.
- **Source:** CTO Sonnet adversary pass-1 on FW-041 Phase 1 draft (originally scope-gap), promoted to HOTFIX after empirical repro via `/tmp/fw041-phase2-verify.sh`.

### FW-043 — FW-029 Layer 1 Phase 1 prefix-bypass: statement-boundary anchors (HIGH)
- **Status:** SHIPPED 2026-04-23 (COO empirical adversary Pass-1 against FW-041 ship `a057c77`, 6 bypass forms; Sonnet adversary Pass-2 against draft, 1 additional form). Commit (this PR).
- **Symptom:** Pre-fix Layer 1 + CI Green gate Phase 1 anchor required command to START at LINE-START (`^[[:space:]]*` with `head -n1` pre-pipe). Real pushes-to-main preceded by any shell statement-boundary construct silently skipped both phases (fail-open — gate never prompted, reviewed key never consumed).
- **Empirical bypass forms confirmed on commit `a057c77`:**
  - (a) `cd /tmp && git push origin main` — chain prefix
  - (b) `echo ok\ngit push origin main` (multi-line) — `head -n1` ate line 1
  - (c) `(git push origin main)` — subshell paren prefix
  - (d) `true && git push origin main` — always-succeed chain
  - (e) `: ; git push origin main` — null-command + semi
  - (f) `git push origin main &` — trailing backgrounding (Phase 1 OK but Phase 2 trailing class `[[:space:];]|$` excluded `&`, so Phase 2 failed to match)
  - (g) `{ git push origin main; }` — brace-group prefix (Sonnet adversary against draft)
- **Blast radius:** HIGH. Same class as FW-041 — silent skip of Layer 1 review gate + CI Green gate. Officer believes gate enforces; gate never runs. No state amplification (gate doesn't consume reviewed key on these forms), but same fail-open severity as FW-041.
- **Fix applied** (pre-tool-use.sh lines 492, 493, 513):
  1. Removed `head -n1 |` from both Phase 1 anchor pipelines — grep's line-mode naturally handles multi-line (each line checked independently against `^`-anchored pattern, form (b) resolved).
  2. Widened Phase 1 anchor prefix from `^[[:space:]]*` to `(^|[;&|({\`])[[:space:]]*` — accepts bare line-start OR preceding shell statement-boundary char (semi, amp, pipe, open-paren, open-brace, backtick) + whitespace. Resolves forms (a)(c)(d)(e)(g).
  3. Extended Layer 1 Phase 2 action regex trailing terminator class from `[[:space:];]|$` to `[[:space:];&|(){}\`]|$` — `main`/`master` followed by backgrounding `&`, pipe `|`, close-brace `}`, close-paren `)`, backtick now also match. Resolves form (f).
- **Trade-offs accepted (fail-closed direction):**
  - FP-1: commit messages containing `&&` + `git push origin main` literal text fire the gate (e.g., `git commit -m "ci: run && git push origin main later"` → exit 2). Rare in officer workflow; gate prompts CTO to set reviewed key + retry, no amplification.
  - FP-2: heredoc bodies with `git push origin main` fire the gate (grep line-mode sees body line as standalone). Rare; same mitigation.
  - FP-3: `$(git push origin main)` command substitution fires gate. Arguably correct (IS a real push).
- **Regression/adversary pins:** `/tmp/fw034-hotfix4-adversary-tests.sh` Section D 5/5 + (f) extended → 6/6 PASS. `/tmp/fw043-adversary.sh` 12/12 HIGH bypass probes PASS + 2/2 CI Green + 1/1 CI commit-msg negative. FW-041 regression 22/22 PASS. FW-034 hotfix-4 regression 30/30 PASS. Golden evals 22/22 PASS (EVAL-014 pin updated to match new prefix `(^|[;&|({...`).
- **EVAL-014 pin evolution:** switched from `"head -n1 \| grep -qE '"` preamble filter to `"grep -qE '\(\^\|\[;&"` — distinctive FW-043 statement-boundary prefix; no other gate in the hook uses this alternation form, so pin is unambiguous.
- **Source:** COO empirical adversary (3rd Pass-1 on FW-041 ship `a057c77`) + CTO Sonnet adversary Pass-2 on draft fix (caught brace-group gap).
- **Follow-ups filed:** FW-044 (`gh api -X DELETE refs/heads/main` Phase 2 scope), FW-040 addendum (6 write-tool scope gaps — perl/tar/gawk/ruby/ln/ex/install/truncate/dd/touch/mkdir/awk-redirect — SEPARATE from FW-043 anchor work).

### FW-044 — `gh api -X DELETE refs/heads/main` Phase 2 scope (MEDIUM)
- **Status:** SHIPPED 2026-04-24 (3-round adversary: Sonnet Pass-1 on first-pass 3-grep AND — 9 bypasses + concurrent Sonnet FP-review — 8 FPs; Pass-2 unified positional regex closes 6/8 HIGH FPs + all 8 FW-044-scoped bypasses; Sonnet Pass-2 post-fix adversary — 4 new bypass classes on unified regex; Pass-3 fix adds `?` terminator + wget anchor + env-var prefix wrapper, closes 3/4; Pass-2 MEDIUM-D quote-concat deferred to FW-051). **Hotfix-1 2026-04-24**: COO Pass-1 empirical adversary on ship `b9fe882` found 14 HIGH bypasses across two root causes — Phase 2b prefix-asymmetry (11 forms) + VAR_ASSIGN quoted-value truncation (3 forms). Hotfix-1 Pass-2 Sonnet added 1 ANSI-C bypass close (15 total). Committed this PR.
- **Symptom:** `gh api -X DELETE repos/OWNER/REPO/git/refs/heads/main` passes Phase 1 (`gh api` is in the subcommand alternation) but Phase 2 action regex `pr[[:space:]]+merge` doesn't match — command is `gh api`, not `gh pr merge`. Result: destructive ref-deletion against main silently bypasses Layer 1 review gate.
- **Blast radius:** MEDIUM. Deletes the `main` branch ref (arguably more severe than a push — but prerequisite is attacker-crafted CTO command, not common workflow). Not amplification; straight bypass. Severity MEDIUM vs HIGH because the attack form is unusual and requires explicit `gh api -X DELETE` — not a natural mistyping.
- **Fix applied:** Phase 2b unified positional regex (OR-alternative to existing Phase 2a). Single `grep -qE` with:
  - **Statement-boundary anchor** on gh/curl/wget: `(^|[;&|({)}\`!])[[:space:]]*` — prevents pattern matching inside quoted echo bodies (MC3 FP: `gh api user && echo "gh api -X DELETE refs/heads/main"` — inner `gh api` has `"` preceding, not in boundary set → no match).
  - **Env-var prefix wrapper** `([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*` absorbs canonical POSIX assignment idioms between boundary anchor and subcommand (`GH_TOKEN=abc gh api …`, multi-var stacks `GH_TOKEN=abc FOO=bar gh api …`). Pass-2 MEDIUM-C fix.
  - **gh-api OR curl OR wget subcommand** alternative: flag-tolerant gh api + curl + wget anchors for raw HTTP calls (Pass-1 C3, Pass-2 HIGH-B).
  - **Clause-exclusion** `[^;&|#]*` between anchor and signals — stops at `;`/`&`/`|`/`#` so compound-command FPs don't cross clauses (MC1 semicolon, MC2 && compound, ND1 git commit body, ND2 # comment, ND3 pipe, WH1 webhook-f-flag).
  - **Case-insensitive DELETE** `[Dd][Ee][Ll][Ee][Tt][Ee]` + **fused flag** `(-X|--method|--request)[=[:space:]]*` covers -XDELETE (A2), -X DELETE, -X=DELETE, --method DELETE, --method=DELETE, --request DELETE.
  - **Quoted DELETE** `["']?[Dd][Ee][Ll][Ee][Tt][Ee]["']?` (A5).
  - **Lowercase DELETE** (A6, A6b).
  - **Trailing-slash** `(main|master)/?` + terminator `[[:space:];&|(){}<>'"\`!#\\^~/?]` includes `/` (B1 disambig) + `?` (Pass-2 HIGH-A query-string `?v=1` bypass).
  - **Branch-protection endpoint** `branches/(main|master)/protection` alternative — same destructive verb class (D1).
  - **Order-agnostic**: flag-before-ref AND ref-before-flag both covered by top-level alternation.
- **First-pass 3-grep AND-composed fix** (replaced by unified positional regex because AND composition is global-scope → 6 HIGH FPs on compound commands where each grep matched independently across `&&`/`;` clauses). Positional regex enforces proximity via clause-exclusion.
- **ACs (all PASS):**
  - AC-1: `gh api -X DELETE repos/OWNER/REPO/git/refs/heads/main` → exit=2. ✓
  - AC-2: `gh api -X DELETE repos/OWNER/REPO/git/refs/heads/master` → exit=2. ✓
  - AC-3: `gh api repos/OWNER/REPO/git/refs/heads/main` (GET default) → exit=0. ✓
  - AC-4: `gh api repos/OWNER/REPO/git/refs/heads/feature-branch` → exit=0 (non-main). ✓
- **Additional adversary-pinned ACs (Pass-1):**
  - A2: `-XDELETE` fused → exit=2. ✓
  - A5: `-X "DELETE"` quoted → exit=2. ✓
  - A6: `-X delete` lowercase → exit=2. ✓
  - B1: `refs/heads/main/` trailing slash → exit=2. ✓
  - C3: `curl -X DELETE https://api.github.com/repos/O/R/git/refs/heads/main` → exit=2. ✓
  - D1: `gh api -X DELETE repos/O/R/branches/main/protection` → exit=2. ✓
  - MC3: `gh api user && echo "gh api -X DELETE refs/heads/main"` → exit=0 (FP avoided). ✓
  - ND1: `gh api user && git commit -m "fixed DELETE refs/heads/main bug"` → exit=0. ✓
  - ND3: `gh api user | grep "DELETE refs/heads/main"` → exit=0. ✓
  - WH1: `gh api -X POST /user/events -f action=DELETE -f ref=refs/heads/main` → exit=0 (webhook event ≠ ref deletion). ✓
- **Additional adversary-pinned ACs (Pass-2 → Pass-3 fix):**
  - PA-A1: `gh api -X DELETE repos/O/R/git/refs/heads/main?v=1` → exit=2. ✓ (HIGH-A query-string fix: `?` in terminator)
  - PA-A2: `curl -X DELETE https://api.github.com/repos/O/R/git/refs/heads/main?v=1` → exit=2. ✓
  - PA-A3: `gh api -X DELETE repos/O/R/branches/main/protection?v=1` → exit=2. ✓
  - PA-B1: `wget --method=DELETE https://api.github.com/…/refs/heads/main` → exit=2. ✓ (HIGH-B wget anchor added parallel to curl)
  - PA-B2: `wget --method DELETE https://api.github.com/…/refs/heads/main` → exit=2. ✓
  - PA-C1: `GH_TOKEN=abc gh api -X DELETE repos/O/R/git/refs/heads/main` → exit=2. ✓ (MEDIUM-C env-var prefix wrapper)
  - PA-C2: `FOO=bar gh api -X DELETE repos/O/R/git/refs/heads/main` → exit=2. ✓
  - PA-C3: `GH_TOKEN=abc FOO=bar gh api -X DELETE …` → exit=2. ✓ (multi-var stack)
  - PA-E1: `gh api -X DELETE repos/O/R/git/refs/heads/MAIN` → exit=0 (ALLOW — `MAIN` is a valid separate ref, not main/master). ✓
  - PA-E2: `gh api -X DELETE repos/O/R/git/refs/heads/MASTER` → exit=0 (ALLOW — same rationale). ✓
- **Hotfix-1** (COO Pass-1 empirical on ship `b9fe882` — 14 HIGH, 2 root causes):
  - **ROOT CAUSE 1 — Phase 2b prefix asymmetry (PA-F class, 11 bypasses):** Phase 2b prefix-absorber was `([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*` only — a strict SUBSET of Phase 1's `(sudo|env|timeout|exec|time|nohup|nice|ionice|coproc|stdbuf|unbuffer|setsid|command|builtin|VAR_ASSIGN|shell-c|eval|redirect|then-do)` alternation. AND-composed gate `phase1 && (phase2a||phase2b)` fires false on every wrapper Phase 1 absorbs but Phase 2b doesn't, because Phase 2b anchor requires immediate `gh|curl|wget` after optional narrow prefix — but with `eval gh api …` Phase 1 matched, Phase 2b saw `eval gh api …` but couldn't absorb `eval`, so anchor matched neither side-by-side nor after a narrow prefix.
    - PA-F1: `eval "gh api -X DELETE refs/heads/main"` → exit=2. ✓
    - PA-F2: `eval 'gh api -X DELETE refs/heads/main'` → exit=2. ✓
    - PA-F3: `bash -c "gh api -X DELETE refs/heads/main"` → exit=2. ✓
    - PA-F4: `sh -c "gh api -X DELETE refs/heads/main"` → exit=2. ✓
    - PA-F5: `nohup gh api -X DELETE refs/heads/main` → exit=2. ✓
    - PA-F6: `time gh api -X DELETE refs/heads/main` → exit=2. ✓
    - PA-F7: `exec gh api -X DELETE refs/heads/main` → exit=2. ✓
    - PA-F8: `sudo gh api -X DELETE refs/heads/main` → exit=2. ✓ (Phase 1 sudo branch caught pre-hotfix, Phase 2b catches post-hotfix for consistency)
    - PA-F9: `env GH_TOKEN=abc gh api -X DELETE refs/heads/main` → exit=2. ✓ (bare `env CMD` form, not `VAR=val gh api`)
    - PA-F10: `timeout 5 gh api -X DELETE refs/heads/main` → exit=2. ✓
    - PA-F11: `command gh api -X DELETE refs/heads/main` → exit=2. ✓
    - PA-F12: `stdbuf -o0 gh api -X DELETE refs/heads/main` → exit=2. ✓
  - **ROOT CAUSE 2 — VAR_ASSIGN quoted-value truncation (PA-E class, 3 bypasses):** `[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+` value class stops at the first space, so `PATH="foo bar" gh api -X DELETE refs/heads/main` breaks: regex consumed `PATH="foo` then hit space, anchor required space-delimited end of prefix, saw quoted `bar" gh…` start with `b`, not `gh`. Phase 1 same flaw. Canonical POSIX assignment idiom with quoted-space value is natural bash usage.
    - PA-E1 (hotfix-1): `PATH="foo bar" gh api -X DELETE refs/heads/main` → exit=2. ✓
    - PA-E2 (hotfix-1): `GH_HOST='api example com' gh api -X DELETE refs/heads/main` → exit=2. ✓
    - PA-E3 (hotfix-1): `MSG="hello world foo" gh api -X DELETE refs/heads/main` → exit=2. ✓
  - **Fix 1 (Phase 2b prefix parity):** Replaced narrow VAR-only absorber with full Phase 1 alternation — same flag-tolerant branches for `sudo|env|timeout|exec|time|nohup|nice|ionice|coproc|stdbuf|unbuffer|setsid|command|builtin|VAR_ASSIGN|shell-c|eval|redirect|then-do`. Phase 2b now absorbs the same prefix surface as Phase 1 so AND-gate is symmetric.
  - **Fix 2 (VAR_ASSIGN value widening):** `[^[:space:]]+` → `('[^']*'|"[^"]*"|[^[:space:]]+)` (quoted-string OR unquoted-non-space). Applied at Phase 1 AND Phase 2b for parity. Later extended to `(\$'[^']*'|'[^']*'|"[^"]*"|[^[:space:]]+)` to cover ANSI-C `$'...'` quoting (Hotfix-1 Pass-2 P2-A2).
  - **Hotfix-1 Pass-2 Sonnet adversary** (post-fix): 1 additional HIGH close (P2-A2 ANSI-C `FOO=$'hello world' gh api -X DELETE refs/heads/main`). P2-A1 `FOO=''hello world''` bash adjacent-quoted-string concat deferred to FW-051 (same preprocessing-class root as `-X 'DE''LETE'` quote-concat). 18/19 adversary probes BLOCK + 15/15 FP controls ALLOW.
  - **Hotfix-1 Pass-3 Sonnet adversary** (orthogonal scope-gaps): 3 deferred to FW-051 — full-path shell (`/bin/bash -c`, shell alternation has no slash), fused-flag `bash -lc` (only `-c` branch exists), wrapper indirection (`./wrapper.sh`, no indirection absorber).
  - **Combined adversary CA1**: `eval "PATH=\"foo bar\" gh api -X DELETE refs/heads/main"` — backslash-escaped quotes inside eval body deferred to FW-051 (CMD_NORM-preprocessing class; same as SP1-SP4 quoted-splice).
  - **Hotfix-1 regression**: 15 COO Pass-1 bypasses + 19 Hotfix-1 Pass-2 adversary probes + 15 FP controls + 60/61 on pre-existing fw044-verify.sh (1 HD1 heredoc pre-existing, not regression). FW-041 phase2 21/21, FW-041 hf3 prod 33/33, FW-041 hf3 pass5 50/50, FW-042 v3.7.2 BSQ 18/18, FW-043 adversary 24/27 (baseline), FW-045 pass7 61/61, FW-042 pass2 44/46 (baseline).
- **Regression/adversary pins:**
  - `/tmp/fw044-verify.sh` 61-probe harness (Pass-3 extended): **60/61 PASS** (HD1 heredoc multi-line body pre-existing scope-gap, accept-fail-closed → FW-051).
  - Pass-3 FP sanity 10-probe sweep: 10/10 ALLOW (wget download, wget -O dash, wget --method=GET, `GIT_TRACE=1 git log`, `FOO=bar echo`, `GH_TOKEN=abc gh pr view 42`, `API_KEY=xxx curl`, `?` in doc body, wget token in grep body, env var in commit msg).
  - FW-041 phase2 (21/21), FW-041 hf3 prod (33/33), FW-041 hf3 pass5 (50/50), FW-042 v3.7.2 BSQ (18/18), FW-043 adversary (24/27 — 3 known-accept baseline FPs unchanged), FW-045 pass7 (61/61), FW-042 pass2 (44/46 — 2 pre-existing Section 2 sudo-redirect-wrapper scope-gaps unrelated to FW-044).
- **Deferred to FW-051:** Layer 1 quoted-splice (SP1-SP4: `"gh" api`, `g"h" api`, `\"gh\" api`, `gh"" api`), subshell-eval splice (E3: `$(echo gh) api`), URL-encoded refs (B2: `refs%2fheads%2fmain`), wildcard refs (B3: `refs/heads/m*`), multi-line heredoc body scan (HD1), **quote-concat `'DE''LETE'` / `"DE""LETE"` (PA-D1/PA-D2 — Pass-2 MEDIUM-D)**. Same root cause as FW-042 v3.7.1 pre-BSQ — Layer 1 doesn't apply CMD_NORM/CMD_UNQUOTED preprocessing.
- **Effort:** S (~4h — first-pass 3-grep (20m) + 2 concurrent adversary/review agents (30m) + unified positional regex redesign (60m) + Pass-2 adversary (30m) + Pass-3 fix for 3/4 Pass-2 findings (45m) + 61-probe harness + regression sweep + backlog + commit).
- **Owner:** CTO.
- **Source:** COO empirical adversary Pass-1 on FW-041 ship — Section D `gh-api-delete-main` form.

### FW-045 — FW-029 Layer 1 Phase 1 wrapper/prefix-consumer bypasses (HIGH)
- **Status:** SHIPPED 2026-04-23 (6-round adversary: Sonnet Pass-1 + COO Pass-2 empirical on FW-043 ship, 14 HIGH + 3 scope-gaps; Sonnet Pass-3 on draft fix, 9 additional; Sonnet Pass-4 post-fix, 4 real bypasses + 2 invalidated FPs; COO Pass-5 empirical on hotfix-6 `e588850`, 6 HIGH shell-compound-statement + 2 MEDIUM stdin-shell scope-gap; Sonnet Pass-6 post-hotfix-7, 0 HIGH + 0 MEDIUM + 1 LOW FP-widening only). Hotfix-7 commit (this PR) closes Pass-5 HIGH.
- **Symptom:** FW-043 statement-boundary anchor only handled `sudo|env VAR=|timeout Ns|(...preceded by boundary char)`. Bare POSIX command modifiers before `git push` bypassed: `exec git push origin main` / `time git push...` / `nohup git push...` / `nice -n 10 git push...` / `ionice -c 3 git push...` / `stdbuf -oL git push...` / `unbuffer git push...` / `coproc git push...` / `setsid git push...` / `command git push...` / `builtin git push...`. Also: bare inline POSIX assignment `GIT_TRACE=1 git push origin main`, `FOO=bar BAZ=qux git push...` (canonical `env` usage idiom — FW-043 `env` branch required literal `env` keyword). Shell `-c` wrapper: `bash -c 'git push...'` + flag-tolerant `bash -x -c`/`bash --norc -c` + ANSI-C `bash -c $'...'` + alt shells `fish|ksh|dash|ash|csh|tcsh|mksh -c '...'`. Boundary class gaps: `! git push...` (bash negation) + `) git push...` (case-arm close) + `} git push...` (function-body close). Redirect-prefix forms: `>/tmp/out git push...` + digit-prefix `2>/dev/null git push...` + `1>/tmp/log git push...`. `eval` wrapper: `eval 'git push...'` + bare `eval git push...`. Phase 2 trailing class asymmetry: `bash -c 'git push origin main'` — ending `'` after `main` not in original Phase 2 trailing class, Phase 2 fails even after Phase 1 matches. Also `main!`/`main#comment`/`main^1`/`main~2`/`main\foo` trailing chars.
- **Blast radius:** HIGH (same fail-open class as FW-041/FW-043). CTO workflow invokes many of these forms naturally (`GIT_TRACE=1` for debug pushes, `timeout 30s git push` for CI hangs, `exec git push` for last-step shell replacement, `bash -c` for git-hook-under-different-context). All silently bypassed Layer 1 review gate. No state amplification.
- **Fix applied** (single commit, two-layer):
  - **Phase 1 comprehensive alternation**: unified flag-tolerant branches for 13 POSIX wrappers `(exec|time|nohup|nice|ionice|coproc|stdbuf|unbuffer|setsid|command|builtin)`, bare-`env` with flag-tolerance, `timeout` with pre-duration flag-tolerance, shell-`-c` across 10 POSIX-family shells `(bash|sh|zsh|fish|ksh|dash|ash|csh|tcsh|mksh)` with pre-`-c` flag-tolerance + ANSI-C absorber `(\$?['"])?`, digit-prefix redirect `[0-9]?[<>]`, `wget` parallel to curl, inline `VAR=val` POSIX assignment idiom `[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+`, boundary class extended `[;&|({)}\`!]` (add `)` + `}`).
  - **Phase 2 trailing class**: extended `[[:space:];&|(){}<>\`]` → `[[:space:];&|(){}<>'"\`!#\\^~]` (add quotes for wrapper-exec endings, `!` for P2 asymmetry, `#` for shell-comment strip, `^` `~` for git ancestor refs, `\\` for backslash).
  - **CI Green Phase 1**: mirrored byte-identical to Layer 1 Phase 1 (both gates now share same prefix-detection surface; Phase 2 diverges intentionally — Layer 1 matches push/merge, CI Green matches `pulls/N/merge`).
  - **Comment block update**: documented every alternation extension, pattern rationale, Pass-3/Pass-4 additions, and scope-gaps.
- **Hotfix-7** (Pass-5 HIGH close): add `(then|do|else|elif)[[:space:]]+` branch to prefix-consumer alt in Layer 1 Phase 1 + CI Green Phase 1. Closes 6 canonical-bash-compound-statement bypasses: `if …; then git push origin main; fi`, `if …; elif …; then …`, `if …; else …`, `while …; do …`, `for … in …; do …`, `until …; do …`. No flag-tolerance (reserved words don't take flags). Sonnet Pass-6 on hotfix-7: clean — tested `select`/`case`/`function`/`coproc`/nested-compound/newline-separated/`;;`-case-terminator/`!` negation — all FIRE via existing wrapper alt or boundary class.
- **Remaining scope-gaps** (acknowledged — NOT fixable by flat regex):
  - `echo origin main | xargs git push` (xargs lexical disaggregation across pipe)
  - `X=git; $X push origin main` (variable expansion — FW-040 Phase B)
  - `. /tmp/push.sh` + `source /tmp/push.sh` (hook can't scan file contents — FW-040 Phase B)
  - `perl -e 'system("git push origin main")'` + `python -c '…'` + `awk 'BEGIN{system(…)}'` (same class as dot-source)
  - `bash <<<"git push origin main"` here-string + `echo 'git push origin main' | bash -s` explicit-stdin-read (same dataflow-decoupled class as xargs + dot-source — Pass-5 MEDIUM #2, fold to FW-040 Phase B).
- **Accepted fail-closed FPs** (same class as FW-043 FP-1):
  - Commit bodies / inline text containing wrapper-token or inline-VAR adjacent to literal `git push origin main` text fire the gate (e.g., commit msg `nohup git push origin main for CI`). Mitigation: `cabinet:layer1:cto:reviewed` re-SET + retry (same as FW-043).
  - **Pass-6 Sonnet LOW widening**: multi-line `-m` commit bodies where a line starts `then git push …` / `do git push …` / `else git push …` / `elif …` fire via the new reserved-word branch + `^` line-start anchor. Same fail-closed class, same retry workaround.
- **Pass-4 false-positives** (Sonnet findings that Pass-4 empirically invalidated):
  - `<(git push origin main)` process substitution: already fires via existing `(` boundary class match.
  - `git push origin main:refs/heads/main` refspec: already fires via greedy `.*(main|master)$` path (the final `main` at end-of-line matches with `$` terminator).
- **Regression/adversary pins:**
  - `/tmp/fw043-pass2-adversary-tests.sh` COO Pass-2 harness: 38/40 PASS (2 acknowledged scope-gaps: xargs, var-expansion).
  - `/tmp/fw045-sonnet-pass3-tests.sh` Sonnet Pass-3 harness: all real bypass forms blocked (2 FAILs are harness-authoring bugs, not regex bugs).
  - `/tmp/fw045-pass4-verify.sh` Sonnet Pass-4 harness: 9/9 real bypasses blocked (C-3 + C-4 + 2 negative-control harness-authoring FPs expected).
  - `/tmp/fw045-pass5-verify.sh` COO Pass-5 harness: 6/6 real bypasses blocked (if-then, if-elif, if-else, while-do, for-do, until-do) + 5/5 controls green.
  - Golden evals: 22/22 PASS (EVAL-014 positive matrix extended with 22 new pins covering Sonnet Pass-3/Pass-4 forms + 6 Pass-5 compound-statement pins: `command`/`builtin`/`fish -c`/`ksh -c`/`dash -c`/`env` bare/`env -u HOME`/`timeout --preserve-status`/`setsid`/`bash -x -c`/`bash --norc -c`/`bash -c $'...'`/`2>/dev/null`/`)` boundary/`}` boundary/`main # comment`/`if…then…fi`/`if…elif…fi`/`if…else…fi`/`while…do…done`/`for…do…done`/`until…do…done`).
- **EVAL-014 architecture change**: Replaced sed-based regex-extraction harness with direct hook invocation (`jq -cn`+`OFFICER_NAME=cto bash "$HOOK"`). Reason: FW-045 added `['"]?` alternation inside the hook's single-quoted grep pattern. The old sed extractor `s/.*grep -qE '([^']+)'.*/\1/` stops at the first `'` inside the regex (from `'\''` embedded escape), truncating the extracted pattern. Hook-invocation approach is robust to future quote additions.
- **Source:**
  - COO empirical adversary Pass-2 on FW-043 ship `f7a231b` — 17 forms, 3 scope-gaps, 14 addressable.
  - CTO Sonnet adversary Pass-3 on draft fix (fresh-context logic review) — found 9 additional issues (4 HIGH boundary/wrapper-flag, 4 MEDIUM, 1 LOW).
  - CTO Sonnet adversary Pass-4 post-fix re-review — found 4 real bypasses (`command`/`builtin`/`fish-ksh-dash -c`) + 2 invalidated-by-empirical findings.
  - COO empirical adversary Pass-5 on hotfix-6 `e588850` — 44/52 PASS; 6 HIGH (`then|do|else|elif`) + 2 MEDIUM scope-gap (`bash<<<`, `bash -s`).
  - CTO Sonnet adversary Pass-6 on hotfix-7 draft — 0 HIGH + 0 MEDIUM + 1 LOW FP-widening (multiline `-m` with `^then|do|else|elif git push` line). All bash compound-statement forms tested clean (select, case, function, coproc, nested, newline-separated, `;;`).
  - COO empirical adversary Pass-7 on hotfix-7 ship `c933973` — 57 probes, 0 real bypasses, 1 non-finding (uppercase `IF/THEN` — bash case-sensitive, no real attack surface). All Pass-5 HIGH (6) closed. All Pass-2/3/4 regression (13) stable. 23 new broader-grammar probes all BLOCK: `case…in…)…;;`, `select`, `[[…]]`, C-style `for ((…))`, function-def brace-form, bash `-c $'if…'`, `true && if…then…`, `true | if…then…`, reserved-word→wrapper cascade, reserved-word→inline-VAR cascade, reserved-word→`bash -c` cascade. **SHIP-CLEAN.**
- **Memory updated:** `feedback_security_regex_authoring.md` — this is 7th pre-tool-use-regex adversary round (Pass-7 clean-confirm); Rule 1 quantified as "4-5 rounds typical for security-critical regex, 6-7 rounds for convergence confirmation"; Rule 1 addendum added: Pass-N triage (bug/scope-gap/false-positive/non-finding) with empirical-verify-before-regex-extend discipline.
- **Follow-ups filed:** FW-044 (still open: gh api -X DELETE refs/heads/main Phase 2 scope); FW-041 Phase 2 (still open: quoted-space flag value); FW-046 (evaluator sed-extraction fragility — systemic).
- **Owner:** CTO.

### FW-046 — Golden-eval sed-extraction fragility (systemic)
- **Status:** SHIPPED 2026-04-23 (commit db96891 — CTO).
- **Symptom:** EVAL-011, EVAL-013, EVAL-015, EVAL-016 extract the hook's grep regex via `sed -E "s/.*grep -qE '([^']+)'.*/\1/"`. The `[^']+` class stops at the first `'` inside the regex content. If the hook regex contains `'\''` shell-escape (closes → literal `'` → reopens single-quote), the extractor truncates the regex mid-pattern — silently returning a partial, matching-subset regex. Test cases then pass or fail based on the truncated view, not the actual hook regex. FW-045 hit this exact bug on EVAL-014 (which used the same pattern); EVAL-014 was migrated to direct hook invocation. The remaining 4 EVALs have NOT been migrated.
- **Blast radius:** MEDIUM (regression-catcher integrity, not production security). Currently all 4 EVALs pass because none of the hook regexes they extract contain `'\''` yet. Any future regex change adding `'\''` to:
  - post-tool-use.sh deploy detection (EVAL-011)
  - post-tool-use.sh FW-028 command-start anchor (EVAL-013)
  - pre-tool-use.sh FW-032 whitelist anchor (EVAL-015)
  - pre-tool-use.sh FW-033 experience-nudge anchor (EVAL-016)
  → silently breaks the eval. Detection requires reading the eval output carefully enough to notice the extracted regex is truncated (hard to spot).
- **Proposed fix:** Port the EVAL-014 direct-hook-invocation pattern to the other 4 EVALs:
  ```bash
  ev_hook_probe() {
    local cmd="$1"
    local json
    json=$(jq -cn --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}')
    redis-cli -h redis -p 6379 DEL <gate-key-1> <gate-key-2> >/dev/null 2>&1
    echo "$json" | OFFICER_NAME=<officer> bash "$HOOK" >/dev/null 2>&1
    return $?
  }
  ```
  Replace all `sed -E "s/.*grep -qE '([^']+)'.*/\1/"` extractions + subsequent `echo "$cmd" | grep -qE "$EXTRACTED"` with `ev_hook_probe "$cmd"` + exit-code check.
- **ACs:**
  - AC-1: All 4 EVALs (011/013/015/016) use direct hook invocation.
  - AC-2: Regex-extraction sed pattern removed from golden-evals.
  - AC-3: 22/22 golden evals still PASS with the migration.
  - AC-4: Add a defensive test that fails hard if any eval's extracted regex contains `'\''` (future-regression guard).
- **Effort:** M (~90min — 4 EVAL rewrites × 20min each + defensive test + full regression).
- **Owner:** CTO.
- **Source:** FW-045 ship process — EVAL-014 migration surfaced the pattern; same pattern repeats 4 places.

### FW-047 — Golden-eval direct hook invocation fires production triggers (HIGH)
- **Status:** SHIPPED 2026-04-23 — Option 1 patched (env-var gate). Incident window 19:24:53-19:27:02 UTC (CPO flagged 19:26:18). Shipped same-session as diagnosis (<30min detection-to-patch). Verified by EVAL-023: 24/24 evals + full-run CPO/COO queue delta = 0.
- **Symptom:** FW-046 (commit db96891) migrated EVAL-011/013/015/016 to direct post-tool-use.sh invocation (`echo "$json" | OFFICER_NAME=cto bash "$HOOK"`). Post-tool-use.sh block 5 (AUTO-DEPLOY fan-out) calls `trigger_send` against **production Redis** whenever the probed CMD matches the deploy-detection regex. Every deploy-positive test case in the eval's positive matrix therefore fires a real AUTO-DEPLOY trigger to every officer with `validates_deployments` + `reviews_implementations`. First incident: single eval run added 383 spam triggers to CPO (144) + COO (239) queues across 69 seconds — ~5.5 triggers/second sustained. Silently burns tokens on every reviewer/validator when the eval is run.
- **Blast radius:** HIGH. The EVAL harness is designed to be run frequently (pre-push gate via FW-025 — which means *every framework push now fires this*). Impact scales with positive-matrix size × reviewer+validator count. Not a security bug; a cross-officer coordination + token-consumption bug. Confirmed via db96891 comment block itself: `# Note: gh pr merge 42 --squash fires block 5 trigger_send (side effect)` — the author knew but did not guard.
- **Fix shipped (Option 1 — env-var guard):**
  - `post-tool-use.sh` block 5 (AUTO-DEPLOY fan-out to `validates_deployments` + `reviews_implementations`) wrapped in `[ "${CABINET_HOOK_TEST_MODE:-}" != "1" ]` guard.
  - `post-tool-use.sh` block 6b (Write/Edit cross-validation to `reviews_specs` + `reviews_research`) wrapped in same guard — EVAL-016 Write-branch probes (product-specs/research-briefs paths) otherwise re-amplify.
  - Block 6 stdout REMINDER echoes left unguarded (the primary eval signal — stdout greps unchanged).
  - `run-golden-evals.sh` ev11_hook_probe + ev13_hook_probe + ev16_hook_probe each set `CABINET_HOOK_TEST_MODE=1` inline (three-word env prefix, no subshell export).
  - EVAL-015 unchanged (pre-tool-use.sh has no trigger_send or notify-officer calls — verified grep-clean).
- **ACs met:**
  - **AC-1 ✅** Full 24-eval run (EVAL-023 added) produces **zero** net trigger growth on `cabinet:triggers:cpo` + `cabinet:triggers:coo`.
  - **AC-2 ✅** All positive-match assertions preserved: EVAL-011/013 still grep "REMINDER:" from stdout; EVAL-016 still reads nudge Redis key (block 7, unaffected). 24/24 PASS.
  - **AC-3 ✅** EVAL-023 `FW-047 trigger-storm regression guard` fires 6 deploy/Write probes, asserts CPO+COO queue parity. Fails hard on regression (guard regression → re-opened storm).
  - **AC-4 ✅** FW-046 comment `# Note: gh pr merge 42 --squash fires block 5 trigger_send (side effect accepted — test-run noise)` replaced with `# Note: ... would fire block 5 trigger_send fan-out in production, but ev13_hook_probe sets CABINET_HOOK_TEST_MODE=1 which short-circuits the fan-out under FW-047.`
- **Alternative options NOT taken (logged for retro):**
  - Stream-prefix redirect (`CABINET_TRIGGER_STREAM_PREFIX`) — would have been more structural but required changes in `lib/triggers.sh` + eval harness. Higher surface area, slower to ship in an active-incident context.
  - trigger_send mock override — clean but fragile to hook modifications; every new trigger_send call site would need re-mocking.
- **Effort:** S-actual: ~25min (10-line hook diff + 3 probe-fn edits + 65-line EVAL-023 + FW-046 comment swap).
- **Owner:** CTO.
- **Source:** 2026-04-23 incident; CPO infra alert; CoS diagnosis. Cross-cut with P-014 (retro: test infrastructure can silently affect production state — reinforcement: always gate test harnesses that invoke production hooks against real state-mutating sinks).

---

### FW-048 — Add dashboard `tsc --noEmit` to Cabinet CI (MEDIUM)
- **Status:** SHIPPED 2026-04-23 (commit `ed829ea`). `typecheck-dashboard` job added to `.github/workflows/cabinet-ci.yml`, gated on PR + push to master. Pre-existing `flow.test.ts` errors resolved via tsconfig exclude of `**/*.test.ts`+`**/*.test.tsx` (FW-050 tracks follow-up to wire vitest + unexclude). Originally Proposed 2026-04-23 (CTO, post-Spec 037 PR A ship).
- **Scope:** Add a `typecheck-dashboard` job to `.github/workflows/cabinet-ci.yml` running `cd cabinet/dashboard && npm ci && npx tsc --noEmit`. Blocks PR merge on TS errors in the dashboard tree.
- **Motivation:** Spec 037 PR A (CommandPalette) shipped with a latent type-shadow error (`import { type KeyboardEvent }` from React shadowed the global DOM `KeyboardEvent` used by window-level keydown listeners). Caught in local `tsc --noEmit` pre-push — but `pre-push-gate.sh` doesn't run dashboard tsc; only a CI check would catch it on PRs where the author forgot to tsc locally. High-leverage additive safety (~45s job once npm cache warm).
- **Dependencies:**
  - **Soft blocker:** `src/lib/provisioning/flow.test.ts` has 2 pre-existing tsc errors (vitest module not found + implicit `any` on `call` parameter). Must either install `vitest` + typings as devDep, OR exclude test files from tsc strict run, OR fix the `any` + leave the file as `// @ts-nocheck` pending vitest install. Check with CPO / test-infra owner before picking.
- **Acceptance criteria:**
  - **AC-1:** `cabinet-ci.yml` has a `typecheck-dashboard` job running `npx tsc --noEmit` against `cabinet/dashboard`, gated on PR + push to master.
  - **AC-2:** Pre-existing `flow.test.ts` errors resolved (method picked per Dependencies section).
  - **AC-3:** One planted type error on a throwaway branch fails the new job (regression pin — prove the gate actually fails, not just passes).
  - **AC-4:** Job completes in under 90s with npm-cache hit; under 3 minutes cold.
- **Out of scope:** Full dashboard test suite (vitest run), ESLint, Next.js build. Type-check only — the narrowest gate that would have caught PR A's error.
- **Effort:** S (workflow YAML addition + flow.test.ts resolution + regression pin).
- **Owner:** CTO.
- **Source:** CTO self-retro post-PR-A ship; experience record `2026-04-23-cto-1776975201-*`.

---

### FW-050 — Dashboard vitest wire-up: remove tsc exclude + CI test step (MEDIUM)
- **Status:** SHIPPED 2026-04-24 (PR #46 squashed to master as `bb9c801`). Local verification: `npx vitest run` 110/110 pass, `npx tsc --noEmit` exit 0 after tsconfig exclude removal. CI run `24872510326` green (Dashboard vitest step + typecheck both green on feature branch). Rebase notes: Crew agent worktree forked from pre-FW-048 base (ff11e85) — CTO rebased in-worktree onto master (3a8fff6), resolved CI workflow conflict (kept agent's vitest step after master's typecheck step), added AC-2 tsconfig exclude removal that agent missed, amended + force-pushed with explicit SHA lease before merge. Originally Proposed 2026-04-23 by CTO during FW-048 follow-up survey.
- **Context:** FW-048 shipped `tsc --noEmit` in CI by excluding `**/*.test.ts` + `**/*.test.tsx` from `cabinet/dashboard/tsconfig.json`. The 3 reference test files (`botfather.test.ts`, `provisioning/flow.test.ts`, `provisioning/state-machine.test.ts`) import vitest, which is not in `devDependencies`. Spec 034 scaffolded them as vitest-syntax reference specs with the assumption that a "PR 5" would wire vitest + execute them in CI.
- **Local discovery (CTO 2026-04-23 FW-048 follow-up):**
  - `npm install --save-dev vitest` + `npx vitest run` surfaces **6 test files, 92 total cases, 52 fail + 40 pass**. Failures stem from:
    1. **`.next/standalone/` duplicates** — Next.js build output contains mirrored source copies; vitest picks up `.next/standalone/src/lib/botfather.test.ts` alongside the real `src/lib/botfather.test.ts`. Needs `vitest.config.ts` with `exclude: ['node_modules', '.next', '.next/**']`.
    2. **Path alias unresolved** — test files import from `@/lib/*` (tsconfig paths). Vitest doesn't read Next.js tsconfig paths natively; needs `vite-tsconfig-paths` plugin or explicit `resolve.alias` block in vitest config.
    3. **Mock scaffolding incomplete** — `flow.test.ts` uses extensive `vi.mock(...)` patterns that reference un-imported modules (redis, send-message API, Telegram client). Per the file comment: "Mocks — these will be wired up when vitest is integrated."
    4. **Assertion typo** — `botfather.test.ts:142` expects `'x___'` where `tokenLastFour` returns `'z___'` on the input token (ends in `z___`, not `x___`). Real test bug.
  - Investigation reverted (`npm uninstall vitest` + `git checkout package-lock.json`) — no commits to main.
- **Proposed fix (single PR):**
  1. Install vitest + vite-tsconfig-paths as devDeps: `npm install --save-dev vitest vite-tsconfig-paths`.
  2. Add minimal `vitest.config.ts` (exclude `.next`, plugin `tsconfigPaths()`).
  3. Fix `botfather.test.ts:142` assertion (`z___` not `x___`).
  4. Wire `flow.test.ts` mocks — import + `vi.mock()` the real modules.
  5. Add `"test": "vitest run"` + `"test:watch": "vitest"` scripts to `cabinet/dashboard/package.json`.
  6. Add CI step `Dashboard vitest` after `Dashboard typecheck`: `cd cabinet/dashboard && npm test`.
  7. Remove `**/*.test.ts` + `**/*.test.tsx` from `tsconfig.json` exclude (tests now typecheck under the same pass).
- **ACs:**
  - AC-1: `cd cabinet/dashboard && npx vitest run` exits 0 locally (all 3 test files green).
  - AC-2: `npx tsc --noEmit` still exits 0 after exclude removal (tests typecheck).
  - AC-3: CI adds a green `Dashboard vitest` step; regression visible pre-merge.
  - AC-4: Golden evals unaffected (Python-only surface).
- **Blast radius:** LOW. Pure coverage-expansion; no runtime behavior change. `tsc` exclude becomes obsolete (can be removed), which is strictly net-positive (tests retain type checking).
- **Effort:** M (~1-2h — mostly wiring + mock scaffolding completion for flow.test.ts).
- **Owner:** CTO. Defers to CPO if spec changes needed (state-machine.test.ts declares its own global types — minor friction with vitest's implicit globals).
- **Source:** CTO local FW-048 follow-up investigation 2026-04-23. FW-048 commit `ed829ea` documented the exclude as "tracked as Spec 034 PR 5 follow-up" — this backlog entry is the formal follow-up.
- **Dependencies:** FW-048 (SHIPPED). No blockers.

### FW-051 — Layer 1 no-preprocessing scope-gap class (MEDIUM) ✓ SHIPPED
- **Status:** SHIPPED 2026-04-24 by CTO (task #139). Root cause: Layer 1 push-to-main gate (Section 6 pre-tool-use.sh) and CI Green gate (Section 7) read `$CMD` raw without the CMD_NORM / CMD_STRIPPED / CMD_UNQUOTED / CMD_MASKED preprocessing chain that Section 3b (prohibited-action gate) applies via FW-042 v3.7.2. Phase 1 scope consolidates: triple-scan architecture (RAW + CMD_L1_NORM + HAS_SPLICE-gated CMD_L1_UNQUOTED), empty-quote-pair strip (`''`, `""`), backtick-substitution strip (`` `gh` `` → `gh`), regex-extension for full-path shells + path-prefixed `env` + fused-flag `-[A-Za-z]*c[A-Za-z]*` + URL-encoded `%2[Ff]` refs/branches. 10 of 12 ACs shipped; AC-3 (subshell-eval splice) + AC-9 edge deferred to FW-040 Phase B (shell-parse-aware, interpreter absorbers).
- **Symptom class (6 deferred bypass sub-classes, all reproducible on FW-044 ship):**
  - **SP1-SP4 quoted-splice**: `"gh" api -X DELETE refs/heads/main`, `g"h" api -X DELETE…`, `\"gh\" api -X DELETE…`, `gh"" api -X DELETE…` — bash concatenates adjacent tokens at runtime so these execute as `gh api …` but the regex's gh-subcommand anchor requires literal `gh` at boundary-start. Same root as FW-042 pre-v3.7.2 BSQ. (From FW-044 /tmp/fw044-verify.sh SP1-SP4.)
  - **E3 subshell-eval splice**: `$(echo gh) api -X DELETE refs/heads/main` — `$(…)` evaluates at runtime to `gh`, but regex sees `$` + `(` + `echo gh` + `)` literally. (From FW-044 adversary Pass-1.)
  - **B2 URL-encoded refs**: `gh api -X DELETE repos/O/R/git/refs%2fheads%2fmain` — `%2f` decodes to `/` server-side so GitHub routes to main ref deletion, but regex pattern requires literal `refs/heads/main`. LOW severity (attacker-crafted only; not natural mistyping).
  - **B3 wildcard refs**: `gh api -X DELETE repos/O/R/git/refs/heads/m*` — unclear if GitHub expands wildcard; likely rejected by server but worth validating. LOW severity.
  - **HD1 multi-line heredoc body**: `cat <<EOF\n<attack>\nEOF` — $CMD is captured with embedded newlines; grep scans line-by-line so attack line matches as standalone command. Fires fail-closed (MC3 echo-body FP class applied to heredoc). Accept-fail-closed status per FW-045 F1/F2 precedent.
  - **PA-D1/PA-D2 quote-concat DELETE** (FW-044 Pass-2 adversary MEDIUM-D): `gh api -X 'DE''LETE' repos/O/R/git/refs/heads/main` + `gh api -X "DE""LETE" repos/…` — bash concatenates adjacent quoted strings at runtime into a single `DELETE` token, but the regex sees `'DE''LETE'` / `"DE""LETE"` literally with internal quote pairs. Same preprocessing-class root as SP1-SP4 (quote-normalization required before pattern match).
  - **CA1 eval-body-with-escaped-quotes** (FW-044 hotfix-1 COO Pass-1): `eval "PATH=\"foo bar\" gh api -X DELETE refs/heads/main"` — backslash-escaped inner quotes inside quoted eval body require CMD_NORM to collapse `\"`→`"` before pattern match. Same preprocessing-class root as SP1-SP4 quoted-splice.
  - **P2-A1 adjacent-quoted-string concat in VAR_ASSIGN value** (FW-044 hotfix-1 Pass-2): `FOO=''hello world'' gh api -X DELETE refs/heads/main` — bash concatenates adjacent empty-quoted + unquoted + empty-quoted tokens into a single `hello world` token at runtime, but the regex sees `''hello world''` literally. Same preprocessing-class root as PA-D1/PA-D2 quote-concat DELETE.
- **Orthogonal (regex-extension, not preprocessing) scope-gaps — filed here for bundling (FW-044 hotfix-1 Pass-3 Sonnet):**
  - **Full-path shell invocation**: `/bin/bash -c "gh api -X DELETE refs/heads/main"` — shell alternation `(bash|sh|zsh|fish|ksh|dash|ash|csh|tcsh|mksh)` has no leading-slash-optional branch. Fix: add `(/(usr/)?bin/)?(bash|sh|…)` or `([^[:space:]]*/)?(bash|sh|…)` path-prefix optional.
  - **Fused flag `-lc`**: `bash -lc "gh api -X DELETE refs/heads/main"` — shell-c branch requires literal `-c` but `-lc` is common bash idiom (login-shell + command). Fix: `-[a-zA-Z]*c` allowing multi-letter-fused-flag (e.g., `-lc`, `-xc`, `-vxc`). Alt: expand `-c` alternation to `(-c|-lc|-xc|-vc|-rc|-nc|-ec|--command)` explicit.
  - **Wrapper-script indirection**: `./wrapper.sh` / `./bin/push.sh` / `$(command -v gh)` — hook can't read wrapper contents; same dataflow-decoupled class as FW-045 dot-source / xargs-stdin. Fix: fold into FW-040 Phase B (shell-parse-aware write-gate) — not fixable by flat regex.
- **Blast radius:** MEDIUM. All sub-classes require attacker-crafted CTO command with explicit intent to bypass (SP1-SP4 quote-splice, $(…) subshell, %2f URL-encoding, `*` glob, quote-concat, escape-eval, full-path shell, fused-flag, wrapper indirection). Not natural mistyping. Same severity rationale as FW-044 parent. No amplification; straight bypass.
- **Proposed fix:** Apply FW-042 v3.7.2 preprocessing chain to Layer 1. Specifically:
  - Derive `CMD_NORM` at Layer 1 entry: `echo "$CMD" | sed 's/\\"/"/g; s/\\'"'"'/'"'"'/g'` (collapses backslash-escaped quotes).
  - Derive `CMD_UNQUOTED` at Layer 1 entry: strip quote-adjacent characters that bash concatenates at runtime.
  - Use `CMD_UNQUOTED` as input to both Phase 1 and Phase 2 regexes in Layer 1.
  - Add subshell-eval stripping: normalize `$(…)` / backtick substitutions by their content (lexical, not evaluated).
  - URL-decode `%2f`/`%2F`/`%2b`/`%3d` before ref-path matching (or add URL-encoded alternatives to refs/heads/ pattern).
  - Heredoc handling: scan each line of multi-line $CMD with a "command-position" rule (line not preceded by heredoc-body-marker). Complex — may defer separately.
- **ACs:**
  - AC-1: `"gh" api -X DELETE repos/O/R/git/refs/heads/main` → exit=2.
  - AC-2: `g"h" api -X DELETE repos/O/R/git/refs/heads/main` → exit=2.
  - AC-3: `$(echo gh) api -X DELETE repos/O/R/git/refs/heads/main` → exit=2.
  - AC-4: `gh api -X DELETE repos/O/R/git/refs%2fheads%2fmain` → exit=2.
  - AC-5: `cat <<EOF\ngh api user\nEOF` (benign heredoc) → exit=0 (regression — MUST NOT fire on data-position heredoc that doesn't match current Phase 2b).
  - AC-6: `gh api -X 'DE''LETE' repos/O/R/git/refs/heads/main` → exit=2 (quote-concat sq).
  - AC-7: `gh api -X "DE""LETE" repos/O/R/git/refs/heads/main` → exit=2 (quote-concat dq).
  - AC-8: `eval "PATH=\"foo bar\" gh api -X DELETE refs/heads/main"` → exit=2 (CA1 escape-eval).
  - AC-9: `FOO=''hello world'' gh api -X DELETE refs/heads/main` → exit=2 (P2-A1 VAR-concat).
  - AC-10: `/bin/bash -c "gh api -X DELETE refs/heads/main"` → exit=2 (full-path shell).
  - AC-11: `bash -lc "gh api -X DELETE refs/heads/main"` → exit=2 (fused flag `-lc`).
  - AC-12: Full regression: all FW-041/042/043/044/045 harnesses unchanged PASS (including FW-044 hotfix-1 harness). **Result:** 24/24 golden evals PASS; FW-041 Phase 2 7/7 PASS; FW-042 v3.7 adversary 86/86 PASS; FW-045 Pass-5 + Pass-7 all PASS. FW-044 harness 8 "FAILs" are desired FW-051 closures (SP1-4, B2, HD1, PA-D1, PA-D2 now block) — not regressions.
  - **AC-13 (adversary Pass A CRITICAL):** `/usr/bin/env bash -c "git push origin main"` → exit=2. Root cause: env preamble atom required literal `env` at boundary; path-prefixed `/usr/bin/env` had no absorber. Fix: extended env atom to `([^[:space:]]*/)?env(` parallel to the shell-path fix already applied to `(bash|sh|…)`. 3-occurrence replace_all in L1_P1 / L1_P2B / S7_P1. Also verified `/bin/env bash -c …`, `env bash -c …` (plain), and S7 variant `env bash -c "git push"` all block.
  - **AC-14 (adversary Pass A HIGH):** `` `gh` api -X DELETE refs/heads/main `` → exit=2. Root cause: no preprocessing stripped backtick command-substitution wrappers. Fix: added `-e 's/\`\([^\`]*\)\`/\1/g'` to CMD_L1_NORM + CMD_L1_UNQUOTED sed chains in Section 6 + Section 7. Same class as deferred AC-3 `$(echo gh)` but lexically strippable without full parser (no arg-eval semantics — backtick substitution is textual at the regex layer). Also verified Section 7 variant `` `gh` api pulls/42/merge `` blocks.
  - **AC-15 (COO Pass-1 LOW — DQ-wrapped backtick E3 class, DEFERRED):** `` "`gh`" api -X DELETE refs/heads/main `` (V1 literal) + 8 `` "`echo gh`" api … `` variants (V2-V9) bypass triple-scan. Root cause: HAS_SPLICE regex detects quote+letter | letter+quote boundaries, not quote+quote; CMD_L1_UNQUOTED regex excludes backtick interior so post-strip `gh` remains DQ-wrapped, target regex expects bare literal. **Severity LOW, DEFERRED:** V1 runtime-INERT (`` `gh` `` with no args returns help-text → invalid argv[0], command-not-found). V2-V9 are dataflow-decoupled (`$(echo gh)` subshell class) = AC-3 subclass already deferred to FW-040 Phase B. No ship-block; closing V1 alone (~3-line DQ-unwrap after backtick-strip) provides no actual security value since target is inert. Reported by COO Pass-1 adversary (60 probes, SHIP-CLEAN verdict, 2026-04-24). Full variant matrix: `/tmp/fw051-p1-coo-pass1.sh` + `/tmp/fw051-p1-coo-e3-variants.sh` + `/tmp/fw051-p1-coo-e3-exploit.sh` (volatile; promote to `cabinet/tests/hook-regression/` if Phase 2 closes).
- **Effort:** M (~4-5h — CMD_L1_NORM + CMD_L1_UNQUOTED derivations at Layer 1 entry, backtick-strip sed addition, regex shell-var extraction for maintainability, triple-scan if-block refactor, EVAL-014 extension with 8 FW-051 attack-form pins, 2 Sonnet adversary passes Pass-A + Pass-B + COO Pass-1 adversary, baseline + golden + FW-041/042/043/044/045 regression sweep). Adversary Pass A surfaced 2 exploitable bypasses (env path-prefix + backtick splice) + 2 accepted-deferred (AC-9 non-exploit, python3/perl -c → FW-040 Phase B). COO Pass-1 (post-ship) surfaced 1 LOW finding (AC-15 DQ-wrapped backtick E3 class, V1 inert + V2-V9 AC-3 subclass) — documented deferred, no ship-block.
- **Owner:** CTO (shipped).
- **Files modified:** `cabinet/scripts/hooks/pre-tool-use.sh` (Section 6 lines 1159-1201, Section 7 lines 1211-1235 — preprocessing + triple-scan + env path-prefix + backtick-strip); `cabinet/scripts/run-golden-evals.sh` (EVAL-014 shell-var anchor regex + 8 FW-051 positive matrix pins + comment block refresh).
- **Source:** FW-044 ship 2026-04-24. Parent FW-044 scope was "close `gh api -X DELETE refs/heads/main` Phase 2 scope" — unified positional regex approach handled all FW-044-scoped attack forms + FP avoidance, but deferred the 5 preprocessing-class bypasses to this ticket. Pattern: FW-042 was the Section 3b analog; FW-051 extends to Layer 1 + CI Green gate for consistency. FW-051 ship added escape-aware regression fix (RAW $CMD prong preserves `'([^'\\]|\\.)*'` atom semantics for `\'` escapes that CMD_NORM's `\'→'` collapse would break — EVAL-014 guard).
- **Dependencies:** None blocking. FW-042 v3.7.2 CMD_NORM approach is proven pattern — mechanical extension to Layer 1 + Section 7.

### FW-049 — Host cron scheduler silently degraded — briefings + research-sweep not firing (HIGH)
- **Status:** Filed 2026-04-23 20:58 UTC by CoS during autonomy-mode investigation (task #75).
- **Symptom:** Host cron hasn't been firing scheduled Cabinet triggers reliably since at least 2026-04-16. Evidence:
  - Last successful morning briefing key update: `cos:morning-briefing` = **2026-04-17T05:16:37Z** (6 days stale as of filing).
  - Last successful evening briefing key update: `cos:evening-briefing` = **2026-04-16T19:09:59Z** (7 days stale); `cos:briefing-evening` = 2026-04-20T16:59:20Z (3 days stale — key-naming inconsistency contributes to ambiguity, see AC-4).
  - Cos trigger stream has ZERO cron-sender entries in retained window (XLEN=5, all from 2026-04-23 19:26+ UTC — post-incident). MAXLEN cap is ~100 so light traffic would preserve cron triggers if they fired; none present.
  - CRO stream retains back to 2026-04-13; only ONE genuine cron trigger found (`2026-04-14 11:13:07 UTC Scheduled reflection`). Research-sweep cron similarly stale (task #56 already open).
  - Prior CoS→CRO trigger `2026-04-21 06:46:20 UTC` explicitly asked: *"Check if 4h cron is firing on host (your stream last-delivered-id = 2026-04-20 13:11 UTC)."* — same diagnosis surfaced days ago but never root-caused.
- **Symptomatic impact:**
  1. **Captain-facing briefing gap:** 07:00 + 19:00 CEST briefings not delivered to Warroom on schedule. Captain observed the gap and filed as task #75 ("19:00 CEST briefing cron + 2h Captain msg delivery gap"). Contributed to Captain's msg 1647 ("where are we at?") after the token-exhaustion window — no proactive status landed for ~24h before Cabinet came back online because no briefing cron fired either.
  2. **Research-sweep gap:** CRO 4h research sweep not firing; CRO flagged to CoS on 2026-04-21 via trigger.
  3. **Reflection + retro cadence drift:** Same underlying cron degradation affects every scheduled trigger script in `/opt/founders-cabinet/cabinet/cron/` (briefing.sh, backlog-refine.sh, research-sweep.sh, retrospective.sh, retro-trigger.sh).
- **Root-cause candidates (NOT YET DIAGNOSED):**
  1. Host crontab wiped or edited without re-install (no `install-cron.sh` script found in repo — initial install path opaque).
  2. Cron daemon on host stopped/crashed (requires host shell to verify `systemctl status cron` — blocked for CoS container).
  3. Path regression in cron invocation (e.g. `/opt/founders-cabinet/cabinet/cron/briefing.sh` no longer resolvable from cron's restricted env).
  4. Redis URL/password env drift breaking `trigger_send` call from cron context (cron inherits minimal env; /etc/environment.cabinet may be missing or incomplete).
  5. CoS-side: briefings do fire but last-run keys aren't being updated consistently (4 different key naming patterns exist: `cos:briefing`, `cos:briefing-evening`, `cos:morning-briefing`, `cos:evening-briefing`). Lower-probability given parallel CRO/retro evidence.
- **Why HIGH:** Silent degradation of every scheduled Cabinet cadence. Captain-visible (missing briefings). Undermines accountability (overdue founder-action reminders don't fire). Compounds token-exhaustion incidents (no proactive resumption signal).
- **Proposed fix (Phase A — diagnostic):**
  1. From host shell: `crontab -l` (user cabinet) + `crontab -l -u root` to inventory current cron entries.
  2. If absent: commit `cabinet/scripts/install-cron.sh` that installs the correct entries + reports status. Add to bootstrap-host.sh.
  3. Test `redis-cli PING` from inside cron-invoked script to verify env inheritance; source `/etc/environment.cabinet` explicitly at script top (briefing.sh already does — verify others).
  4. Add a canary cron (e.g. `* * * * * redis-cli SET cabinet:cron:canary "$(date -u +%s)"`) → CoS post-tool-use hook reads canary age every 50 calls; if >10min stale, surfaces WARN.
- **Proposed fix (Phase B — robustness):**
  5. Normalize CoS last-run key naming to a single canonical form (spec says `cabinet:schedule:last-run:<role>:<task>`; enforce `<task>` ∈ `{morning-briefing, evening-briefing}`). Delete deprecated variants.
  6. Golden eval similar to existing `eval-006-briefings-on-schedule.md` that asserts: canary key age < 90s across a 3-minute window. Empirical gate, not just config-check.
- **Acceptance criteria:**
  - **AC-1:** Host cron runs both briefings on time (±60s) for 3 consecutive days; last-run keys update each run.
  - **AC-2:** Research-sweep cron (CRO, 4h) fires on time; unblocks task #56.
  - **AC-3:** Canary key mechanism live + surfaced to CoS via post-tool-use (≤50-call-lag WARN).
  - **AC-4:** Single canonical last-run key per briefing (old variants deleted or aliased); CoS updates it atomically on briefing completion.
  - **AC-5:** `install-cron.sh` committed + documented in HOST-SETUP.md; golden eval added and passes.
- **Effort:** M (diagnostic + install-cron + canary + eval + key normalization).
- **Owner:** CTO (infra), CoS (key normalization + eval validation).
- **Blocks:** None in progress — but unblocks reliable briefing cadence + founder-accountability reminders + research-sweep.
- **Related:** task #75 (this investigation), task #56 (research-sweep cron confirmation), FW-047 (trigger-storm incident unrelated but exposed stream retention dynamics used in this diagnosis).
- **Source:** CoS autonomy-mode task-#75 investigation 2026-04-23 20:55-20:58 UTC. Evidence trail in `instance/memory/tier2/cos/briefing-draft-2026-04-21-evening.md` (this session's append).

### FW-042 — pre-tool-use Section 3: substring-match → word-boundary prohibited-command gates ✓ SHIPPED v3.7.2
- **Status:** SHIPPED 2026-04-24 (commits `716fb96` v3.7 + `261f2f1` v3.7.1 hotfix + `e94ca39` v3.7.2 hotfix) after 4 adversary passes + 1 review-agent round + COO Pass-1 BSQ finding.
- **Why:** Original Section 3 used shell-glob substring match (`*"docker"*`, `*"sudo"*`) which silently blocked any command containing the keyword ANYWHERE — including `grep docker file`, `ls docker-compose.yml`, `cat shutdown.md`, `echo "docker runs the world"`. Surface hit officer productivity daily.
- **Approach:** Two-context scan on each CMD:
  - **CMD_STRIPPED** = raw with quoted spans (`'...'`, `"..."`, `$'...'`) + heredoc bodies wiped. Scanned by `CMD_PREAMBLE` (operator-boundary anchor + optional reserved-word prefix + optional VAR=VAL and redirect absorber).
  - **CMD_UNQUOTED** = raw with quoted spans UNWRAPPED (content preserved via sed backref). Scanned by `STRICT_KW_START` (strict boundary-only) gated by **HAS_SPLICE** — which fires only when a command-position adjacent-quote pattern is present. HAS_SPLICE runs on `CMD_MASKED` (quoted interiors replaced with literal `x`, outer quotes preserved) to avoid tripping on interior pipe/ampersand/semicolon inside data quotes.
- **Iteration history (all dates 2026-04-23/04-24):**
  - **v3.0–v3.3**: initial word-boundary design + `CMD_STRIPPED` + heredoc-body strip + env/coproc/BRACE_AFTER_COMMA wrappers.
  - **v3.4**: closed 4 shell-parse adversary findings (eval+wrapper nest, `\sudo` escape, `command -- sudo`, `{rm,}` brace-reverse).
  - **v3.5**: closed 3 regex-internals findings (wide-range SHELL_C absorber, quoted kw inside wrapper arg, backslash before wrapper name, in-eval redirect) + heredoc-body shell-parse scan + quote-interstitial rm class.
  - **v3.6**: closed 7 shell-parse findings (bare `<<<`, full-path PATH_PREFIX, `bash --rcfile FILE -c`, rm flag-order variants, `{,sudo,}` trailing comma, subshell/brace-group inside eval, 11-shell binary enumeration).
  - **v3.7**: closed 2 shell-parse findings — **Finding 1 (leading-redirect)**: `2>&1 KW`, `>/dev/null KW`, `echo hi; 2>&1 KW` — CMD_PREAMBLE absorber extended to consume `[0-9]*[<>]+[&0-9-]*[^[:space:]]*`. **Finding 2 (quoted-token splice)**: `"sudo" ls`, `s"udo" ls`, `"s"udo`, `s'udo' ls` — POSIX adjacent-quote concat fuses to literal kw; CMD_UNQUOTED + STRICT_KW_START + HAS_SPLICE gate introduced.
  - **v3.7.1** (review hotfix): Sonnet review agent found 2 HIGH FPs — **BUG-A** (grep regex with pipe+kw): HAS_SPLICE ran on raw CMD so interior pipes inside quotes falsely triggered; fix: HAS_SPLICE scans CMD_MASKED. **BUG-B** (rm -rf on quoted non-root path): RM_FLEX_QS had no post-slash constraint; fix: terminal `\**['\''"`]*([[:space:];&|)]|$)`.
  - **v3.7.2** (COO Pass-1 hotfix): COO adversary (parallel to review-agent round) found HIGH class bypass — **BSQ** (backslash-escaped quoted-splice): `echo hi;\"sudo\" ls`, `(\"sudo\" ls)`, `{ \"sudo\" ls; }` — 14/15 variants bypassed HAS_SPLICE because `\` between boundary and quote hides quote-adjacent-letter signal. Bash treats `\"` in unquoted context as literal `"` (adjacent-quote concat still fuses at runtime). Fix: **CMD_NORM** pre-processing stage normalizes `\"`→`"` and `\'`→`'` before CMD_STRIPPED / CMD_UNQUOTED / CMD_MASKED derivation, collapsing BSQ to already-defended quoted-splice class. Single-point normalization, no surface missed.
- **Test coverage:** 358 probes across 11 harnesses, 0 FAIL as of v3.7.2 ship.
  - `fw042-v33-delta-harness.sh` (99) — v3.3/v3.4 coverage + FP controls
  - `fw042-v35-adv-validation.sh` (52) — v3.5 adversary fixes
  - `fw042-v36-adv-validation.sh` (55) — v3.6 adversary fixes
  - `fw042-v37-adv-validation.sh` (86) — v3.7 adversary fixes + full regression
  - `fw042-v37-has-splice-check.sh` (20) — HAS_SPLICE gate + FP controls
  - `fw042-v37-has-splice-edge.sh` (17) — HAS_SPLICE edge cases (splice-after-sep, letter-splice, mixed data, mixed-case)
  - `fw042-v37-fp-repro.sh` (11) — v3.7.1 regression controls for BUG-A + BUG-B
  - `fw042-bsq-verify.sh` (18) — v3.7.2 BSQ class closure (14 attack + 4 FP) + COO 19-probe BSQ sweep
- **Deferred to v3.8 / FW-040 Phase B (all low-frequency, officer-callable alternatives exist):**
  - `H3` dot/source file reparse (hook has no file-content visibility — reads target script)
  - `M5` readarray `<<<` array-assignment with kw content
  - `M6` ANSI-C `\n` inside eval single-quoted arg (existing known gap)
  - `H1/H2` pipe-to-shell `echo kw | bash`, process-substitution `bash <(echo kw)` (dataflow-decoupled reparse class)
  - `M7` tilde-parent `rm -rf ~/../../` (RM_FLEX path-traversal class)
  - `H4/H6/M1/M3` var-assignment + param-expansion (`v=sudo; $v ls`, `${!cmd} ls`, IFS-splice, alias) — requires detector for bash-semantic replay
- **Acceptance criteria:** ✓ all harnesses green · ✓ v3.6→v3.7 adversary findings both closed · ✓ v3.7.1 FPs both closed · ✓ v3.7.2 BSQ class closed · ✓ review agent approved after hotfix · ✓ deployed to production hook · ✓ pushed to master · 358/358 passes, 0 regressions.
- **Effort:** L (23 iterations across v3.0→v3.7.2 — heavy regex + adversary-testing surface).
- **Owner:** CTO (shipped).
- **Follow-ups:** Deferred bypass classes above go into a v3.8 scope if any becomes observed in the wild; otherwise rolled into FW-040 Phase B (shell-parse-aware coverage).
- **Source:** Captain directive post-FW-043 to tighten Section 3. Multiple adversary passes (regex-internals + shell-parser Sonnet agents) + 1 pre-push Sonnet code-reviewer + COO concurrent adversary Pass-1 on v3.7 that caught the BSQ class bypass.
