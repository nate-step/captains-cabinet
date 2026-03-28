# Phase 2 — Activate CTO + CPO

Run these on the server: `ssh root@81.27.108.164`

---

## Prerequisites

- Phase 1 complete (CoS running, Watchdog running)
- Telegram bots already created: @sensed_cto_bot, @sensed_cprod_bot
- Bot tokens already in `.env` as `TELEGRAM_CTO_TOKEN` and `TELEGRAM_CPO_TOKEN`

Verify tokens are set:
```bash
grep -E 'TELEGRAM_CTO_TOKEN|TELEGRAM_CPO_TOKEN' /opt/founders-cabinet/cabinet/.env
```

If either is empty, get the token from @BotFather on Telegram and add it.

---

## Step 1: Pull latest changes

```bash
cd /opt/founders-cabinet
git pull origin master
```

This brings in the first assignment files and any framework updates.

## Step 2: Enter the Officers container

```bash
docker exec -it sensed-officers bash -c "su - cabinet"
```

You're now inside the container as the `cabinet` user.

## Step 3: Start the CTO Officer

```bash
/home/cabinet/start-officer.sh cto
```

This creates a new tmux window `officer-cto` and launches Claude Code with:
- Telegram Channels plugin connected to @sensed_cto_bot
- `--dangerously-skip-permissions` enabled
- `--effort max` (Opus 4.6)

**OAuth login:** Claude Code will print a login URL. Copy it, open in your browser, authenticate with your Max subscription. Same process as CoS.

**Tip for the long URL:** If tmux wraps the URL and it's hard to copy, open a second SSH session and run:
```bash
docker exec sensed-officers bash -c "cat /tmp/login-url.txt 2>/dev/null || echo 'No URL file found — copy from tmux'"
```

Or authenticate Claude Code locally on your Mac first, then copy credentials:
```bash
# On your Mac:
cat ~/.claude/.credentials.json
# Copy the JSON, then on the server:
docker exec sensed-officers bash -c "cat > /home/cabinet/.claude/.credentials.json << 'CREDS'
<paste JSON here>
CREDS"
```

## Step 4: Verify CTO is connected

Once authenticated, the CTO session should be running. In the tmux session:
- Switch to the CTO window: `Ctrl-B` then select window `officer-cto`
- You should see Claude Code running with the Channels plugin active
- DM @sensed_cto_bot on Telegram — it should respond

## Step 5: Start the CPO Officer

```bash
/home/cabinet/start-officer.sh cpo
```

Same OAuth process. Authenticate, verify by DMing @sensed_cprod_bot.

## Step 6: Mark Officers as expected

Exit the container (`exit`) and set Redis flags so the Watchdog monitors them:

```bash
docker exec sensed-redis redis-cli SET cabinet:officer:expected:cto active
docker exec sensed-redis redis-cli SET cabinet:officer:expected:cpo active
```

## Step 7: Backup OAuth credentials

```bash
docker exec sensed-officers cat /home/cabinet/.claude/.credentials.json > /opt/founders-cabinet/.oauth-backup-all.json
chmod 600 /opt/founders-cabinet/.oauth-backup-all.json
```

Note: All Officers share the same Claude auth (same Max subscription). The credential file is shared. You only need to authenticate once — but back it up after each new Officer starts in case the auth refreshes.

## Step 8: Send first assignments

DM each bot on Telegram:

**To @sensed_cto_bot:**
> Your first assignment is ready at `shared/interfaces/cto-first-assignment.md`. Read it and execute. Deep dive the codebase, database, and build pipeline. Produce an engineering assessment in Notion Engineering Hub. Take your time and be thorough.

**To @sensed_cprod_bot:**
> Your first assignment is ready at `shared/interfaces/cpo-first-assignment.md`. Read it and execute. Absorb the business brain, audit the Linear backlog, and produce a product roadmap in Notion Product Hub. Take your time and be thorough.

## Step 9: Verify inter-officer communication

Once both Officers are working, test the Redis notification system:

```bash
# From inside the container as cabinet:
bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cto "Test notification from Captain setup"
bash /opt/founders-cabinet/cabinet/scripts/notify-officer.sh cpo "Test notification from Captain setup"
```

The Officers should receive these as `⏰ PENDING TRIGGERS` in their next tool call.

## Step 10: Monitor

```bash
# Check all Officers are healthy
docker exec sensed-redis redis-cli GET cabinet:health:cos
docker exec sensed-redis redis-cli GET cabinet:health:cto
docker exec sensed-redis redis-cli GET cabinet:health:cpo

# Watch Watchdog logs
cd /opt/founders-cabinet/cabinet
docker compose logs watchdog --tail 30

# View tmux windows
docker exec -it sensed-officers bash -c "su - cabinet -c 'tmux list-windows -t cabinet'"
```

---

## Troubleshooting

**OAuth URL hard to copy from tmux:**
Use `Ctrl-B [` to enter tmux copy mode, scroll to the URL, select it. Or use the second-SSH-tab trick above.

**"API key overrides subscription" warning:**
Make sure `ANTHROPIC_API_KEY` is empty or unset in `.env`. If set, Claude Code uses pay-per-token API instead of your Max subscription.

**Officer crashes immediately:**
Check if the bot token is correct. Enter the container and try starting manually:
```bash
docker exec -it sensed-officers bash -c "su - cabinet"
export TELEGRAM_CTO_TOKEN=<token>
claude --channels plugin:telegram@claude-plugins-official --dangerously-skip-permissions --effort max
```

**Officers can't see each other's notifications:**
Verify Redis is running: `docker exec sensed-redis redis-cli PING` should return `PONG`.
