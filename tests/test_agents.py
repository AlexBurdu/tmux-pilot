"""Unit tests for mcp/agents.py.

Tests the resolve_uuid function and UUID-related functionality.
"""

import os
import sys
import unittest
from unittest.mock import patch, MagicMock

# Add mcp/ to path so we can import agents
sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(__file__), "..", "mcp"
    ),
)

from agents import resolve_uuid, AgentInfo


class TestResolveUUID(unittest.TestCase):

    @patch("agents._run")
    def test_resolve_uuid_success(self, mock_run):
        """Resolve existing UUID to target."""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = (
            "abc123def456\tmy-session:0.1\n"
            "other-uuid\tother:1.0\n"
        )
        mock_run.return_value = mock_result
        target = resolve_uuid("abc123def456")
        self.assertEqual(target, "my-session:0.1")

    @patch("agents._run")
    def test_resolve_uuid_second_pane(self, mock_run):
        """Resolve UUID that appears later in list."""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = (
            "aaa\tfirst:0.0\n"
            "bbb\tsecond:1.0\n"
        )
        mock_run.return_value = mock_result
        target = resolve_uuid("bbb")
        self.assertEqual(target, "second:1.0")

    @patch("agents._run")
    def test_resolve_uuid_not_found(self, mock_run):
        """Raise ValueError for missing UUID."""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = (
            "other-uuid\tother:1.0\n"
        )
        mock_run.return_value = mock_result
        with self.assertRaises(ValueError) as cm:
            resolve_uuid("nonexistent")
        self.assertIn(
            "UUID not found", str(cm.exception)
        )

    @patch("agents._run")
    def test_resolve_uuid_tmux_failure(self, mock_run):
        """Raise ValueError when tmux fails."""
        mock_result = MagicMock()
        mock_result.returncode = 1
        mock_result.stderr = "no server running"
        mock_run.return_value = mock_result
        with self.assertRaises(ValueError) as cm:
            resolve_uuid("abc123def456")
        self.assertIn(
            "tmux command failed",
            str(cm.exception),
        )

    @patch("agents._run")
    def test_resolve_uuid_no_panes(self, mock_run):
        """Raise ValueError when no panes exist."""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = ""
        mock_run.return_value = mock_result
        with self.assertRaises(ValueError) as cm:
            resolve_uuid("abc123def456")
        self.assertIn(
            "No panes found", str(cm.exception)
        )


class TestAgentInfoUUID(unittest.TestCase):

    def test_agent_info_has_uuid_field(self):
        """Test that AgentInfo has uuid field."""
        # Create an AgentInfo instance
        agent = AgentInfo(uuid="test-uuid-123")
        self.assertEqual(agent.uuid, "test-uuid-123")

    def test_agent_info_uuid_default_empty(self):
        """Test that AgentInfo uuid defaults to empty string."""
        agent = AgentInfo()
        self.assertEqual(agent.uuid, "")


if __name__ == "__main__":
    unittest.main()