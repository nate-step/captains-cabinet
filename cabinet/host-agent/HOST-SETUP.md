# Host Pre-requisites — FW-018 Phase A

What a fresh host needs before `bootstrap-host.sh` succeeds end-to-end. Captured live during 2026-04-21 first-install.

## System packages (apt)

`bootstrap-host.sh` requires these commands present (or it dies fast):

- `systemctl` (always present on systemd hosts)
- `logrotate` — usually pre-installed
- `python3` — usually pre-installed
- `chattr` — pre-installed (in `e2fsprogs`)

Also needed — **now auto-installed by bootstrap** (2026-04-21, task #49 closed):

- `python3-pip` — bootstrap runs `apt install -y python3-pip` if missing. Ubuntu 24.04 ships python3 *without* pip.

## Python packages (pip)

`bootstrap-host.sh` auto-installs these on fresh hosts (2026-04-21, task #49 closed):

- `python-telegram-bot==22.7` — bootstrap runs `pip3 install --break-system-packages python-telegram-bot==22.7` if import fails.
  - Version pin matches CRO library pressure-test (KillMode=mixed compat, no breaking changes vs Spec 035 wire shape)
  - `--break-system-packages` is needed on Python 3.12+ (PEP 668)

## One-time fresh-host install

```bash
sudo bash /opt/founders-cabinet/cabinet/host-agent/bootstrap-host.sh
# bootstrap will prompt for the BotFather admin bot token; paste it
sudo systemctl restart cabinet-admin-bot && sleep 3 && sudo systemctl status cabinet-admin-bot
```

Then verify from your phone:

1. DM `@<your_admin_bot_username>` → start the chat
2. Send `/cos ping` → expect `pong (host-agent running)`

If status shows `active (running)` and the ping responds, FW-018 Phase A is live.

## What bootstrap *does* install correctly

- Creates `cabinet-cos` user (UID 60001) for socket peer-cred auth
- Installs `/etc/cabinet/admin-bot.env` (mode 0600) with the admin-bot token
- Installs systemd units `cabinet-host-agent.service` and `cabinet-admin-bot.service`
- Creates `/var/log/cabinet/cos-actions.jsonl` with `chattr +a` (append-only audit log)
- Installs logrotate config for the audit log
- Enables both services to start at boot

## Follow-ups (035-hardening)

- Long-term: ship admin-bot in a venv to avoid `--break-system-packages`
- Long-term: lock specific apt + pip versions in a manifest for reproducibility
