#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = ["fastmcp>=2.0"]
# ///
"""tmux-pilot MCP server — agent lifecycle tools for MCP-capable clients."""

import json
import os
import re
import subprocess
import time
import uuid

from fastmcp import FastMCP

from monitor import (
    PaneReport,
    detect_events,
    detect_prompts,
    format_report,
    infer_status,
)

SCRIPTS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "scripts")

mcp = FastMCP("tmux-pilot")


def _run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    """Run a command, capturing output."""
    return subprocess.run(cmd, capture_output=True, text=True, **kwargs)


# Tmux target format: session:window.pane (window/pane parts optional)
_TARGET_RE = re.compile(r"^[\w.:-]+$")

# Tmux special key names that must go through send-keys (cannot be pasted).
_TMUX_SPECIAL_KEY_RE = re.compile(
    r"^("
    r"Enter|Escape|Tab|BTab|Space|BSpace|NPage|PPage|"
    r"Up|Down|Left|Right|Home|End|IC|DC|"
    r"F[0-9]{1,2}|"
    r"[CMS]-.+"
    r")$"
)


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
    host: str | None = None,
    mode: str | None = None,
) -> str:
    """Create a new AI agent in its own tmux session.

    Args:
        agent: Agent name (claude, gemini, aider, codex, goose, interpreter).
        prompt: The task prompt to send to the agent.
        directory: Working directory for the agent session.
        session_name: Optional session name (auto-generated from prompt if omitted).
        host: Optional remote hostname (launches agent on remote machine via SSH).
        mode: Execution mode when host is set: "local-ssh" (local pane over SSH,
              visible in deck) or "remote-tmux" (fully remote tmux session).
              Defaults to "local-ssh".
    """
    cmd = [
        os.path.join(SCRIPTS_DIR, "spawn.sh"),
        "--agent", agent,
        "--prompt", prompt,
        "--dir", directory,
    ]
    if session_name:
        cmd += ["--session", session_name]
    if host:
        cmd += ["--host", host]
    if mode:
        cmd += ["--mode", mode]

    result = _run(cmd)
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"
    name = result.stdout.strip()
    effective_mode = mode or ("local-ssh" if host else None)
    if effective_mode == "remote-tmux":
        return (
            f"Remote session created: {name}\n"
            f"Attach with: ssh {host} -t \"tmux attach -t {name}\""
        )
    return f"Spawned session: {name}"


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
        f"#{{pane_pid}}{sep}"
        f"#{{@pilot-host}}{sep}"
        f"#{{@pilot-mode}}"
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
        # Pad to 9 fields for backwards compat with older tmux metadata
        while len(parts) < 9:
            parts.append("")
        target, agent, desc, workdir, path, activity_s, pane_pid_s, phost, pmode = parts

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

        host_info = f"  host={phost} ({pmode})" if phost else ""
        entry = (
            f"  {target}"
            f"  agent={agent or '?'}"
            f"  desc=\"{desc}\""
            f"  dir={directory}"
            f"  age={age}"
            f"  cpu={cpu_str}"
            f"  mem={mem_str}"
            f"{host_info}"
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


# ---------------------------------------------------------------------------
# capture_pane
# ---------------------------------------------------------------------------
@mcp.tool()
def capture_pane(target: str, lines: int = 20) -> str:
    """Capture terminal text content from a tmux pane.

    Args:
        target: tmux pane target (e.g. "my-session:0.0").
        lines: Number of lines to capture from bottom (default 20).
    """
    if err := _validate_target(target):
        return f"Error: {err}"
    if lines < 1:
        return "Error: lines must be >= 1"
    result = _run(["tmux", "capture-pane", "-t", target, "-p", "-S", f"-{lines}"])
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"
    return result.stdout


# ---------------------------------------------------------------------------
# send_keys
# ---------------------------------------------------------------------------
@mcp.tool()
def send_keys(target: str, keys: str) -> str:
    """Send text or key names to a tmux pane.

    For multi-line text, uses load-buffer + paste-buffer to write directly to
    the pane PTY, bypassing tmux popup/overlay interception. For single
    control keys (Enter, C-c, etc.), uses send-keys directly.

    Args:
        target: tmux pane target (e.g. "my-session:0.0").
        keys: Text or key names to send (e.g. "Enter", "BTab", "C-c", or arbitrary text).
    """
    if err := _validate_target(target):
        return f"Error: {err}"
    if not keys:
        return "Error: keys must not be empty"

    if _TMUX_SPECIAL_KEY_RE.match(keys):
        # Single control/special key — send directly via send-keys.
        result = _run(["tmux", "send-keys", "-t", target, keys])
    else:
        # Text payload — use load-buffer + paste-buffer to bypass overlays.
        result = _run(["tmux", "load-buffer", "-"], input=keys)
        if result.returncode != 0:
            return f"Error loading buffer: {result.stderr.strip()}"
        result = _run(["tmux", "paste-buffer", "-d", "-p", "-t", target])

    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"
    return f"Sent keys to {target}"


# ---------------------------------------------------------------------------
# monitor_agents
# ---------------------------------------------------------------------------
_MONITOR_CAPTURE_LINES = 50


@mcp.tool()
def monitor_agents() -> str:
    """Monitor all agent panes for permission prompts and lifecycle events.

    Captures recent output from every agent pane, detects Claude Code permission
    prompts, classifies them by risk (safe/low/high), and detects lifecycle
    events (PR created, agent finished, context low).

    Returns a structured report with status, prompts, and events per pane.
    When nothing is actionable, returns a compact summary.
    """
    sep = "\x1f"
    fmt = (
        f"#{{session_name}}:#{{window_index}}"
        f".#{{pane_index}}{sep}"
        f"#{{@pilot-agent}}"
    )
    result = _run(
        ["tmux", "list-panes", "-a", "-F", fmt]
    )
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"

    if not result.stdout.strip():
        return "No agent panes found."

    reports: list[PaneReport] = []

    for raw_line in result.stdout.strip().splitlines():
        raw_line = raw_line.replace("\\037", sep)
        parts = raw_line.split(sep)
        if len(parts) < 2:
            continue
        target = parts[0]
        agent = parts[1] if len(parts) > 1 else ""

        # Skip non-agent panes (no @pilot-agent set)
        if not agent:
            continue

        # Capture pane output
        cap = _run([
            "tmux", "capture-pane",
            "-t", target, "-p",
            "-S", f"-{_MONITOR_CAPTURE_LINES}",
        ])
        if cap.returncode != 0:
            continue
        text = cap.stdout

        prompts = detect_prompts(text)
        events = detect_events(text)
        status = infer_status(prompts, events)

        reports.append(PaneReport(
            target=target,
            agent=agent,
            status=status,
            prompts=prompts,
            events=events,
        ))

    return format_report(reports)


# ---------------------------------------------------------------------------
# run_command_silent
# ---------------------------------------------------------------------------
@mcp.tool()
def run_command_silent(
    command: str,
    directory: str,
    timeout_minutes: int = 15,
) -> str:
    """Run a command silently, return exit code and tail of output. Full output saved to a log file.

    The command's stdout/stderr go to a temp file, not to the MCP response.
    Only the exit code and last N lines are returned — keeping LLM context clean.

    Args:
        command: Shell command to execute.
        directory: Working directory for the command.
        timeout_minutes: Max execution time (default 15).
    """
    log_file = f"/tmp/pilot-cmd-{uuid.uuid4()}.log"
    try:
        with open(log_file, "w") as f:
            result = subprocess.run(
                command,
                shell=True,
                cwd=directory,
                stdout=f,
                stderr=subprocess.STDOUT,
                timeout=timeout_minutes * 60,
            )
        exit_code = result.returncode
        tail = ""
        if exit_code != 0:
            with open(log_file) as f:
                lines = f.readlines()
                tail = "".join(lines[-30:])
        return json.dumps({"exit_code": exit_code, "log_file": log_file, "tail": tail})
    except subprocess.TimeoutExpired:
        tail = f"TIMEOUT after {timeout_minutes}m"
        return json.dumps({"exit_code": -1, "log_file": log_file, "tail": tail})


if __name__ == "__main__":
    mcp.run()
