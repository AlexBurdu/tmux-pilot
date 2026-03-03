"""Unit tests for mcp/agents.py.

Tests pane parsing, process tree stats, and
formatting helpers. No tmux required — all
functions are pure.
"""

import os
import sys
import unittest

# Add mcp/ to path so we can import agents
sys.path.insert(
    0,
    os.path.join(os.path.dirname(__file__)),
)

from agents import (
    AgentInfo,
    fmt_age,
    fmt_mem,
    parse_pane_lines,
    tree_stats,
)

SEP = "\x1f"


def _make_line(
    target="s:0.0",
    agent="claude",
    desc="Working on task",
    workdir="/home/user/proj",
    path="/home/user/proj",
    activity="1709500000",
    pid="12345",
    host="",
    mode="",
    status="working",
    owner="%5",
    tier="",
    trust="",
    session="s",
):
    """Build a single tmux list-panes output line."""
    return SEP.join([
        target, agent, desc, workdir, path,
        activity, pid, host, mode, status,
        owner, tier, trust, session,
    ])


# -------------------------------------------------------
# fmt_mem
# -------------------------------------------------------
class TestFmtMem(unittest.TestCase):

    def test_kilobytes(self):
        self.assertEqual(fmt_mem(500), "500K")

    def test_megabytes(self):
        self.assertEqual(fmt_mem(2048), "2M")

    def test_megabytes_rounds_down(self):
        self.assertEqual(fmt_mem(3500), "3M")

    def test_gigabytes(self):
        self.assertEqual(fmt_mem(1048576), "1.0G")

    def test_gigabytes_fractional(self):
        self.assertEqual(
            fmt_mem(1572864), "1.5G"
        )

    def test_zero(self):
        self.assertEqual(fmt_mem(0), "0K")


# -------------------------------------------------------
# fmt_age
# -------------------------------------------------------
class TestFmtAge(unittest.TestCase):

    def test_active(self):
        self.assertEqual(fmt_age(30), "active")

    def test_minutes(self):
        self.assertEqual(fmt_age(300), "5m ago")

    def test_hours(self):
        self.assertEqual(fmt_age(7200), "2h ago")

    def test_days(self):
        self.assertEqual(
            fmt_age(172800), "2d ago"
        )

    def test_zero(self):
        self.assertEqual(fmt_age(0), "active")


# -------------------------------------------------------
# tree_stats
# -------------------------------------------------------
class TestTreeStats(unittest.TestCase):

    def test_single_process(self):
        procs = {1: (0, 1024, 5.0)}
        rss, cpu = tree_stats(1, procs)
        self.assertEqual(rss, 1024)
        self.assertAlmostEqual(cpu, 5.0)

    def test_parent_child(self):
        procs = {
            1: (0, 1024, 5.0),
            2: (1, 2048, 3.0),
        }
        rss, cpu = tree_stats(1, procs)
        self.assertEqual(rss, 3072)
        self.assertAlmostEqual(cpu, 8.0)

    def test_deep_tree(self):
        procs = {
            1: (0, 100, 1.0),
            2: (1, 200, 2.0),
            3: (2, 300, 3.0),
            4: (3, 400, 4.0),
        }
        rss, cpu = tree_stats(1, procs)
        self.assertEqual(rss, 1000)
        self.assertAlmostEqual(cpu, 10.0)

    def test_missing_root(self):
        """Root PID not in procs table."""
        procs = {2: (1, 1024, 5.0)}
        rss, cpu = tree_stats(999, procs)
        self.assertEqual(rss, 0)
        self.assertAlmostEqual(cpu, 0.0)

    def test_branching_tree(self):
        procs = {
            1: (0, 100, 1.0),
            2: (1, 200, 2.0),
            3: (1, 300, 3.0),
            4: (2, 400, 4.0),
        }
        rss, cpu = tree_stats(1, procs)
        self.assertEqual(rss, 1000)
        self.assertAlmostEqual(cpu, 10.0)

    def test_subtree_only(self):
        """Only sums the subtree under root."""
        procs = {
            1: (0, 100, 1.0),
            2: (1, 200, 2.0),
            3: (0, 300, 3.0),  # sibling
        }
        rss, cpu = tree_stats(1, procs)
        self.assertEqual(rss, 300)
        self.assertAlmostEqual(cpu, 3.0)


# -------------------------------------------------------
# parse_pane_lines
# -------------------------------------------------------
class TestParsePaneLines(unittest.TestCase):

    def test_basic_parsing(self):
        line = _make_line()
        agents = parse_pane_lines(
            line, procs=None, now=1709500060
        )
        self.assertEqual(len(agents), 1)
        a = agents[0]
        self.assertEqual(a.target, "s:0.0")
        self.assertEqual(a.agent, "claude")
        self.assertEqual(a.desc, "Working on task")
        self.assertEqual(
            a.workdir, "/home/user/proj"
        )
        self.assertEqual(a.status, "working")
        self.assertEqual(a.owner, "%5")
        self.assertEqual(a.age, "1m ago")

    def test_backslash_037_separator(self):
        """tmux <3.5 escapes 0x1F as \\037."""
        line = _make_line().replace(SEP, "\\037")
        agents = parse_pane_lines(
            line, procs=None, now=1709500060
        )
        self.assertEqual(len(agents), 1)
        self.assertEqual(
            agents[0].agent, "claude"
        )

    def test_multiple_lines(self):
        lines = "\n".join([
            _make_line(
                target="a:0.0", agent="claude"
            ),
            _make_line(
                target="b:0.0", agent="gemini"
            ),
        ])
        agents = parse_pane_lines(
            lines, procs=None, now=1709500060
        )
        self.assertEqual(len(agents), 2)
        self.assertEqual(
            agents[0].agent, "claude"
        )
        self.assertEqual(
            agents[1].agent, "gemini"
        )

    def test_short_line_skipped(self):
        """Lines with fewer than 7 fields skip."""
        short = SEP.join(["a:0.0", "claude", "d"])
        agents = parse_pane_lines(
            short, procs=None, now=1709500000
        )
        self.assertEqual(len(agents), 0)

    def test_empty_input(self):
        agents = parse_pane_lines(
            "", procs=None, now=1709500000
        )
        self.assertEqual(len(agents), 0)

    def test_workdir_fallback_to_path(self):
        """When workdir is empty, uses path."""
        line = _make_line(
            workdir="", path="/fallback/dir"
        )
        agents = parse_pane_lines(
            line, procs=None, now=1709500060
        )
        self.assertEqual(
            agents[0].workdir, "/fallback/dir"
        )

    def test_invalid_activity_gives_question(self):
        line = _make_line(activity="notanumber")
        agents = parse_pane_lines(
            line, procs=None, now=1709500000
        )
        self.assertEqual(agents[0].age, "?")

    def test_with_process_stats(self):
        line = _make_line(pid="100")
        procs = {
            100: (0, 2048, 5.0),
            101: (100, 1024, 3.0),
        }
        agents = parse_pane_lines(
            line, procs=procs, now=1709500060
        )
        a = agents[0]
        self.assertEqual(a.memory, "3M")
        self.assertEqual(a.cpu, "8%")

    def test_host_and_mode_preserved(self):
        line = _make_line(
            host="desktop", mode="remote-tmux"
        )
        agents = parse_pane_lines(
            line, procs=None, now=1709500060
        )
        self.assertEqual(
            agents[0].host, "desktop"
        )
        self.assertEqual(
            agents[0].mode, "remote-tmux"
        )

    def test_tier_and_trust(self):
        line = _make_line(tier="L4", trust="high")
        agents = parse_pane_lines(
            line, procs=None, now=1709500060
        )
        self.assertEqual(agents[0].tier, "L4")
        self.assertEqual(agents[0].trust, "high")

    def test_session_field(self):
        line = _make_line(session="issue-42")
        agents = parse_pane_lines(
            line, procs=None, now=1709500060
        )
        self.assertEqual(
            agents[0].session, "issue-42"
        )

    def test_padding_short_fields(self):
        """Lines with 7-13 fields get padded."""
        # Only 7 fields (minimum)
        parts = [
            "s:0.0", "claude", "desc",
            "/dir", "/path", "1709500000", "123",
        ]
        line = SEP.join(parts)
        agents = parse_pane_lines(
            line, procs=None, now=1709500060
        )
        self.assertEqual(len(agents), 1)
        a = agents[0]
        self.assertEqual(a.host, "")
        self.assertEqual(a.owner, "")


if __name__ == "__main__":
    unittest.main()
