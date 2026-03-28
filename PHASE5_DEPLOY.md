# Phase 5: Hardening — Deployment Guide

## What's New

### 1. Officer Auto-Restart (Supervisor)
A background loop inside the officers container that checks every 2 minutes:
- Is the tmux session alive?
- Does each officer's window still exist?
- Is claude still running inside the window?

If an officer crashes, it auto-restarts and alerts you via Telegram.

**Key behaviors:**
- Respects the kill switch — won't restart during emergency stop
- 5-minute cooldown between restarts of the same officer (prevents restart loops)
- Tracks restart counts in Redis (`cabinet:supervisor:restart-count:<officer>`)
- Only restarts officers marked as `cabinet:officer:expected:active` in Redis

### 2. Cost Dashboard
Daily at 20:00 CET, you get a Telegram message showing:
- Today's spending vs. daily limit (with progress bar)
- Yesterday's spending for comparison
- Monthly running total
- Per-officer breakdown
- Officer health status (✅/🔴/⏸️)
- Auto-restart counts

You can also trigger it manually from the watchdog container:
```bash
docker exec sensed-watchdog bash /opt/watchdog/cost-dashboard.sh
```

### 3. Kill Switch Escalation Test
A test script that verifies the full chain:
```bash
# Dry run (safe, just checks Redis connectivity)
docker exec sensed-watchdog bash /opt/watchdog/test-escalation.sh

# Live test (actually sets and clears the kill switch — officers pause briefly!)
docker exec sensed-watchdog bash /opt/watchdog/test-escalation.sh --live
```

## Deployment Steps

### Step 1: Push and Pull
On your Mac:
```bash
cd ~/founders-cabinet  # or wherever your local repo is
git pull
git push
```

On the server:
```bash
cd /opt/founders-cabinet
git pull
```

### Step 2: Rebuild Both Containers
The supervisor is in the entrypoint (officers container) and the cost dashboard is baked into the watchdog image.

```bash
cd /opt/founders-cabinet/cabinet
docker compose build officers watchdog
```

### Step 3: Restart Containers
```bash
docker compose up -d officers watchdog
```

⚠️ **This will restart all officers.** You'll need to re-start each officer's claude session:

```bash
docker exec -it -u cabinet sensed-officers bash
/home/cabinet/start-officer.sh cos
/home/cabinet/start-officer.sh cto
/home/cabinet/start-officer.sh cpo
/home/cabinet/start-officer.sh cro
```

Each will need OAuth re-authentication (open the URL, log in, come back).

### Step 4: Mark Officers as Expected-Active
The supervisor only watches officers marked active in Redis:
```bash
docker exec sensed-redis redis-cli SET cabinet:officer:expected:cos active
docker exec sensed-redis redis-cli SET cabinet:officer:expected:cto active
docker exec sensed-redis redis-cli SET cabinet:officer:expected:cpo active
docker exec sensed-redis redis-cli SET cabinet:officer:expected:cro active
```

### Step 5: Run the Escalation Test (Dry Run)
```bash
docker exec sensed-watchdog bash /opt/watchdog/test-escalation.sh
```
Should show all tests passing.

### Step 6: Run the Escalation Test (Live)
```bash
docker exec sensed-watchdog bash /opt/watchdog/test-escalation.sh --live
```
This briefly activates and then deactivates the kill switch. Officers will be blocked for a few seconds during the test.

### Step 7: Trigger Cost Dashboard Manually
```bash
docker exec sensed-watchdog bash /opt/watchdog/cost-dashboard.sh
```
Check your Telegram — you should receive a formatted cost report.

### Step 8: 48-Hour Autonomous Run
Let the Cabinet run for 48 hours without intervention. Monitor:
- Telegram: daily briefings at 07:00/19:00, cost dashboard at 20:00
- Health alerts (should be none if supervisor is working)
- Officer work quality via Telegram DMs

## Monitoring During the 48h Run

| What to watch | Where | Expected |
|--------------|-------|----------|
| Daily briefings | Telegram (CoS DM) | 07:00 + 19:00 CET |
| Cost dashboard | Telegram (CoS DM) | 20:00 CET |
| Health alerts | Telegram (CoS DM) | None (supervisor handles restarts) |
| Auto-restart alerts | Telegram (CoS DM) | 🔄 messages if any officer crashes |
| Officer work | Each bot's DM | Responding to triggers, doing assigned work |

## Kill Switch (Emergency Stop)
If anything goes wrong during the 48h run:
```bash
docker exec sensed-redis redis-cli SET cabinet:killswitch active
```
This immediately blocks ALL officer tool use. To resume:
```bash
docker exec sensed-redis redis-cli DEL cabinet:killswitch
```
