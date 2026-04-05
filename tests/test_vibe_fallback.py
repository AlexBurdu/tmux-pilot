import os
import sys
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "mcp"))

import server


class TestVibeFallback(unittest.TestCase):
    @patch("server._run")
    @patch("server.os.path.exists")
    def test_capture_pane_vibe_fallback(
        self, mock_exists, mock_run
    ):
        """Alternate screen active + pipe log exists
        uses tail fallback instead of capture-pane."""
        def side_effect(cmd, **kwargs):
            if "display-message" in cmd:
                return MagicMock(
                    returncode=0,
                    stdout="1\x1f/tmp/vibe.log",
                )
            if "tail" in cmd:
                return MagicMock(
                    returncode=0,
                    stdout="line 1\nline 2",
                )
            return MagicMock(returncode=1)

        mock_run.side_effect = side_effect
        mock_exists.return_value = True

        result = server.capture_pane(
            target="vibe:0.0", lines=2
        )
        self.assertEqual(result, "line 1\nline 2")
        tail_calls = [
            c for c in mock_run.call_args_list
            if "tail" in c[0][0]
        ]
        self.assertTrue(len(tail_calls) > 0)

    @patch("server._run")
    @patch("server.os.path.exists")
    def test_no_fallback_when_alt_off(
        self, mock_exists, mock_run
    ):
        """Normal screen uses capture-pane."""
        def side_effect(cmd, **kwargs):
            if "display-message" in cmd:
                return MagicMock(
                    returncode=0,
                    stdout="0\x1f/tmp/vibe.log",
                )
            if "capture-pane" in cmd:
                return MagicMock(
                    returncode=0,
                    stdout="regular output",
                )
            return MagicMock(returncode=1)

        mock_run.side_effect = side_effect
        mock_exists.return_value = True

        result = server.capture_pane(
            target="vibe:0.0", lines=2
        )
        self.assertEqual(result, "regular output")

    @patch("server._run")
    def test_spawn_starts_pipe_pane_for_vibe(
        self, mock_run
    ):
        """spawn_agent starts pipe-pane for vibe."""
        mock_run.return_value = MagicMock(
            returncode=0, stdout="vibe-session"
        )

        server.spawn_agent(
            agent="vibe",
            prompt="test",
            directory="/tmp",
        )

        pipe_calls = [
            c for c in mock_run.call_args_list
            if "pipe-pane" in c[0][0]
        ]
        self.assertTrue(len(pipe_calls) > 0)

    @patch("server._run")
    @patch("server.os.path.exists")
    @patch("server.os.remove")
    def test_kill_cleans_up_log(
        self, mock_remove, mock_exists, mock_run
    ):
        """kill_agent removes pipe log."""
        def side_effect(cmd, **kwargs):
            if "display-message" in cmd:
                if "#{@pilot-pipe-log}" in cmd:
                    return MagicMock(
                        returncode=0,
                        stdout="/tmp/vibe.log",
                    )
                if "#{@pilot-workdir}" in cmd:
                    return MagicMock(
                        returncode=0,
                        stdout="/tmp/wt",
                    )
            if any("kill.sh" in p for p in cmd):
                return MagicMock(
                    returncode=0,
                    stdout="Killed",
                    stderr="",
                )
            return MagicMock(
                returncode=0, stdout="", stderr=""
            )

        mock_run.side_effect = side_effect
        mock_exists.return_value = True

        server.kill_agent(target="vibe:0.0")
        mock_remove.assert_called_once_with(
            "/tmp/vibe.log"
        )


if __name__ == "__main__":
    unittest.main()
