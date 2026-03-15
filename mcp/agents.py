"""Shared pane-parsing module for tmux-pilot.

Provides typed agent metadata and parsing utilities
used by both the MCP server and external consumers.
"""

from __future__ import annotations

import subprocess
import time
from dataclasses import dataclass, field


@dataclass
class AgentInfo:
    """Typed representation of a single agent pane."""

    target: str = ""
    agent: str = ""
    desc: str = ""
    workdir: str = ""
    path: str = ""
    age: str = ""
    pid: int = 0
    host: str = ""
    mode: str = ""
    status: str = ""
    owner: str = ""
    tier: str = ""
    trust: str = ""
    review_target: str = ""
    review_context: str = ""
    issue: str = ""
    worktree: str = ""
    repo: str = ""
    cpu: str = ""
    memory: str = ""
    session: str = ""
    pane_id: str = ""
    uuid: str = ""


def _run(
    cmd: list[str], **kwargs
) -> subprocess.CompletedProcess:
    """Run a command, capturing output."""
    return subprocess.run(
        cmd, capture_output=True, text=True, **kwargs
    )


def tree_stats(
    root_pid: int,
    procs: dict[int, tuple[int, int, float]],
) -> tuple[int, float]:
    """Sum RSS (KB) and CPU% for the process tree.

    Walks the process tree from root_pid, summing
    RSS and CPU% for all descendants.

    Args:
        root_pid: PID of the root process.
        procs: Map of pid -> (ppid, rss_kb, cpu%).

    Returns:
        Tuple of (total_rss_kb, total_cpu_pct).
    """
    pids = {root_pid}
    changed = True
    while changed:
        changed = False
        for pid, (ppid, _, _) in procs.items():
            if pid not in pids and ppid in pids:
                pids.add(pid)
                changed = True
    total_rss = sum(
        procs[p][1] for p in pids if p in procs
    )
    total_cpu = sum(
        procs[p][2] for p in pids if p in procs
    )
    return total_rss, total_cpu


def fmt_mem(kb: int) -> str:
    """Format kilobytes as human-readable string."""
    if kb >= 1048576:
        return f"{kb / 1048576:.1f}G"
    if kb >= 1024:
        return f"{kb // 1024}M"
    return f"{kb}K"


def fmt_age(elapsed: int) -> str:
    """Format elapsed seconds as human-readable age."""
    if elapsed < 60:
        return "active"
    if elapsed < 3600:
        return f"{elapsed // 60}m ago"
    if elapsed < 86400:
        return f"{elapsed // 3600}h ago"
    return f"{elapsed // 86400}d ago"


def _get_procs() -> dict[int, tuple[int, int, float]]:
    """Gather process stats via ps.

    Returns:
        Map of pid -> (ppid, rss_kb, cpu_pct).
    """
    result = _run(
        ["ps", "-ax", "-o", "pid=,ppid=,rss=,%cpu="]
    )
    procs: dict[int, tuple[int, int, float]] = {}
    if result.returncode != 0:
        return procs
    for line in result.stdout.strip().splitlines():
        parts = line.split()
        if len(parts) >= 4:
            try:
                procs[int(parts[0])] = (
                    int(parts[1]),
                    int(parts[2]),
                    float(parts[3]),
                )
            except (ValueError, IndexError):
                continue
    return procs


def parse_pane_lines(
    raw_output: str,
    procs: dict[int, tuple[int, int, float]]
    | None = None,
    now: int | None = None,
) -> list[AgentInfo]:
    """Parse tmux list-panes output into AgentInfo.

    Args:
        raw_output: Raw stdout from tmux list-panes
            with the expected format string.
        procs: Process table (pid -> ppid, rss, cpu).
            If None, stats are skipped.
        now: Current epoch seconds. If None, uses
            time.time().

    Returns:
        List of AgentInfo objects.
    """
    if now is None:
        now = int(time.time())
    sep = "\x1f"
    agents: list[AgentInfo] = []

    # Pre-join continuation lines caused by
    # newlines inside tmux variables (e.g.
    # multiline @pilot-desc). A valid pane line
    # has >=13 separators (14 fields). When a
    # line has fewer, it is either a
    # continuation of the previous line's
    # multiline field, or the start of a
    # broken entry. We accumulate until the
    # total separator count is sufficient.
    raw_lines: list[str] = []
    for line in raw_output.strip().splitlines():
        line = line.replace("\\037", sep)
        if (
            raw_lines
            and raw_lines[-1].count(sep) < 18
        ):
            raw_lines[-1] += " " + line
        else:
            raw_lines.append(line)

    for raw_line in raw_lines:
        parts = raw_line.split(sep)
        if len(parts) < 7:
            continue
        # Pad to expected field count
        while len(parts) < 21:
            parts.append("")
        (
            target, agent, desc, workdir, path,
            activity_s, pane_pid_s, phost, pmode,
            pstatus, powner, ptier, ptrust,
            preview_target, preview_context,
            pissue, pworktree, prepo,
            puuid,
            session, pane_id,
        ) = parts[:22]

        directory = workdir if workdir else path

        # Compute age from window_activity
        try:
            activity = int(activity_s)
            age = fmt_age(now - activity)
        except ValueError:
            age = "?"

        # Compute CPU/memory from process tree
        cpu_str = "?"
        mem_str = "?"
        pid = 0
        try:
            pid = int(pane_pid_s)
            if procs is not None:
                rss, cpu = tree_stats(pid, procs)
                mem_str = fmt_mem(rss)
                cpu_str = f"{int(cpu)}%"
        except ValueError:
            pass

        agents.append(AgentInfo(
            target=target,
            pane_id=pane_id,
            agent=agent or "",
            desc=desc,
            workdir=directory,
            path=path,
            age=age,
            pid=pid,
            host=phost,
            mode=pmode,
            status=pstatus,
            owner=powner,
            tier=ptier,
            trust=ptrust,
            review_target=preview_target,
            review_context=preview_context,
            issue=pissue,
            worktree=pworktree,
            repo=prepo,
            uuid=puuid,
            cpu=cpu_str,
            memory=mem_str,
            session=session,
        ))

    return agents


# The tmux format string used to query pane metadata.
# Consumers can use this directly or call
# list_agent_panes() which handles everything.
PANE_FORMAT_FIELDS = [
    "#{session_name}:#{window_index}"
    ".#{pane_index}",
    "#{@pilot-agent}",
    "#{@pilot-desc}",
    "#{@pilot-workdir}",
    "#{pane_current_path}",
    "#{window_activity}",
    "#{pane_pid}",
    "#{@pilot-host}",
    "#{@pilot-mode}",
    "#{@pilot-status}",
    "#{@pilot-owner}",
    "#{@pilot-tier}",
    "#{@pilot-trust}",
    "#{@pilot-review-target}",
    "#{@pilot-review-context}",
    "#{@pilot-issue}",
    "#{@pilot-worktree}",
    "#{@pilot-repo}",
    "#{@pilot-uuid}",
    "#{session_name}",
    "#{pane_id}",
]


def resolve_uuid(uuid: str) -> str:
    """Resolve a UUID to a tmux pane target.

    Args:
        uuid: The @pilot-uuid value (12-char hex).

    Returns:
        Pane target (e.g. "session:0.0").

    Raises:
        ValueError: If not found or tmux fails.
    """
    fmt = (
        "#{@pilot-uuid}\t"
        "#{session_name}:"
        "#{window_index}.#{pane_index}"
    )
    result = _run(
        ["tmux", "list-panes", "-a", "-F", fmt]
    )
    if result.returncode != 0:
        raise ValueError(
            f"tmux command failed: "
            f"{result.stderr.strip()}"
        )
    if not result.stdout.strip():
        raise ValueError("No panes found")
    for line in result.stdout.strip().splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            if parts[0] == uuid:
                return parts[1]
    raise ValueError(f"UUID not found: {uuid}")


def list_agent_panes() -> list[AgentInfo]:
    """Query tmux for all agent panes with metadata.

    Returns a list of AgentInfo objects with process
    stats (CPU, memory) computed from the process tree.
    Returns an empty list if tmux is not available.
    """
    sep = "\x1f"
    fmt = sep.join(PANE_FORMAT_FIELDS)

    result = _run(
        ["tmux", "list-panes", "-a", "-F", fmt]
    )
    if result.returncode != 0:
        return []

    if not result.stdout.strip():
        return []

    procs = _get_procs()
    return parse_pane_lines(
        result.stdout, procs=procs
    )
