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

    @patch('agents._run')
    def test_resolve_uuid_success(self, mock_run):
        """Test successful UUID resolution."""
        # Mock tmux output with UUID and target
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "abc123def456\x1fmy-session:0.1\nother-uuid\x1fother-session:1.0\n"
        mock_run.return_value = mock_result
        
        # Test resolving existing UUID
        target = resolve_uuid("abc123def456")
        self.assertEqual(target, "my-session:0.1")

    @patch('agents._run')
    def test_resolve_uuid_not_found(self, mock_run):
        """Test UUID not found error."""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = "other-uuid\x1fother-session:1.0\n"
        mock_run.return_value = mock_result
        
        # Test resolving non-existent UUID
        with self.assertRaises(ValueError) as cm:
            resolve_uuid("nonexistent")
        self.assertIn("UUID not found", str(cm.exception))

    @patch('agents._run')
    def test_resolve_uuid_tmux_failure(self, mock_run):
        """Test tmux command failure."""
        mock_result = MagicMock()
        mock_result.returncode = 1
        mock_result.stderr = "tmux: no server running"
        mock_run.return_value = mock_result
        
        # Test tmux failure
        with self.assertRaises(ValueError) as cm:
            resolve_uuid("abc123def456")
        self.assertIn("tmux command failed", str(cm.exception))

    @patch('agents._run')
    def test_resolve_uuid_no_panes(self, mock_run):
        """Test no panes found."""
        mock_result = MagicMock()
        mock_result.returncode = 0
        mock_result.stdout = ""
        mock_run.return_value = mock_result
        
        # Test no panes
        with self.assertRaises(ValueError) as cm:
            resolve_uuid("abc123def456")
        self.assertIn("No panes found", str(cm.exception))


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