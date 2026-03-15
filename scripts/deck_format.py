#!/usr/bin/env python3
"""Deck v2 display formatter.

Reads raw pane data (tab-separated) from stdin,
outputs formatted display lines for fzf. Handles:
- Alphabetical sorting by session
- Owner-based section grouping
- Dimmed repeated session/agent names
- Emoji width compensation
- Remote host separators
- Orchestrator flags (★, ★⇄)

Input format (one line per pane, tab-separated):
  target session win_idx win_name pane_idx
  path agent status cpu mem owner desc type

Output format (tab-separated):
  index<TAB>formatted_display_line

Also writes a data file (target<TAB>path per line)
for fzf action lookup.
"""
import sys
import unicodedata
from dataclasses import dataclass, field


@dataclass
class Pane:
    target: str = ""
    session: str = ""
    win_idx: int = 0
    win_name: str = ""
    pane_idx: int = 0
    path: str = ""
    agent: str = ""
    status: str = ""
    cpu: str = ""
    mem: str = ""
    owner: str = ""
    desc: str = ""
    pane_type: str = ""
    host: str = ""  # remote host, empty=local
    uuid: str = ""   # unique pane identifier
    activity: int = 0  # window_activity timestamp


def display_width(s: str) -> int:
    """Compute display width accounting for wide
    chars (CJK, emoji)."""
    w = 0
    for ch in s:
        cat = unicodedata.east_asian_width(ch)
        if cat in ("W", "F"):
            w += 2
        else:
            w += 1
    return w


def pad_to(s: str, width: int) -> str:
    """Left-align string to exact display width."""
    dw = display_width(s)
    if dw >= width:
        return s
    return s + " " * (width - dw)


# ANSI escape codes
DIM = "\033[2m"
RST = "\033[0m"
BOLD = "\033[1m"


# Column widths
COL_PANE = 26
COL_TYPE = 14
COL_STAT = 2
COL_CPU = 4
COL_MEM = 5


def set_col_widths(
    pane: int = 26,
    typ: int = 14,
):
    """Override column widths (for testing)."""
    global COL_PANE, COL_TYPE
    COL_PANE = pane
    COL_TYPE = typ


def type_label(
    agent: str,
    pane_type: str,
    flag: str = "",
) -> str:
    """Build TYPE column content.

    Flag (★, ★⇄) is inserted between the icon
    and the agent name: 🤖 ★⇄ claude
    """
    if agent:
        if pane_type == "daemon":
            return f"⚙ {flag}{agent}"
        return f"🤖 {flag}{agent}"
    if pane_type == "daemon":
        return " ⚙"
    if pane_type == "agent":
        return " 🤖"
    return " $"


def stat_icon(
    status: str,
    activity: int = 0,
    now: int = 0,
) -> str:
    """Map status to Option C icon.

    If @pilot-status is set (by watchdog or other
    tooling), uses the semantic status. Otherwise
    falls back to output-age heuristic from
    window_activity timestamp.
    """
    if status:
        icons = {
            "working": "▶",
            "watching": "▶",
            "waiting": "!",
            "paused": "‖",
            "done": "✓",
            "stuck": "!",
        }
        return icons.get(status, "·")
    # Fallback: derive from output age
    if activity and now:
        elapsed = now - activity
        if elapsed < 60:
            return "▶"  # recent output
        if elapsed < 600:
            return "·"  # quiet
    return "·"


def pane_name(p: Pane, session_wins: dict,
              session_panes: dict) -> str:
    """Build display name for a pane."""
    name = p.session
    if p.host:
        name = f"{p.session}@{p.host}"
    wc = session_wins.get(p.session, 1)
    if wc > 1:
        name = f"{name}/{p.win_name}"
    pc = session_panes.get(
        f"{p.session}:{p.win_idx}", 1
    )
    if pc > 1 and p.pane_idx > 0:
        name = f"{name}.{p.pane_idx}"
    if len(name) > COL_PANE:
        name = name[: COL_PANE - 2] + ".."
    return name


def format_line(
    pane_col: str,
    type_col: str,
    stat: str,
    cpu: str,
    mem: str,
) -> str:
    """Format a single pane line with fixed widths."""
    return (
        f"{pad_to(pane_col, COL_PANE)}  "
        f"{pad_to(type_col, COL_TYPE)}  "
        f"{stat:>{COL_STAT}}  "
        f"{cpu:>{COL_CPU}}  "
        f"{mem:>{COL_MEM}}"
    )


def header() -> str:
    """Column header line."""
    return (
        f"{BOLD}"
        f"{pad_to('PANE', COL_PANE)}  "
        f"{pad_to('TYPE', COL_TYPE)}  "
        f"{'ST':>{COL_STAT}}  "
        f"{'CPU':>{COL_CPU}}  "
        f"{'MEM':>{COL_MEM}}"
        f"{RST}"
    )


def separator(label: str) -> str:
    """Section separator line."""
    total = (
        COL_PANE + COL_TYPE + COL_STAT
        + COL_CPU + COL_MEM + 8
    )
    dashes = total - len(label) - 4
    if dashes < 2:
        dashes = 2
    return f"{DIM}── {label} {'─' * dashes}{RST}"


def parse_pane(line: str) -> Pane:
    """Parse a tab-separated pane line.

    13 fields = local pane, 14 fields = remote
    (14th field is the remote hostname).
    """
    parts = line.rstrip("\n").split("\t")
    while len(parts) < 16:
        parts.append("")
    act = 0
    try:
        act = int(parts[15]) if parts[15] else 0
    except ValueError:
        pass
    return Pane(
        target=parts[0],
        session=parts[1],
        win_idx=int(parts[2] or "0"),
        win_name=parts[3],
        pane_idx=int(parts[4] or "0"),
        path=parts[5],
        agent=parts[6],
        status=parts[7],
        cpu=parts[8],
        mem=parts[9],
        owner=parts[10],
        desc=parts[11],
        pane_type=parts[12],
        host=parts[13],
        uuid=parts[14],
        activity=act,
    )


def compute_counts(panes: list[Pane]) -> tuple:
    """Compute session window/pane counts."""
    session_wins: dict[str, set] = {}
    session_panes: dict[str, int] = {}
    for p in panes:
        key = p.session
        if key not in session_wins:
            session_wins[key] = set()
        session_wins[key].add(p.win_idx)
        pkey = f"{p.session}:{p.win_idx}"
        session_panes[pkey] = (
            session_panes.get(pkey, 0) + 1
        )
    win_counts = {
        k: len(v) for k, v in session_wins.items()
    }
    return win_counts, session_panes


def find_orchestrators(panes: list[Pane]) -> set:
    """Find sessions that own other panes."""
    owners = set()
    for p in panes:
        if p.owner:
            owners.add(p.owner)
    return owners


def find_peers(
    panes: list[Pane],
    orchestrators: set,
) -> dict[str, str]:
    """Find peer relationships.

    Returns dict mapping session -> peer session
    for mutual ownership.
    """
    # Map session -> owner session
    owns: dict[str, set] = {}
    for p in panes:
        if p.owner and p.owner in orchestrators:
            # Find owner's session
            for o in panes:
                if o.session == p.owner:
                    if o.session not in owns:
                        owns[o.session] = set()
                    owns[o.session].add(p.session)
                    break
    # Find mutual: A owns B and B owns A
    peers: dict[str, str] = {}
    for a, a_children in owns.items():
        for b in a_children:
            if b in owns and a in owns[b]:
                peers[a] = b
                peers[b] = a
    return peers


def format_panes(
    panes: list[Pane],
    data_file: str | None = None,
    now: int = 0,
) -> list[str]:
    """Format all panes into display lines.

    Returns list of "idx\\tformatted_line" strings.
    Writes target\\tpath lines to data_file.
    """
    # Split local and remote panes. Deduplicate:
    # if a local pane has the same session name as
    # a remote pane, keep only the local one (the
    # remote is a stale or duplicate tmux session).
    local_panes = [p for p in panes if not p.host]
    local_sessions = {p.session for p in local_panes}
    remote_panes = [
        p for p in panes
        if p.host and p.session not in local_sessions
    ]

    win_counts, pane_counts = compute_counts(
        local_panes
    )

    # Build OID → session map for owner resolution
    uuid_to_session: dict[str, str] = {}
    for p in local_panes:
        if p.uuid:
            uuid_to_session[p.uuid] = p.session

    # Determine which sessions are orchestrators
    # (have agents owned by them via OID)
    owner_sessions: dict[str, list[Pane]] = {}
    for p in local_panes + remote_panes:
        if p.owner:
            # Resolve owner OID to session name
            owner_ses = uuid_to_session.get(
                p.owner, p.owner
            )
            if owner_ses not in owner_sessions:
                owner_sessions[owner_ses] = []
            owner_sessions[owner_ses].append(p)

    # Find peer relationships
    peer_map: dict[str, str] = {}
    for p in local_panes:
        if p.owner:
            owner_ses = uuid_to_session.get(
                p.owner, p.owner
            )
            for q in local_panes:
                if q.session == owner_ses and q.owner:
                    q_owner_ses = uuid_to_session.get(
                        q.owner, q.owner
                    )
                    if q_owner_ses == p.session:
                        peer_map[p.session] = owner_ses
                        peer_map[owner_ses] = p.session

    # Classify panes into groups:
    # - unowned: no owner, session is not an
    #   orchestrator
    # - orchestrator section: orchestrator panes
    #   (all panes in that session) + its owned
    #   agents from other sessions
    unowned: list[Pane] = []
    sections: dict[str, list[Pane]] = {}

    # First pass: identify orchestrator sessions
    orch_sessions = set(owner_sessions.keys())

    def resolve_owner(p: Pane) -> str:
        """Resolve owner OID to session name."""
        if not p.owner:
            return ""
        return uuid_to_session.get(
            p.owner, p.owner
        )

    for p in local_panes:
        if p.session in orch_sessions:
            if p.session not in sections:
                sections[p.session] = []
            sections[p.session].append(p)
        else:
            owner_ses = resolve_owner(p)
            if owner_ses in orch_sessions:
                if owner_ses not in sections:
                    sections[owner_ses] = []
                sections[owner_ses].append(p)
            else:
                unowned.append(p)

    # Remote panes: owned → owner section,
    # unowned → host section
    unowned_remote: list[Pane] = []
    for p in remote_panes:
        owner_ses = resolve_owner(p)
        if owner_ses in orch_sessions:
            if owner_ses not in sections:
                sections[owner_ses] = []
            sections[owner_ses].append(p)
        else:
            unowned_remote.append(p)

    # Sort within each group
    def sort_key(p: Pane) -> tuple:
        return (p.session, p.win_idx, p.pane_idx)

    unowned.sort(key=sort_key)
    for k in sections:
        sections[k].sort(key=sort_key)

    # Build output
    lines: list[str] = []
    data_lines: list[str] = []
    idx = 1
    prev_ses = ""
    prev_ag = ""

    def emit_pane(p: Pane, flag: str = ""):
        nonlocal idx, prev_ses, prev_ag
        name = pane_name(
            p, win_counts, pane_counts
        )
        tc = type_label(
            p.agent, p.pane_type, flag
        )
        st = stat_icon(
            p.status, p.activity, now
        ) if (
            p.agent or p.pane_type
            or p.status or p.activity
        ) else " "
        cpu = p.cpu or ""
        mem = p.mem or ""

        raw = format_line(name, tc, st, cpu, mem)

        # Dim repeated session name
        if (p.session == prev_ses
                and prev_ses
                and not p.host):
            slen = len(p.session)
            raw = (
                f"{DIM}{raw[:slen]}{RST}"
                f"{raw[slen:]}"
            )
        # Dim repeated agent
        if (p.agent == prev_ag
                and prev_ag
                and p.agent):
            # Find agent in the line and dim it
            pos = raw.find(p.agent)
            if pos >= 0:
                end = pos + len(p.agent)
                raw = (
                    f"{raw[:pos]}"
                    f"{DIM}{p.agent}{RST}"
                    f"{raw[end:]}"
                )
        prev_ses = p.session
        prev_ag = p.agent

        lines.append(f"{idx}\t{raw}")
        data_lines.append(
            f"{p.target}\t{p.path}\t{p.host}"
        )
        idx += 1

    def emit_separator(label: str):
        nonlocal idx, prev_ses, prev_ag
        # Empty line
        lines.append(f"{idx}\t")
        data_lines.append("\t")
        idx += 1
        # Separator
        lines.append(f"{idx}\t{separator(label)}")
        data_lines.append("\t")
        idx += 1
        prev_ses = ""
        prev_ag = ""

    # Emit unowned panes
    for p in unowned:
        emit_pane(p)

    # Emit orchestrator sections (sorted by name)
    for orch_ses in sorted(sections.keys()):
        section_panes = sections[orch_ses]
        # Count non-orchestrator agents
        agent_count = sum(
            1 for p in section_panes
            if p.session != orch_ses
        )
        emit_separator(
            f"{orch_ses} ({agent_count} agents)"
        )
        for p in section_panes:
            flag = ""
            if (p.session == orch_ses
                    and p.pane_idx == 0
                    and p.win_idx == 0):
                # Main pane of the orchestrator
                if p.session in peer_map:
                    flag = "★⇄ "
                else:
                    flag = "★  "
            elif (p.session != orch_ses
                    and p.session in orch_sessions):
                # A different orchestrator owned
                # by this one (peer or child)
                if p.session in peer_map:
                    flag = "★⇄ "
                else:
                    flag = "★  "
            emit_pane(p, flag)

    # Unowned remote panes grouped by host
    if unowned_remote:
        # Group by host
        hosts: dict[str, list[Pane]] = {}
        for p in unowned_remote:
            if p.host not in hosts:
                hosts[p.host] = []
            hosts[p.host].append(p)

        for host_name in sorted(hosts.keys()):
            host_panes = sorted(
                hosts[host_name], key=sort_key
            )
            emit_separator(host_name)
            for p in host_panes:
                emit_pane(p)

    # Write data file
    if data_file:
        with open(data_file, "w") as f:
            for dl in data_lines:
                f.write(dl + "\n")

    return lines


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--data-file", required=True,
        help="Path to write target/path data",
    )
    parser.add_argument(
        "--col-pane", type=int, default=26,
    )
    parser.add_argument(
        "--col-type", type=int, default=14,
    )
    args = parser.parse_args()
    set_col_widths(args.col_pane, args.col_type)

    import time
    now = int(time.time())

    panes = []
    for line in sys.stdin:
        if line.strip():
            panes.append(parse_pane(line))

    # Print header
    print(f"0\t{header()}")

    # Print formatted panes
    for out_line in format_panes(
        panes, args.data_file, now=now
    ):
        print(out_line)


if __name__ == "__main__":
    main()
