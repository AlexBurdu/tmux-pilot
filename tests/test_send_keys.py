"""Unit tests for Escape+delay pattern in send_keys.

Verifies that Claude Code agents trigger the dismissal pattern for text
payloads, while non-Claude agents or special keys skip it.
"""

import asyncio
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, call, patch, AsyncMock

# Add mcp/ to path so we can import server
sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(__file__), "..", "mcp"
    ),
)

# Stub fastmcp if not installed
if "fastmcp" not in sys.modules:
    class _StubMCP:
        def __init__(self, name: str): pass
        def tool(self):
            return lambda fn: fn
        def run(self): pass

    _fm = types.ModuleType("fastmcp")
    _fm.FastMCP = _StubMCP
    sys.modules["fastmcp"] = _fm

import server

class TestSendKeysClaude(unittest.IsolatedAsyncioTestCase):

    @patch("server._run")
    @patch("asyncio.sleep", new_callable=AsyncMock)
    async def test_claude_text_triggers_delay_pattern(
        self, mock_sleep, mock_run
    ):
        """Claude agent with text payload should trigger Escape+delay.
        """
        # Mock responses:
        # 1. load-buffer (returncode 0)
        # 2. tmux display (return "claude")
        # 3. paste-buffer (returncode 0)
        # 4. tmux send-keys Escape (returncode 0)
        # 5. tmux send-keys Enter (returncode 0)
        mock_run.side_effect = [
            MagicMock(returncode=0),
            MagicMock(returncode=0, stdout="claude\n"),
            MagicMock(returncode=0),
            MagicMock(returncode=0),
            MagicMock(returncode=0),
        ]

        result = await server.send_keys("s:0.0", "hello world")

        self.assertIn("(Claude delay pattern)", result)

        # Verify tmux display was called to check agent
        self.assertTrue(any(
            "display" in c[0][0] and "#{@pilot-agent}" in c[0][0]
            for c in mock_run.call_args_list
        ))

        # Verify extra keys were sent
        self.assertTrue(any(
            "send-keys" in c[0][0] and "Escape" in c[0][0]
            for c in mock_run.call_args_list
        ))
        self.assertTrue(any(
            "send-keys" in c[0][0] and "Enter" in c[0][0]
            for c in mock_run.call_args_list
        ))

        # Verify sleeps occurred
        self.assertEqual(mock_sleep.call_count, 2)
        mock_sleep.assert_has_calls([call(0.3), call(0.1)])

    @patch("server._run")
    @patch("asyncio.sleep", new_callable=AsyncMock)
    async def test_non_claude_skips_delay_pattern(
        self, mock_sleep, mock_run
    ):
        """Non-Claude agent with text payload should skip the delay pattern.
        """
        # Mock responses:
        # 1. load-buffer
        # 2. tmux display (return "gemini")
        # 3. paste-buffer
        mock_run.side_effect = [
            MagicMock(returncode=0),
            MagicMock(returncode=0, stdout="gemini\n"),
            MagicMock(returncode=0),
        ]

        result = await server.send_keys("s:0.0", "hello world")
        self.assertNotIn("(Claude delay pattern)", result)

        # Should NOT have sent extra keys
        for c in mock_run.call_args_list:
            cmd = c[0][0]
            if "send-keys" in cmd:
                self.assertNotIn("Escape", cmd)
                self.assertNotIn("Enter", cmd)

        # Should NOT have slept
        self.assertEqual(mock_sleep.call_count, 0)

    @patch("server._run")
    @patch("asyncio.sleep", new_callable=AsyncMock)
    async def test_special_keys_skip_delay_pattern(
        self, mock_sleep, mock_run
    ):
        """Special keys (even for Claude) should skip the delay pattern.
        """
        # Mock responses:
        # 1. send-keys Enter
        mock_run.return_value = MagicMock(returncode=0)

        await server.send_keys("s:0.0", "Enter")

        # Should NOT have checked agent type (one call only for send-keys)
        self.assertEqual(mock_run.call_count, 1)
        cmd = mock_run.call_args[0][0]
        self.assertIn("send-keys", cmd)
        self.assertIn("Enter", cmd)

        # Should NOT have slept
        self.assertEqual(mock_sleep.call_count, 0)

    @patch("server._run")
    @patch("asyncio.sleep", new_callable=AsyncMock)
    async def test_control_keys_skip_delay_pattern(
        self, mock_sleep, mock_run
    ):
        """Control keys (C-c) should skip the delay pattern."""
        mock_run.return_value = MagicMock(returncode=0)

        await server.send_keys("s:0.0", "C-c")

        self.assertEqual(mock_run.call_count, 1)
        self.assertEqual(mock_sleep.call_count, 0)

if __name__ == "__main__":
    unittest.main()
