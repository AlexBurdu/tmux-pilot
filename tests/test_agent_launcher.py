"""Shell-level tests for scripts/_agents.sh.

Verifies KNOWN_AGENTS membership and the
command array produced by agent_build_cmd.
"""

import os
import subprocess
import unittest

SCRIPT = os.path.join(
    os.path.dirname(__file__),
    "..",
    "scripts",
    "_agents.sh",
)


def _build_cmd(agent: str, prompt: str) -> str:
    """Run agent_build_cmd via bash and return
    the space-quoted cmd_args."""
    out = subprocess.run(
        [
            "bash",
            "-c",
            f"source {SCRIPT} && cmd_args=() && "
            f'agent_build_cmd {agent} "{prompt}" '
            f'&& printf "%q " "${{cmd_args[@]}}"',
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return out.stdout


class TestKnownAgents(unittest.TestCase):

    def test_known_agents_contains_agy(self):
        out = subprocess.run(
            [
                "bash",
                "-c",
                f"source {SCRIPT} "
                f"&& echo $KNOWN_AGENTS",
            ],
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertIn("agy", out.stdout.split())


class TestAgentBuildCmd(unittest.TestCase):

    def test_agy_uses_dangerously_skip(self):
        cmd = _build_cmd("agy", "do thing")
        self.assertIn(
            "--dangerously-skip-permissions", cmd
        )
        self.assertIn("-i", cmd)
        self.assertIn("agy", cmd)

    def test_gemini_uses_yolo(self):
        cmd = _build_cmd("gemini", "do thing")
        self.assertIn("-y", cmd)

    def test_claude_uses_dangerously_skip(self):
        cmd = _build_cmd("claude", "do thing")
        self.assertIn(
            "CLAUDE_CODE_DISABLE_AUTOCOMPLETE",
            cmd,
        )


if __name__ == "__main__":
    unittest.main()
