"""Tests for deck_format.py display formatter."""
import os
import sys
import tempfile
import pytest

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(__file__),
        "..", "scripts",
    ),
)
from deck_format import (
    Pane,
    format_panes,
    format_line,
    type_label,
    stat_icon,
    pane_name,
    header,
    separator,
    display_width,
    pad_to,
    set_col_widths,
    DIM,
    RST,
    COL_PANE,
    COL_TYPE,
)


@pytest.fixture(autouse=True)
def reset_widths():
    set_col_widths(26, 14)
    yield


# --- Unit tests ---

class TestDisplayWidth:
    def test_ascii(self):
        assert display_width("hello") == 5

    def test_emoji(self):
        # 🤖 is a wide char (2 cells)
        assert display_width("🤖") == 2

    def test_mixed(self):
        assert display_width("🤖 claude") == 9


class TestPadTo:
    def test_short_string(self):
        result = pad_to("hi", 10)
        assert len(result) == 10
        assert result == "hi        "

    def test_emoji_padding(self):
        # 🤖 is 2 cells, so padding to 10
        # needs 8 more spaces
        result = pad_to("🤖", 10)
        assert display_width(result) == 10


class TestTypeLabel:
    def test_agent(self):
        result = type_label("claude", "")
        assert "🤖" in result
        assert "claude" in result

    def test_daemon(self):
        result = type_label("watchdog", "daemon")
        assert "⚙" in result
        assert "watchdog" in result

    def test_shell(self):
        result = type_label("", "")
        assert "$" in result
        assert "🤖" not in result

    def test_shell_daemon(self):
        result = type_label("", "daemon")
        assert "⚙" in result


class TestStatIcon:
    def test_working(self):
        assert stat_icon("working") == "▶"

    def test_waiting(self):
        assert stat_icon("waiting") == "!"

    def test_done(self):
        assert stat_icon("done") == "✓"

    def test_paused(self):
        assert stat_icon("paused") == "‖"

    def test_unknown(self):
        assert stat_icon("") == "·"

    def test_idle(self):
        assert stat_icon("idle") == "·"


class TestPaneName:
    def _pane(self, **kw):
        return Pane(**kw)

    def test_single_window_single_pane(self):
        p = self._pane(
            session="backup", win_name="main",
            win_idx=0, pane_idx=0,
        )
        wins = {"backup": 1}
        panes = {"backup:0": 1}
        assert pane_name(p, wins, panes) == "backup"

    def test_multi_window(self):
        p = self._pane(
            session="nexus", win_name="watchdog",
            win_idx=1, pane_idx=0,
        )
        wins = {"nexus": 2}
        panes = {"nexus:0": 1, "nexus:1": 1}
        assert (
            pane_name(p, wins, panes)
            == "nexus/watchdog"
        )

    def test_multi_pane(self):
        p = self._pane(
            session="frugal", win_name="main",
            win_idx=0, pane_idx=1,
        )
        wins = {"frugal": 1}
        panes = {"frugal:0": 3}
        assert (
            pane_name(p, wins, panes)
            == "frugal.1"
        )

    def test_multi_window_multi_pane(self):
        p = self._pane(
            session="nexus", win_name="watchdog",
            win_idx=1, pane_idx=1,
        )
        wins = {"nexus": 2}
        panes = {"nexus:1": 2}
        assert (
            pane_name(p, wins, panes)
            == "nexus/watchdog.1"
        )

    def test_remote_host(self):
        p = self._pane(
            session="issue-42",
            win_name="main",
            win_idx=0, pane_idx=0,
            host="desktop",
        )
        wins = {"issue-42": 1}
        panes = {"issue-42:0": 1}
        assert (
            pane_name(p, wins, panes)
            == "issue-42@desktop"
        )

    def test_truncation(self):
        p = self._pane(
            session="very-long-session-name-here",
            win_name="main",
            win_idx=0, pane_idx=0,
        )
        wins = {"very-long-session-name-here": 1}
        panes = {
            "very-long-session-name-here:0": 1
        }
        result = pane_name(p, wins, panes)
        assert len(result) <= 26
        assert result.endswith("..")


# --- Integration tests ---

def _make_panes():
    """Create a realistic set of panes."""
    return [
        Pane(
            target="backup:0.0",
            session="backup",
            win_idx=0, win_name="main",
            pane_idx=0, path="/home",
            agent="claude", status="working",
            cpu="0%", mem="423M",
            uuid="aaa11111",
        ),
        Pane(
            target="frugal:0.0",
            session="frugal",
            win_idx=0, win_name="orch",
            pane_idx=0, path="/home",
            agent="claude", status="",
            cpu="0%", mem="977M",
            owner="bbb22222",  # owned by swarm
            uuid="ccc33333",
        ),
        Pane(
            target="frugal:0.1",
            session="frugal",
            win_idx=0, win_name="orch",
            pane_idx=1, path="/home",
            agent="", status="",
            cpu="0%", mem="560M",
            uuid="ddd44444",
        ),
        Pane(
            target="issue-904:0.0",
            session="issue-904",
            win_idx=0, win_name="main",
            pane_idx=0, path="/work",
            agent="vibe", status="working",
            cpu="23%", mem="236M",
            owner="ccc33333",  # owned by frugal
            uuid="eee55555",
        ),
        Pane(
            target="nexus:0.0",
            session="nexus",
            win_idx=0, win_name="dash",
            pane_idx=0, path="/home",
            agent="", status="",
            cpu="0%", mem="130M",
            uuid="fff66666",
        ),
        Pane(
            target="nexus:1.0",
            session="nexus",
            win_idx=1, win_name="watchdog",
            pane_idx=0, path="/home",
            agent="", status="working",
            cpu="0%", mem="62M",
            pane_type="daemon",
            uuid="ggg77777",
        ),
        Pane(
            target="swarm:0.0",
            session="swarm",
            win_idx=0, win_name="main",
            pane_idx=0, path="/home",
            agent="claude", status="working",
            cpu="9%", mem="1.3G",
            owner="ccc33333",  # owned by frugal
            uuid="bbb22222",
        ),
    ]


class TestFormatPanes:
    def test_all_panes_present(self):
        """Every pane appears exactly once."""
        panes = _make_panes()
        lines = format_panes(panes)
        # Filter out separator/empty lines
        content = [
            l for l in lines
            if "\t" in l
            and l.split("\t", 1)[1].strip()
            and not l.split("\t", 1)[1]
            .startswith(DIM + "──")
        ]
        assert len(content) == len(panes)

    def test_alphabetical_unowned(self):
        """Unowned panes are sorted alphabetically."""
        panes = _make_panes()
        lines = format_panes(panes)
        content = [
            l.split("\t", 1)[1]
            for l in lines
            if "\t" in l
            and l.split("\t", 1)[1].strip()
            and not l.split("\t", 1)[1]
            .startswith(DIM + "──")
        ]
        # First panes should be unowned:
        # backup, frugal.1, nexus/dash,
        # nexus/watchdog
        assert "backup" in content[0]

    def test_orchestrator_sections(self):
        """Orchestrator sections have headers."""
        panes = _make_panes()
        lines = format_panes(panes)
        text = "\n".join(
            l.split("\t", 1)[1]
            for l in lines if "\t" in l
        )
        assert "frugal" in text
        assert "swarm" in text

    def test_orchestrator_in_own_section(self):
        """Orchestrator pane appears in its own
        section, not under its peer's section."""
        panes = _make_panes()
        lines = format_panes(panes)
        # Find frugal section
        in_frugal = False
        frugal_panes = []
        for l in lines:
            if "\t" not in l:
                continue
            content = l.split("\t", 1)[1]
            if "── frugal" in content:
                in_frugal = True
                continue
            if in_frugal and content.startswith(
                DIM + "──"
            ):
                break
            if in_frugal and content.strip():
                frugal_panes.append(content)
        # frugal's own pane should be here
        assert any(
            "frugal" in p and "★" in p
            for p in frugal_panes
        ), (
            f"frugal orchestrator pane not in "
            f"frugal section: {frugal_panes}"
        )

    def test_peer_flag(self):
        """Peer orchestrators have ★⇄ flag."""
        panes = _make_panes()
        lines = format_panes(panes)
        text = "\n".join(
            l.split("\t", 1)[1]
            for l in lines if "\t" in l
        )
        # Both frugal and swarm own each other
        assert "★⇄" in text

    def test_star_flag(self):
        """Orchestrators have ★ flag."""
        panes = _make_panes()
        lines = format_panes(panes)
        text = "\n".join(
            l.split("\t", 1)[1]
            for l in lines if "\t" in l
        )
        assert "★" in text

    def test_dimming_repeated_session(self):
        """Repeated session names are dimmed."""
        panes = _make_panes()
        lines = format_panes(panes)
        text = "\n".join(
            l.split("\t", 1)[1]
            for l in lines if "\t" in l
        )
        # nexus appears twice (dash + watchdog)
        # — second should be dimmed
        assert DIM in text

    def test_data_file(self):
        """Data file has correct target/path."""
        panes = _make_panes()
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".txt", delete=False
        ) as f:
            data_path = f.name
        try:
            format_panes(panes, data_path)
            with open(data_path) as f:
                data = f.read().strip().split("\n")
            # Should have entries for all panes
            # plus separator lines (empty)
            targets = [
                l.split("\t")[0]
                for l in data if l.split("\t")[0]
            ]
            assert "backup:0.0" in targets
            assert "swarm:0.0" in targets
        finally:
            os.unlink(data_path)

    def test_no_duplicate_panes(self):
        """Each target appears exactly once in
        data file."""
        panes = _make_panes()
        with tempfile.NamedTemporaryFile(
            mode="w", suffix=".txt", delete=False
        ) as f:
            data_path = f.name
        try:
            format_panes(panes, data_path)
            with open(data_path) as f:
                data = f.read().strip().split("\n")
            targets = [
                l.split("\t")[0]
                for l in data if l.split("\t")[0]
            ]
            assert len(targets) == len(set(targets))
        finally:
            os.unlink(data_path)

    def test_shell_type(self):
        """Non-agent panes show $ type."""
        panes = [
            Pane(
                target="shell:0.0",
                session="shell",
                win_idx=0, win_name="main",
                pane_idx=0, path="/home",
            ),
        ]
        lines = format_panes(panes)
        text = lines[0].split("\t", 1)[1]
        assert "$" in text
        assert "🤖" not in text
