import os
import sys
import unittest
from unittest.mock import patch, MagicMock

# Add mcp/ to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "mcp"))

import server

class TestVibeFallback(unittest.TestCase):
    @patch("server._run")
    @patch("server.os.path.exists")
    def test_capture_pane_vibe_fallback(self, mock_exists, mock_run):
        # Setup: alternate screen is on, pipe log exists
        def side_effect(cmd, **kwargs):
            if "display-message" in cmd:
                # Mock return for fmt = "#{alternate_on}\x1f#{@pilot-pipe-log}"
                return MagicMock(returncode=0, stdout="1\x1f/tmp/vibe.log")
            if "tail" in cmd:
                return MagicMock(returncode=0, stdout="log content line 1\nlog content line 2")
            return MagicMock(returncode=1)
        
        mock_run.side_effect = side_effect
        mock_exists.return_value = True
        
        result = server.capture_pane(target="vibe:0.0", lines=2)
        
        self.assertEqual(result, "log content line 1\nlog content line 2")
        # Verify tail was called instead of capture-pane
        tail_calls = [call for call in mock_run.call_args_list if "tail" in call[0][0]]
        self.assertTrue(len(tail_calls) > 0)
        
        cap_calls = [call for call in mock_run.call_args_list if "capture-pane" in call[0][0]]
        self.assertEqual(len(cap_calls), 0)

    @patch("server._run")
    @patch("server.os.path.exists")
    def test_capture_pane_no_fallback_when_alt_off(self, mock_exists, mock_run):
        # Setup: alternate screen is off
        def side_effect(cmd, **kwargs):
            if "display-message" in cmd:
                return MagicMock(returncode=0, stdout="0\x1f/tmp/vibe.log")
            if "capture-pane" in cmd:
                return MagicMock(returncode=0, stdout="regular capture output")
            return MagicMock(returncode=1)
        
        mock_run.side_effect = side_effect
        mock_exists.return_value = True
        
        result = server.capture_pane(target="vibe:0.0", lines=2)
        
        self.assertEqual(result, "regular capture output")
        # Verify capture-pane was called
        cap_calls = [call for call in mock_run.call_args_list if "capture-pane" in call[0][0]]
        self.assertTrue(len(cap_calls) > 0)

    @patch("server._run")
    def test_spawn_agent_starts_pipe_pane_for_vibe(self, mock_run):
        # Mock successful spawn.sh call
        mock_run.return_value = MagicMock(returncode=0, stdout="vibe-session")
        
        server.spawn_agent(agent="vibe", prompt="test", directory="/tmp")
        
        # Verify pipe-pane was started
        pipe_pane_calls = [call for call in mock_run.call_args_list if "pipe-pane" in call[0][0]]
        self.assertTrue(len(pipe_pane_calls) > 0)
        
        # Verify @pilot-pipe-log was set
        set_opt_calls = [call for call in mock_run.call_args_list if "set-option" in call[0][0] and "@pilot-pipe-log" in call[0][0]]
        self.assertTrue(len(set_opt_calls) > 0)

    @patch("server._run")
    @patch("server.os.path.exists")
    @patch("server.os.remove")
    def test_kill_agent_cleans_up_log(self, mock_remove, mock_exists, mock_run):
        # Setup: @pilot-pipe-log is set
        def side_effect(cmd, **kwargs):
            if "display-message" in cmd:
                if "#{@pilot-pipe-log}" in cmd:
                    return MagicMock(returncode=0, stdout="/tmp/vibe.log")
                if "#{@pilot-workdir}" in cmd:
                    return MagicMock(returncode=0, stdout="/tmp/some-worktree")
            if any("kill.sh" in part for part in cmd):
                return MagicMock(returncode=0, stdout="Killed", stderr="")
            return MagicMock(returncode=0, stdout="", stderr="")
            
        mock_run.side_effect = side_effect
        mock_exists.return_value = True
        
        server.kill_agent(target="vibe:0.0")
        
        # Verify log was removed
        mock_remove.assert_called_once_with("/tmp/vibe.log")

if __name__ == "__main__":
    unittest.main()
