# Phase 1 — Remaining Steps (Server-Side)

Run these on the server: `ssh root@81.27.108.164`

---

## Step 1: Pull the fixes

The cron scripts and watchdog entrypoint had bugs (dead `$TRIGGER_FILE` references, fragile `sed` injection). These are now fixed in the repo.

```bash
cd /opt/founders-cabinet
git pull origin master
```

## Step 2: Rebuild and start the Watchdog

The Watchdog container needs to be rebuilt (Dockerfile copies the fixed scripts at build time):

```bash
cd /opt/founders-cabinet/cabinet
docker compose build watchdog
docker compose up -d watchdog
```

Verify it's running:
```bash
docker compose ps watchdog
docker compose logs watchdog --tail 20
```

You should see the "Sensed Cabinet — Watchdog Starting" banner with the cron schedule listed.

## Step 3: Mark CoS as expected (so health checks work)

The health-check script only monitors Officers flagged as "expected":

```bash
docker exec cabinet-redis redis-cli SET cabinet:officer:expected:cos active
```

(Don't set cto/cro/cpo yet — they're not running.)

## Step 4: Backup OAuth credentials

Save the CoS OAuth credentials so you can restore them if the container is rebuilt:

```bash
docker exec cabinet-officers cat /home/cabinet/.claude/.credentials.json > /opt/founders-cabinet/.oauth-backup-cos.json
chmod 600 /opt/founders-cabinet/.oauth-backup-cos.json
```

## Step 5: Give CoS the gap analysis assignment

Open the CoS tmux session:
```bash
docker exec -it cabinet-officers bash -c "su - cabinet -c 'tmux attach -t cabinet'"
```

Switch to the CoS window (Ctrl-B then `1` or whichever window number). Then send this message via Telegram DM to @sensed_cos_bot:

> Your first assignment is ready at `shared/interfaces/cos-first-assignment.md`. Read it and execute. This is a gap analysis — discover the product, audit the business brain in Notion, assess the Linear backlog, verify Cabinet infrastructure, then produce a full gap analysis doc in Notion and brief me. Take your time and be thorough.

Or just paste it directly into the CoS Claude Code session if you'd rather skip Telegram for this one.

## Step 6: Verify everything

After a few minutes:
```bash
# Check watchdog health logs
docker compose logs watchdog --tail 30

# Check Redis for health keys
docker exec cabinet-redis redis-cli GET cabinet:health:cos

# Check CoS is producing output
docker exec cabinet-officers bash -c "su - cabinet -c 'tmux capture-pane -t cabinet:officer-cos -p | tail -20'"
```

---

## What Changed in This Session

1. **Fixed 4 cron scripts** (`briefing.sh`, `research-sweep.sh`, `backlog-refine.sh`, `retrospective.sh`): Removed dead `$TRIGGER_FILE` references left over from the removed inbox approach. Redis delivery was already correct.

2. **Fixed `watchdog-entrypoint.sh`**: Replaced fragile `sed` injection with explicit `source /etc/environment.cabinet` in each script. Cron env vars now load reliably.

3. **Added env sourcing**: All Watchdog scripts (`health-check.sh`, `token-refresh-watch.sh`, 4 cron scripts) now explicitly source `/etc/environment.cabinet` for cron compatibility.

4. **Created CoS first assignment**: `shared/interfaces/cos-first-assignment.md` — structured gap analysis covering product, business brain, backlog, and infrastructure.
