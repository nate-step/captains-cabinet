#!/usr/bin/env python3
"""
Admin Bot Tests — Spec 035 Phase A

pytest coverage for:
  - Sender rejection (non-Captain messages silently dropped)
  - /cos ping when host-agent paused vs running
  - /cos pause — creates pause flag
  - /cos resume — removes pause flag
  - /cos restart — calls docker compose restart + returns logs

Run:
    cd /opt/founders-cabinet/cabinet/admin-bot
    python -m pytest test_bot.py -v

All tests mock the Telegram API and filesystem.
Does NOT require a live Telegram bot token.
"""

import asyncio
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, Mock, patch, call

# Add parent dir to path
sys.path.insert(0, str(Path(__file__).parent))
sys.path.insert(0, str(Path(__file__).parent.parent.parent))

# Mock Telegram dependencies before importing bot module
# python-telegram-bot may not be installed in the test environment
try:
    from telegram import Update, User, Message
    from telegram.ext import ContextTypes
    TELEGRAM_AVAILABLE = True
except ImportError:
    TELEGRAM_AVAILABLE = False

# ----------------------------------------------------------------
# Helpers for making mock Telegram objects
# ----------------------------------------------------------------

def make_mock_update(user_id: int, text: str = "/cos ping", args: list = None):
    """Create a mock Update object that simulates a Telegram message."""
    mock_user = MagicMock()
    mock_user.id = user_id
    mock_user.username = f"user_{user_id}"

    mock_message = MagicMock()
    mock_message.text = text
    mock_message.reply_text = AsyncMock()

    mock_update = MagicMock()
    mock_update.effective_user = mock_user
    mock_update.message = mock_message

    return mock_update


def make_mock_context(captain_user_id: int, args: list = None):
    """Create a mock ContextTypes.DEFAULT_TYPE with bot_data and args."""
    mock_context = MagicMock()
    mock_context.bot_data = {"captain_user_id": captain_user_id}
    mock_context.args = args or []
    return mock_context


CAPTAIN_ID = 8631324091
OTHER_USER_ID = 1234567890


# ----------------------------------------------------------------
# Config loader tests (no Telegram dependency)
# ----------------------------------------------------------------

class TestConfigLoaders(unittest.TestCase):

    def test_load_captain_user_id_from_platform_yml(self):
        """load_captain_user_id must parse captain_telegram_chat_id."""
        import bot as bot_module
        yml_content = 'captain_telegram_chat_id: "8631324091"\n'
        with patch("builtins.open", unittest.mock.mock_open(read_data=yml_content)):
            with patch.object(Path, "exists", return_value=True):
                with patch.object(Path, "read_text", return_value=yml_content):
                    uid = bot_module.load_captain_user_id()
        self.assertEqual(uid, 8631324091)
        self.assertIsInstance(uid, int)

    def test_load_bot_token_from_env_file(self):
        """load_bot_token must extract ADMIN_BOT_TOKEN from env file."""
        import bot as bot_module
        env_content = "ADMIN_BOT_TOKEN=test-token-12345\n"
        with patch.object(Path, "exists", return_value=True):
            with patch.object(Path, "read_text", return_value=env_content):
                token = bot_module.load_bot_token()
        self.assertEqual(token, "test-token-12345")

    def test_load_bot_token_missing_file_exits(self):
        """Missing env file must call sys.exit(1)."""
        import bot as bot_module
        with patch.object(Path, "exists", return_value=False):
            with self.assertRaises(SystemExit) as ctx:
                bot_module.load_bot_token()
            self.assertEqual(ctx.exception.code, 1)


# ----------------------------------------------------------------
# Sender validation tests
# ----------------------------------------------------------------

@unittest.skipUnless(TELEGRAM_AVAILABLE, "python-telegram-bot not installed")
class TestSenderValidation(unittest.IsolatedAsyncioTestCase):

    async def test_non_captain_message_rejected_silently(self):
        """Non-Captain update must be dropped with NO Telegram reply."""
        import bot as bot_module

        update = make_mock_update(OTHER_USER_ID, "/cos ping")
        context = make_mock_context(CAPTAIN_ID, args=["ping"])

        with patch.object(Path, "exists", return_value=False):  # not paused
            await bot_module.cmd_cos_router(update, context)

        # CRITICAL: no reply must be sent to the unauthorized user
        update.message.reply_text.assert_not_called()

    async def test_captain_message_is_accepted(self):
        """Captain's /cos ping must get a reply."""
        import bot as bot_module

        update = make_mock_update(CAPTAIN_ID, "/cos ping")
        context = make_mock_context(CAPTAIN_ID, args=["ping"])

        with patch.object(Path, "exists", return_value=False):  # not paused
            await bot_module.cmd_cos_router(update, context)

        update.message.reply_text.assert_called_once()

    async def test_is_captain_returns_true_for_captain(self):
        """is_captain must return True for matching user_id."""
        import bot as bot_module
        update = make_mock_update(CAPTAIN_ID)
        self.assertTrue(bot_module.is_captain(update, CAPTAIN_ID))

    async def test_is_captain_returns_false_for_other(self):
        """is_captain must return False for non-Captain user_id."""
        import bot as bot_module
        update = make_mock_update(OTHER_USER_ID)
        self.assertFalse(bot_module.is_captain(update, CAPTAIN_ID))

    async def test_is_captain_returns_false_for_none_user(self):
        """is_captain must return False when effective_user is None."""
        import bot as bot_module
        update = MagicMock()
        update.effective_user = None
        self.assertFalse(bot_module.is_captain(update, CAPTAIN_ID))


# ----------------------------------------------------------------
# /cos ping tests
# ----------------------------------------------------------------

@unittest.skipUnless(TELEGRAM_AVAILABLE, "python-telegram-bot not installed")
class TestCosPing(unittest.IsolatedAsyncioTestCase):

    async def test_ping_when_not_paused_returns_running(self):
        """ping must return 'pong (host-agent running)' when flag absent."""
        import bot as bot_module

        update = make_mock_update(CAPTAIN_ID, "/cos ping")
        context = make_mock_context(CAPTAIN_ID, args=["ping"])

        with patch.object(Path, "exists", return_value=False):
            await bot_module.cmd_cos_router(update, context)

        update.message.reply_text.assert_called_once_with(
            "pong (host-agent running)"
        )

    async def test_ping_when_paused_returns_paused(self):
        """ping must return 'pong (host-agent paused)' when flag present."""
        import bot as bot_module

        update = make_mock_update(CAPTAIN_ID, "/cos ping")
        context = make_mock_context(CAPTAIN_ID, args=["ping"])

        with patch.object(Path, "exists", return_value=True):
            await bot_module.cmd_cos_router(update, context)

        update.message.reply_text.assert_called_once_with(
            "pong (host-agent paused)"
        )


# ----------------------------------------------------------------
# /cos pause tests
# ----------------------------------------------------------------

@unittest.skipUnless(TELEGRAM_AVAILABLE, "python-telegram-bot not installed")
class TestCosPause(unittest.IsolatedAsyncioTestCase):

    async def test_pause_creates_flag_file(self):
        """pause must touch /run/cabinet/host-agent.paused."""
        import bot as bot_module

        update = make_mock_update(CAPTAIN_ID, "/cos pause")
        context = make_mock_context(CAPTAIN_ID, args=["pause"])

        with tempfile.TemporaryDirectory() as tmpdir:
            pause_flag = Path(tmpdir) / "host-agent.paused"

            with patch.object(bot_module, "PAUSE_FLAG", pause_flag):
                self.assertFalse(pause_flag.exists())
                await bot_module.cmd_cos_router(update, context)
                self.assertTrue(pause_flag.exists())

        update.message.reply_text.assert_called_once()
        call_text = update.message.reply_text.call_args[0][0]
        self.assertIn("paused", call_text.lower())
        self.assertIn("resume", call_text.lower())

    async def test_pause_rejected_for_non_captain(self):
        """Non-Captain pause attempt must be silently rejected."""
        import bot as bot_module

        update = make_mock_update(OTHER_USER_ID, "/cos pause")
        context = make_mock_context(CAPTAIN_ID, args=["pause"])

        with patch.object(Path, "exists", return_value=False):
            await bot_module.cmd_cos_router(update, context)

        update.message.reply_text.assert_not_called()


# ----------------------------------------------------------------
# /cos resume tests
# ----------------------------------------------------------------

@unittest.skipUnless(TELEGRAM_AVAILABLE, "python-telegram-bot not installed")
class TestCosResume(unittest.IsolatedAsyncioTestCase):

    async def test_resume_removes_flag_file(self):
        """resume must remove the pause flag."""
        import bot as bot_module

        update = make_mock_update(CAPTAIN_ID, "/cos resume")
        context = make_mock_context(CAPTAIN_ID, args=["resume"])

        with tempfile.TemporaryDirectory() as tmpdir:
            pause_flag = Path(tmpdir) / "host-agent.paused"
            pause_flag.touch()  # Flag exists

            with patch.object(bot_module, "PAUSE_FLAG", pause_flag):
                self.assertTrue(pause_flag.exists())
                await bot_module.cmd_cos_router(update, context)
                self.assertFalse(pause_flag.exists())

        update.message.reply_text.assert_called_once()
        call_text = update.message.reply_text.call_args[0][0]
        self.assertIn("resumed", call_text.lower())

    async def test_resume_when_not_paused_reports_not_paused(self):
        """resume when flag absent must report it wasn't paused."""
        import bot as bot_module

        update = make_mock_update(CAPTAIN_ID, "/cos resume")
        context = make_mock_context(CAPTAIN_ID, args=["resume"])

        with tempfile.TemporaryDirectory() as tmpdir:
            pause_flag = Path(tmpdir) / "host-agent.paused"
            # Flag does NOT exist

            with patch.object(bot_module, "PAUSE_FLAG", pause_flag):
                await bot_module.cmd_cos_router(update, context)

        update.message.reply_text.assert_called_once()
        call_text = update.message.reply_text.call_args[0][0]
        self.assertIn("not paused", call_text.lower())


# ----------------------------------------------------------------
# /cos restart tests
# ----------------------------------------------------------------

@unittest.skipUnless(TELEGRAM_AVAILABLE, "python-telegram-bot not installed")
class TestCosRestart(unittest.IsolatedAsyncioTestCase):

    async def test_restart_calls_subprocess_and_replies(self):
        """restart must call subprocess.run and reply with exit code + logs."""
        import bot as bot_module
        import subprocess

        update = make_mock_update(CAPTAIN_ID, "/cos restart")
        context = make_mock_context(CAPTAIN_ID, args=["restart"])

        mock_restart = MagicMock()
        mock_restart.returncode = 0
        mock_logs = MagicMock()
        mock_logs.stdout = "log line 1\nlog line 2\n"
        mock_logs.stderr = ""

        with patch("bot.subprocess.run", side_effect=[mock_restart, mock_logs]):
            await bot_module.cmd_cos_router(update, context)

        # Must have replied at least twice (initial "Restarting..." + result)
        self.assertGreaterEqual(update.message.reply_text.call_count, 2)

    async def test_restart_reply_includes_exit_code(self):
        """restart reply must include exit code."""
        import bot as bot_module

        update = make_mock_update(CAPTAIN_ID, "/cos restart")
        context = make_mock_context(CAPTAIN_ID, args=["restart"])

        mock_restart = MagicMock()
        mock_restart.returncode = 0
        mock_logs = MagicMock()
        mock_logs.stdout = "some logs\n"
        mock_logs.stderr = ""

        with patch("bot.subprocess.run", side_effect=[mock_restart, mock_logs]):
            await bot_module.cmd_cos_router(update, context)

        # Second call should contain the exit code
        calls = [str(c) for c in update.message.reply_text.call_args_list]
        combined = " ".join(calls)
        self.assertIn("exit 0", combined)

    async def test_restart_rejected_for_non_captain(self):
        """Non-Captain restart attempt must be silently rejected."""
        import bot as bot_module

        update = make_mock_update(OTHER_USER_ID, "/cos restart")
        context = make_mock_context(CAPTAIN_ID, args=["restart"])

        await bot_module.cmd_cos_router(update, context)

        update.message.reply_text.assert_not_called()


# ----------------------------------------------------------------
# /cos unknown subcommand
# ----------------------------------------------------------------

@unittest.skipUnless(TELEGRAM_AVAILABLE, "python-telegram-bot not installed")
class TestCosUnknown(unittest.IsolatedAsyncioTestCase):

    async def test_unknown_subcommand_returns_help(self):
        """Unknown subcommand from Captain must return help text."""
        import bot as bot_module

        update = make_mock_update(CAPTAIN_ID, "/cos whatever")
        context = make_mock_context(CAPTAIN_ID, args=["whatever"])

        await bot_module.cmd_cos_router(update, context)

        update.message.reply_text.assert_called_once()
        call_text = update.message.reply_text.call_args[0][0]
        self.assertIn("ping", call_text)
        self.assertIn("pause", call_text)
        self.assertIn("resume", call_text)
        self.assertIn("restart", call_text)

    async def test_no_args_returns_help(self):
        """Empty /cos with no subcommand must return help text."""
        import bot as bot_module

        update = make_mock_update(CAPTAIN_ID, "/cos")
        context = make_mock_context(CAPTAIN_ID, args=[])

        await bot_module.cmd_cos_router(update, context)

        update.message.reply_text.assert_called_once()


if __name__ == "__main__":
    import unittest
    unittest.main(verbosity=2)
