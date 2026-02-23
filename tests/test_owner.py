"""Unit tests for @pilot-owner functionality in mcp/server.py.

Tests owner auto-detection in spawn_agent and transfer_ownership
logic. Uses mocks — no tmux required.
"""

import os
import sys
import types
import unittest
from unittest.mock import MagicMock, call, patch

# Add mcp/ to path so we can import server
sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(__file__), "..", "mcp"
    ),
)

# Stub fastmcp if not installed (server.py imports it at module level).
# The stub's .tool() decorator must return the original function unchanged
# so we can call spawn_agent / transfer_ownership directly in tests.
if "fastmcp" not in sys.modules:
    class _StubMCP:
        def __init__(self, name: str): pass
        def tool(self):
            return lambda fn: fn
        def run(self): pass

    _fm = types.ModuleType("fastmcp")
    _fm.FastMCP = _StubMCP  # type: ignore[attr-defined]
    sys.modules["fastmcp"] = _fm

import server


# -----------------------------------------------------------
# spawn_agent — owner detection
# -----------------------------------------------------------
class TestSpawnAgentOwner(unittest.TestCase):

    @patch.dict(os.environ, {"TMUX_PANE": "%5"})
    @patch("server._run")
    def test_owner_is_tmux_pane_id(self, mock_run):
        """When $TMUX_PANE is set, its value is
        passed directly as --owner (unique pane ID).
        """
        spawn_result = MagicMock(
            returncode=0,
            stdout="claude-fix-42",
            stderr="",
        )
        mock_run.return_value = spawn_result

        result = server.spawn_agent(
            agent="claude",
            prompt="Fix bug #42",
            directory="/tmp",
        )

        self.assertIn("claude-fix-42", result)

        # Only one _run call (spawn.sh) — no tmux
        # display-message needed.
        self.assertEqual(mock_run.call_count, 1)

        spawn_cmd = mock_run.call_args[0][0]
        self.assertIn("--owner", spawn_cmd)
        owner_idx = spawn_cmd.index("--owner")
        self.assertEqual(
            spawn_cmd[owner_idx + 1], "%5"
        )

    @patch.dict(os.environ, {}, clear=True)
    @patch("server._run")
    def test_no_owner_when_no_tmux_pane(
        self, mock_run
    ):
        """When $TMUX_PANE is not set, --owner is
        not passed."""
        os.environ.pop("TMUX_PANE", None)

        spawn_result = MagicMock(
            returncode=0,
            stdout="claude-fix-42",
            stderr="",
        )
        mock_run.return_value = spawn_result

        result = server.spawn_agent(
            agent="claude",
            prompt="Fix bug #42",
            directory="/tmp",
        )

        self.assertIn("claude-fix-42", result)

        self.assertEqual(mock_run.call_count, 1)
        spawn_cmd = mock_run.call_args[0][0]
        self.assertNotIn("--owner", spawn_cmd)


# -----------------------------------------------------------
# transfer_ownership
# -----------------------------------------------------------
class TestTransferOwnership(unittest.TestCase):

    @patch("server._run")
    def test_transfers_matching_panes(
        self, mock_run
    ):
        """Panes with matching old_owner get
        updated."""
        sep = "\x1f"
        list_output = (
            f"orch-main:0.0{sep}%5\n"
            f"worker-1:0.0{sep}%5\n"
            f"worker-2:0.0{sep}%99\n"
        )
        list_result = MagicMock(
            returncode=0, stdout=list_output
        )
        set_result = MagicMock(returncode=0)
        mock_run.side_effect = [
            list_result, set_result, set_result,
        ]

        result = server.transfer_ownership(
            "%5", "%12"
        )

        self.assertIn("2 pane(s)", result)
        self.assertIn("orch-main:0.0", result)
        self.assertIn("worker-1:0.0", result)
        self.assertNotIn("worker-2:0.0", result)

    @patch("server._run")
    def test_no_matching_panes(self, mock_run):
        """Reports when no panes match old_owner."""
        sep = "\x1f"
        list_result = MagicMock(
            returncode=0,
            stdout=f"worker:0.0{sep}%99\n",
        )
        mock_run.return_value = list_result

        result = server.transfer_ownership(
            "%5", "%12"
        )

        self.assertIn("No panes found", result)

    def test_empty_old_owner(self):
        result = server.transfer_ownership("", "%12")
        self.assertIn("Error", result)

    def test_empty_new_owner(self):
        result = server.transfer_ownership("%5", "")
        self.assertIn("Error", result)

    @patch("server._run")
    def test_handles_tmux_037_escape(
        self, mock_run
    ):
        """Handles older tmux that escapes 0x1F
        to \\037."""
        list_output = "worker:0.0\\037%5\n"
        list_result = MagicMock(
            returncode=0, stdout=list_output
        )
        set_result = MagicMock(returncode=0)
        mock_run.side_effect = [
            list_result, set_result,
        ]

        result = server.transfer_ownership(
            "%5", "%12"
        )

        self.assertIn("1 pane(s)", result)


if __name__ == "__main__":
    unittest.main()
