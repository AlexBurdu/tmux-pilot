#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["fastmcp>=2.0"]
# ///
"""tmux-pilot MCP server — agent lifecycle tools for MCP-capable clients."""

import os
import re
import subprocess
import time

from fastmcp import FastMCP

SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")

mcp = FastMCP("tmux-pilot")


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    """Run a command, capturing output."""
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


# Tmux target format: session:window.pane (window/pane parts optional)
_TARGET_RE = re.compile(r"^[\w.:-]+$")


def _validate_target(target: str) -> str | None:
    """Return an error message if target looks invalid, else None."""
    if not target or not _TARGET_RE.match(target):
        return f"Invalid target format: {target!r}"
    return None


# ---------------------------------------------------------------------------
# spawn_agent
# ---------------------------------------------------------------------------
@mcp.tool()
def spawn_agent(
    agent: str,
    prompt: str,
    directory: str,
    session_name: str | None = None,
) -> str:
    """Create a new AI agent in its own tmux session.

    Args:
        agent: Agent name (claude, gemini, aider, codex, goose, interpreter).
        prompt: The task prompt to send to the agent.
        directory: Working directory for the agent session.
        session_name: Optional session name (auto-generated from prompt if omitted).
    """
    cmd = [
        os.path.join(SCRIPTS_DIR, "spawn.sh"),
        "--agent", agent,
        "--prompt", prompt,
        "--dir", directory,
    ]
    if session_name:
        cmd += ["--session", session_name]

    result = _run(cmd)
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"
    return f"Spawned session: {result.stdout.strip()}"


# ---------------------------------------------------------------------------
# list_agents
# ---------------------------------------------------------------------------
@mcp.tool()
def list_agents() -> str:
    """List running agent sessions with metadata (name, agent, description, directory, age, CPU, memory)."""
    sep = "\x1f"
    fmt = (
        f"#{{session_name}}:#{{window_index}}.#{{pane_index}}{sep}"
        f"#{{@pilot-agent}}{sep}"
        f"#{{@pilot-desc}}{sep}"
        f"#{{@pilot-workdir}}{sep}"
        f"#{{pane_current_path}}{sep}"
        f"#{{window_activity}}{sep}"
        f"#{{pane_pid}}"
    )
    result = _run(["tmux", "list-panes", "-a", "-F", fmt])
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"

    if not result.stdout.strip():
        return "No panes found."

    # Gather process stats in one call
    ps_result = _run(["ps", "-ax", "-o", "pid=,ppid=,rss=,%cpu="])
    procs: dict[int, tuple[int, int, float]] = {}  # pid -> (ppid, rss_kb, cpu%)
    if ps_result.returncode == 0:
        for line in ps_result.stdout.strip().splitlines():
            parts = line.split()
            if len(parts) >= 4:
                try:
                    procs[int(parts[0])] = (int(parts[1]), int(parts[2]), float(parts[3]))
                except (ValueError, IndexError):
                    continue

    def tree_stats(root_pid: int) -> tuple[int, float]:
        """Sum RSS (KB) and CPU% for the full process tree under root_pid."""
        pids = {root_pid}
        changed = True
        while changed:
            changed = False
            for pid, (ppid, _, _) in procs.items():
                if pid not in pids and ppid in pids:
                    pids.add(pid)
                    changed = True
        total_rss = sum(procs[p][1] for p in pids if p in procs)
        total_cpu = sum(procs[p][2] for p in pids if p in procs)
        return total_rss, total_cpu

    def fmt_mem(kb: int) -> str:
        if kb >= 1048576:
            return f"{kb / 1048576:.1f}G"
        if kb >= 1024:
            return f"{kb // 1024}M"
        return f"{kb}K"

    def fmt_age(elapsed: int) -> str:
        if elapsed < 60:
            return "active"
        if elapsed < 3600:
            return f"{elapsed // 60}m ago"
        if elapsed < 86400:
            return f"{elapsed // 3600}h ago"
        return f"{elapsed // 86400}d ago"

    now = int(time.time())
    lines: list[str] = []

    for raw_line in result.stdout.strip().splitlines():
        # tmux <3.5 escapes 0x1F to literal \037 in format output; decode it
        raw_line = raw_line.replace("\\037", sep)
        parts = raw_line.split(sep)
        if len(parts) < 7:
            continue
        target, agent, desc, workdir, path, activity_s, pane_pid_s = parts

        directory = workdir if workdir else path
        try:
            activity = int(activity_s)
            age = fmt_age(now - activity)
        except ValueError:
            age = "?"

        try:
            pane_pid = int(pane_pid_s)
            rss, cpu = tree_stats(pane_pid)
            mem_str = fmt_mem(rss)
            cpu_str = f"{int(cpu)}%"
        except ValueError:
            mem_str = "?"
            cpu_str = "?"

        entry = (
            f"  {target}"
            f"  agent={agent or '?'}"
            f"  desc=\"{desc}\""
            f"  dir={directory}"
            f"  age={age}"
            f"  cpu={cpu_str}"
            f"  mem={mem_str}"
        )
        lines.append(entry)

    if not lines:
        return "No agent sessions found."
    return f"{len(lines)} pane(s):\n" + "\n".join(lines)


# ---------------------------------------------------------------------------
# pause_agent
# ---------------------------------------------------------------------------
@mcp.tool()
def pause_agent(target: str) -> str:
    """Gracefully pause a running agent (sends the agent's quit command, keeps the pane alive for resume).

    Args:
        target: tmux pane target (e.g. "my-session:0.0").
    """
    if err := _validate_target(target):
        return f"Error: {err}"
    cmd = [
        "bash", "-c",
        'source "$1/_agents.sh" && agent=$(detect_agent "$2") || agent="" ; agent_pause "$2" "$agent"',
        "--", SCRIPTS_DIR, target,
    ]
    result = _run(cmd)
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"
    return f"Paused {target}"


# ---------------------------------------------------------------------------
# resume_agent
# ---------------------------------------------------------------------------
@mcp.tool()
def resume_agent(target: str) -> str:
    """Resume a previously paused agent.

    Args:
        target: tmux pane target (e.g. "my-session:0.0").
    """
    if err := _validate_target(target):
        return f"Error: {err}"
    cmd = [
        "bash", "-c",
        'source "$1/_agents.sh" && agent=$(detect_agent "$2") || agent="" ; agent_resume "$2" "$agent"',
        "--", SCRIPTS_DIR, target,
    ]
    result = _run(cmd)
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"
    return f"Resumed {target}"


# ---------------------------------------------------------------------------
# kill_agent
# ---------------------------------------------------------------------------
@mcp.tool()
def kill_agent(target: str) -> str:
    """Kill an agent session and clean up its worktree.

    Args:
        target: tmux pane target (e.g. "my-session:0.0").
    """
    if err := _validate_target(target):
        return f"Error: {err}"
    # Get working directory for worktree cleanup
    path_result = _run([
        "tmux", "display-message", "-t", target, "-p",
        "#{@pilot-workdir}",
    ])
    path = path_result.stdout.strip() if path_result.returncode == 0 else ""

    if not path:
        path_result = _run([
            "tmux", "display-message", "-t", target, "-p",
            "#{pane_current_path}",
        ])
        path = path_result.stdout.strip() if path_result.returncode == 0 else ""

    if not path:
        return "Error: could not determine pane working directory"

    result = _run([os.path.join(SCRIPTS_DIR, "kill.sh"), target, path])
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"

    output = result.stdout.strip()
    return output if output else f"Killed {target}"


if __name__ == "__main__":
    mcp.run()
