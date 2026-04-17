# Provisioning a Personal Cabinet

When Phase 2 framework ready (this doc's scope) meets Captain-ready (your answers to the 5 decisions below), standing up the Personal Cabinet is a 30-minute operation. This is the step-by-step.

## Prerequisites — 5 decisions you own

Framework prep built around these being deferred. Answer them before starting.

1. **Host (`CD_P1`).** Three realistic options:
   - **Same-host separate Docker stack** — simplest, cheapest. Two `docker compose` stacks on the same VM, each with its own Postgres/Redis. Budget $0 extra, operational cost near-zero. Recommended unless separation concern is high.
   - **Separate VPS** — full physical separation. Budget $10-40/month depending on provider. Recommended if Work data has legal/compliance exposure that personal data shouldn't share a host with.
   - **Mac mini (local)** — if Captain has spare hardware and wants Personal truly off-cloud. Extra ops burden (uptime, backups, updates are yours).
2. **Telegram bots (`CD_P2`).** Create one bot per personal-capacity agent via @BotFather. At minimum: a CoS for Personal (even if it's you-of-cabinet-B; separate identity), a Physical Coach bot, a Mindfulness Coach bot. Grab tokens; put them in the Personal Cabinet's `cabinet/.env`.
3. **Personal warroom chat.** Create a Telegram group named e.g. "Personal Cabinet," add the bots. Grab the chat_id. For Personal preset the warroom is optional — Captain-DM can be the only channel — but a warroom helps if multiple coaches are active.
4. **Calendar source (`CD_P3`).** Pick one: manual (edit `instance/config/calendar.yml` by hand), Google Calendar (needs OAuth + client secret), CalDAV (endpoint + credentials), Apple Calendar (CalDAV via iCloud). Phase 2 ships manual; live integrations are future work.
5. **Physical Coach: live day 1, or wait (`CD_P5`)?** Either works — content ships either way. "Wait" = the scaffold stays scaffold, you don't create a bot for it yet. "Live day 1" = full hire, bot active from first session.

## What the framework already ships (you don't need to build)

- `presets/personal/` populated — constitution addendum, safety addendum, 4 schemas (longitudinal_metrics, coaching_narratives, coaching_consent_log, coaching_experiments), 2 agent scaffolds (physical-coach, mindfulness-coach)
- Cabinet MCP with 5 tools (identify, presence, availability, send_message, request_handoff); transport stdio for Phase 2, HTTP-ready signatures for Phase 3
- `peers.yml` config schema + loader validation at boot (`CABINET_MODE=multi` enforces, single-mode warns)
- Trust policy enforcement in `pre-tool-use.sh` §10
- `split-cabinet.sh` migration — dry-run default, `--apply` to execute; covers all 8 Cabinet-infrastructure tables
- 41-test behavior-level golden eval at `memory/golden-evals/phase-2/pre-captain-test.sh`

## Step-by-step

### Step 1 — Pick host (CD_P1) and copy framework

Option: same-host separate Docker stack. (Adjust if you chose otherwise.)

```bash
cp -r /opt/founders-cabinet /opt/founders-cabinet-personal
cd /opt/founders-cabinet-personal
```

Two filesystem layouts now: Work stays at `/opt/founders-cabinet`, Personal at `/opt/founders-cabinet-personal`.

### Step 2 — Set active preset to personal

```bash
echo personal > /opt/founders-cabinet-personal/instance/config/active-preset
```

### Step 3 — Set Cabinet identity env

Edit `/opt/founders-cabinet-personal/cabinet/.env`:

```
CABINET_ID=personal
CABINET_MODE=multi
CABINET_CAPACITY=personal
# ... existing Neon/Telegram/etc. env unchanged for now; you'll update after steps 4-5
```

### Step 4 — Create Telegram bots (CD_P2) + populate .env

Via @BotFather: create bots for each personal agent you plan to hire. For a minimal Phase-2 start, one bot is enough (Physical Coach scaffolded; actual hire TBD per CD_P5). Put tokens in `cabinet/.env`:

```
TELEGRAM_PHYSICALCOACH_TOKEN=...
TELEGRAM_HQ_CHAT_ID=<personal-warroom-group-id>
```

### Step 5 — Update `instance/config/peers.yml` on BOTH Cabinets

**On `/opt/founders-cabinet/` (Work Cabinet):** flip the `personal` peer `consented_by_captain` from `false` to `true`:

```yaml
peers:
  personal:
    ...
    consented_by_captain: true
```

**On `/opt/founders-cabinet-personal/` (Personal Cabinet):** add a reciprocal `work` peer. IMPORTANT: the endpoint points at the **Work Cabinet's** server.py (the one you're communicating with), not your own — but the path must match wherever Work Cabinet lives on this host:

```yaml
peers:
  work:
    role: work-cabinet
    endpoint: stdio:/opt/founders-cabinet/cabinet/mcp-server/server.py   # WORK Cabinet's server
    capacity: work
    trust_level: high
    consented_by_captain: true
    allowed_tools:
      - identify
      - presence
      - availability
      - send_message
      - request_handoff
```

And symmetrically on Work Cabinet's peers.yml, the `personal` peer's `endpoint:` line must point at the Personal Cabinet's server:

```yaml
peers:
  personal:
    endpoint: stdio:/opt/founders-cabinet-personal/cabinet/mcp-server/server.py   # PERSONAL Cabinet's server
```

Each Cabinet points at the OTHER Cabinet's server.py — never its own.

### Step 6 — Populate the hired-agent list in `cabinet/mcp-scope.yml` on Personal Cabinet

Move `physical-coach` (and `mindfulness-coach` if you're hiring both) from `scaffolds:` to `agents:` in `/opt/founders-cabinet-personal/cabinet/mcp-scope.yml`. Leave other entries as-is.

### Step 7 — Migrate personal-capacity data

From Work Cabinet root, dry-run first:

```bash
cd /opt/founders-cabinet
bash cabinet/scripts/split-cabinet.sh --target-cabinet personal --capacity personal
```

Review the counts + sample rows. When satisfied, apply:

```bash
bash cabinet/scripts/split-cabinet.sh --target-cabinet personal --capacity personal --apply
```

Phase 2 note: this restamps `cabinet_id` in the SHARED DBs (Work + Personal Cabinets share one Postgres + one Neon during Phase 2). Phase 3 later adds separate DBs + cross-DB INSERT mode.

### Step 8 — Boot Personal Cabinet

```bash
cd /opt/founders-cabinet-personal
bash cabinet/scripts/load-preset.sh    # validates env, applies schemas, populates agents
bash cabinet/scripts/start-officer.sh physical-coach    # or whichever agents you're hiring
```

Verify heartbeat:

```bash
redis-cli -h redis -p 6379 GET cabinet:heartbeat:physical-coach
```

### Step 9 — Smoke-test inter-Cabinet comms

From Work Cabinet, invoke `mcp__cabinet__presence` on `personal`. Expected: `status: online` with a fresh `last_seen` timestamp.

From Work Cabinet, invoke `mcp__cabinet__send_message` with `to_cabinet=personal`. Check that the message lands in Redis stream `cabinet:inbox:personal` and Personal Cabinet's CoS picks it up.

### Step 10 — Create the Captain-facing context

Edit `/opt/founders-cabinet-personal/instance/config/contexts/` to add real personal contexts (beyond the placeholder `personal.yml`). Example: `sleep.yml`, `training.yml`, `mindfulness.yml` — whatever slicing makes sense for how you think about your life.

## Verification checklist

Before declaring Personal Cabinet live:

- [ ] `bash memory/golden-evals/phase-2/pre-captain-test.sh` — 41/41 PASS on Work Cabinet
- [ ] Same suite on Personal Cabinet adapted for personal preset (see below)
- [ ] `mcp__cabinet__identify` on Personal returns `cabinet_id=personal, capacity=personal`
- [ ] `mcp__cabinet__presence` between the two Cabinets returns `online`
- [ ] A test message sent Work → Personal lands in the right Redis stream
- [ ] Physical Coach (or whichever coach you hired) responds to a Captain DM
- [ ] A dry-run `split-cabinet.sh` with `--capacity work` targeting `work` from Personal side returns `0 rows to restamp` (sanity: no work-capacity data should have migrated)

## What to do if it goes wrong

- **Personal Cabinet won't boot.** Check `bash load-preset.sh` output for schema errors. `CABINET_MODE=multi` with invalid peers.yml aborts — that's intentional. Fix peers.yml and retry.
- **Trust policy blocks legitimate calls.** Confirm `consented_by_captain: true` AND the tool name is in `allowed_tools`. The hook's error message names exactly what's wrong.
- **split-cabinet moved too many / too few rows.** Re-run dry-run with the migrated state to confirm. If you need to undo: `split-cabinet.sh --target-cabinet main --capacity <cap> --apply` restamps them back.

## Rollback

If Personal Cabinet isn't working out:

```bash
cd /opt/founders-cabinet
bash cabinet/scripts/split-cabinet.sh --target-cabinet main --capacity personal --apply    # restamp rows back
# Stop Personal Cabinet's docker stack
# Remove /opt/founders-cabinet-personal/
# Flip peers.yml `personal.consented_by_captain` back to false on Work Cabinet
```

No framework changes needed. Phase 2 is additive; rollback is per-row + per-filesystem-tree.
