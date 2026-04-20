#!/usr/bin/env python3
"""
Cabinet Admin Bot — Spec 035 Phase A

Telegram bot running as root on the host (NOT in container) via systemd.
Provides Captain-only emergency control commands for the Cabinet:

  /cos ping    — check host-agent status (paused or running)
  /cos pause   — pause host-agent (blocks all CoS host-tool calls)
  /cos resume  — resume host-agent
  /cos restart — restart the CoS container

Security model:
  - Every message checked against captain_user_id from platform.yml.
  - Non-Captain messages are silently dropped with a local log line only.
    No Telegram echo to the sender (avoids leaking presence).
  - Bot token loaded from /etc/cabinet/admin-bot.env.
  - Bot runs outside all Cabinet containers — remains reachable even when
    the entire Docker stack is down.

Dependencies: python-telegram-bot==22.7 (CRO pinned, spec line 222)
Install: pip3 install python-telegram-bot==22.7

Systemd unit: cabinet-admin-bot.service (KillMode=mixed per spec line 170)
"""

import logging
import os
import re
import subprocess
import sys
from pathlib import Path

# python-telegram-bot 22.x uses the Application pattern
# Guard import so config loaders can be tested without the library installed.
try:
    from telegram import Update
    from telegram.ext import (
        Application,
        CommandHandler,
        ContextTypes,
        MessageHandler,
        filters,
    )
    _TELEGRAM_AVAILABLE = True
except ImportError:
    _TELEGRAM_AVAILABLE = False
    # Provide stubs so type annotations in function signatures still work
    # when module is imported for testing config-loader functions only.
    Update = object
    ContextTypes = type("ContextTypes", (), {"DEFAULT_TYPE": None})()

# ----------------------------------------------------------------
# Configuration paths
# ----------------------------------------------------------------
ENV_FILE      = Path("/etc/cabinet/admin-bot.env")
PLATFORM_YML  = Path("/opt/founders-cabinet/instance/config/platform.yml")
PAUSE_FLAG    = Path("/run/cabinet/host-agent.paused")
COMPOSE_FILE  = Path("/opt/founders-cabinet/cabinet/docker-compose.yml")

# ----------------------------------------------------------------
# Logging
# ----------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="[admin-bot] %(levelname)s %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("admin-bot")


# ----------------------------------------------------------------
# Config loaders
# ----------------------------------------------------------------

def load_bot_token() -> str:
    """Load Telegram bot token from /etc/cabinet/admin-bot.env."""
    if not ENV_FILE.exists():
        log.critical("Admin bot env file not found: %s", ENV_FILE)
        log.critical("Run bootstrap-host.sh to configure the token.")
        sys.exit(1)
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if line.startswith("ADMIN_BOT_TOKEN="):
            token = line.split("=", 1)[1].strip()
            if token:
                return token
    log.critical("ADMIN_BOT_TOKEN not found in %s", ENV_FILE)
    sys.exit(1)


def load_captain_user_id() -> int:
    """Load captain Telegram user_id from instance/config/platform.yml.

    Reads `captain_telegram_chat_id:` key. This is the numeric Telegram
    user ID (not the bot token). Messages from any other user are rejected.
    """
    if not PLATFORM_YML.exists():
        log.critical("platform.yml not found at %s", PLATFORM_YML)
        sys.exit(1)

    for line in PLATFORM_YML.read_text().splitlines():
        # Match: captain_telegram_chat_id: "8631324091"
        m = re.match(r'^\s*captain_telegram_chat_id:\s*["\']?(\d+)["\']?', line)
        if m:
            return int(m.group(1))

    log.critical("captain_telegram_chat_id not found in %s", PLATFORM_YML)
    log.critical("Add it as: captain_telegram_chat_id: \"<your_telegram_user_id>\"")
    sys.exit(1)


# ----------------------------------------------------------------
# Sender validation
# ----------------------------------------------------------------

def is_captain(update: Update, captain_user_id: int) -> bool:
    """Return True if the message is from the Captain."""
    user = update.effective_user
    if user is None:
        return False
    return user.id == captain_user_id


async def reject_silently(update: Update, captain_user_id: int) -> None:
    """Log rejection locally; do NOT reply to the sender on Telegram."""
    user = update.effective_user
    user_id = user.id if user else "unknown"
    username = user.username if user else "unknown"
    log.warning(
        "Rejected message from unauthorized user: id=%s username=@%s "
        "(expected captain_id=%s)",
        user_id, username, captain_user_id,
    )
    # Intentionally NO reply to the sender — silent rejection per spec §4


# ----------------------------------------------------------------
# Command handlers
# ----------------------------------------------------------------

async def cmd_cos_ping(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """
    /cos ping — check host-agent status.
    Returns 'pong (host-agent paused)' or 'pong (host-agent running)'.
    """
    captain_user_id: int = context.bot_data["captain_user_id"]

    if not is_captain(update, captain_user_id):
        await reject_silently(update, captain_user_id)
        return

    if PAUSE_FLAG.exists():
        status = "paused"
        reply = "pong (host-agent paused)"
    else:
        status = "running"
        reply = "pong (host-agent running)"

    log.info("ping from Captain — host-agent %s", status)
    await update.message.reply_text(reply)


async def cmd_cos_pause(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """
    /cos pause — create pause flag, blocking all host-agent calls.
    """
    captain_user_id: int = context.bot_data["captain_user_id"]

    if not is_captain(update, captain_user_id):
        await reject_silently(update, captain_user_id)
        return

    try:
        PAUSE_FLAG.parent.mkdir(parents=True, exist_ok=True)
        PAUSE_FLAG.touch(exist_ok=True)
        log.info("Host-agent paused by Captain (flag: %s)", PAUSE_FLAG)
        await update.message.reply_text(
            "CoS host-agent paused. /cos resume to re-enable."
        )
    except OSError as exc:
        log.error("Failed to create pause flag: %s", exc)
        await update.message.reply_text(
            f"Failed to pause host-agent: {exc}"
        )


async def cmd_cos_resume(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """
    /cos resume — remove pause flag, re-enabling host-agent calls.
    """
    captain_user_id: int = context.bot_data["captain_user_id"]

    if not is_captain(update, captain_user_id):
        await reject_silently(update, captain_user_id)
        return

    try:
        if PAUSE_FLAG.exists():
            PAUSE_FLAG.unlink()
            log.info("Host-agent resumed by Captain (flag removed: %s)", PAUSE_FLAG)
            await update.message.reply_text(
                "CoS host-agent resumed. Host tools are now active."
            )
        else:
            await update.message.reply_text(
                "Host-agent was not paused (flag was already absent)."
            )
    except OSError as exc:
        log.error("Failed to remove pause flag: %s", exc)
        await update.message.reply_text(
            f"Failed to resume host-agent: {exc}"
        )


async def cmd_cos_restart(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """
    /cos restart — restart the CoS container and reply with status + recent logs.
    """
    captain_user_id: int = context.bot_data["captain_user_id"]

    if not is_captain(update, captain_user_id):
        await reject_silently(update, captain_user_id)
        return

    log.info("CoS restart requested by Captain")
    await update.message.reply_text("Restarting CoS container...")

    # Restart CoS container
    restart_result = subprocess.run(
        ["docker", "compose", "-f", str(COMPOSE_FILE), "restart", "cos"],
        capture_output=True,
        text=True,
    )
    exit_code = restart_result.returncode

    # Fetch recent logs (first 10 lines per spec §4)
    logs_result = subprocess.run(
        ["docker", "compose", "-f", str(COMPOSE_FILE), "logs", "--tail=10", "cos"],
        capture_output=True,
        text=True,
    )
    log_lines = logs_result.stdout.strip() or logs_result.stderr.strip() or "(no logs)"

    reply = (
        f"docker compose restart cos → exit {exit_code}\n"
        f"\nRecent logs (last 10 lines):\n"
        f"```\n{log_lines}\n```"
    )
    log.info("CoS restart exit=%d", exit_code)
    await update.message.reply_text(reply, parse_mode="Markdown")


# ----------------------------------------------------------------
# Unknown command / message fallback
# ----------------------------------------------------------------

async def cmd_unknown(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Handle /cos with unknown subcommand or any other message from Captain."""
    captain_user_id: int = context.bot_data["captain_user_id"]

    if not is_captain(update, captain_user_id):
        await reject_silently(update, captain_user_id)
        return

    text = update.message.text or ""
    # Only respond if the Captain sent /cos with something unexpected
    if text.startswith("/cos"):
        await update.message.reply_text(
            "Unknown command. Available:\n"
            "  /cos ping — check host-agent status\n"
            "  /cos pause — pause host-agent\n"
            "  /cos resume — resume host-agent\n"
            "  /cos restart — restart CoS container"
        )
    # Other messages from Captain: ignore silently (this bot is for /cos commands only)


# ----------------------------------------------------------------
# Command router
# ----------------------------------------------------------------
# python-telegram-bot dispatches on the bot command name. /cos is treated
# as a command with subcommands passed as args. We register /cos and parse
# args inside the handler.

async def cmd_cos_router(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Route /cos <subcommand> to the appropriate handler."""
    captain_user_id: int = context.bot_data["captain_user_id"]

    if not is_captain(update, captain_user_id):
        await reject_silently(update, captain_user_id)
        return

    args = context.args or []
    subcommand = args[0].lower() if args else ""

    if subcommand == "ping":
        await cmd_cos_ping(update, context)
    elif subcommand == "pause":
        await cmd_cos_pause(update, context)
    elif subcommand == "resume":
        await cmd_cos_resume(update, context)
    elif subcommand == "restart":
        await cmd_cos_restart(update, context)
    else:
        await update.message.reply_text(
            "Available commands:\n"
            "  /cos ping — check host-agent status\n"
            "  /cos pause — pause host-agent\n"
            "  /cos resume — resume host-agent\n"
            "  /cos restart — restart CoS container"
        )


# ----------------------------------------------------------------
# Main
# ----------------------------------------------------------------

def main() -> None:
    if not _TELEGRAM_AVAILABLE:
        log.critical(
            "python-telegram-bot is not installed. "
            "Install with: pip3 install python-telegram-bot==22.7"
        )
        sys.exit(1)

    token = load_bot_token()
    captain_user_id = load_captain_user_id()

    log.info("Starting admin bot (captain_user_id=%d)", captain_user_id)

    app = Application.builder().token(token).build()

    # Store captain_user_id in bot_data for access in handlers
    app.bot_data["captain_user_id"] = captain_user_id

    # Register /cos command handler
    app.add_handler(CommandHandler("cos", cmd_cos_router))

    # Catch-all for unknown messages (from Captain: show help; from others: reject silently)
    app.add_handler(
        MessageHandler(filters.TEXT & ~filters.COMMAND, cmd_unknown)
    )

    log.info("Admin bot running. Polling for updates.")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
