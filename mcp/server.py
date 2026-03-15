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
import uuid

from fastmcp import FastMCP

from agents import list_agent_panes
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
    owner: str | None = None,
    tier: str | None = None,
    trust: str | None = None,
    review_target: str | None = None,
    review_context: str | None = None,
    issue: str | None = None,
    worktree: str | None = None,
    repo: str | None = None,
    agent_args: str | None = None,
) -> str:
    """Create a new AI agent in its own tmux session.

    Args:
        agent: Agent name (claude, gemini, aider, codex, goose, interpreter, vibe).
        prompt: The task prompt to send to the agent.
        directory: Working directory for the agent session.
        session_name: Optional session name (auto-generated from prompt if omitted).
        host: Optional remote hostname (launches agent on remote machine via SSH).
        mode: Execution mode when host is set: "local-ssh" (local pane over SSH,
              visible in deck) or "remote-tmux" (fully remote tmux session).
              Defaults to "local-ssh".
        owner: Optional owner pane ID (e.g. "%5"). Overrides $TMUX_PANE
               auto-detection. Use when the MCP server runs outside tmux
               (e.g. remote MCP) and the caller knows its own pane ID.
        tier: Optional tier label (string). Sets @pilot-tier pane variable.
        trust: Optional trust level (string). Sets @pilot-trust pane variable.
        review_target: Optional pane target for routing review notifications.
                       Sets @pilot-review-target pane variable.
        review_context: Optional task-specific review hints for the worker.
                        Sets @pilot-review-context pane variable.
        issue: Optional issue number (string). Sets @pilot-issue pane variable.
        worktree: Optional worktree path. Sets @pilot-worktree pane variable.
        repo: Optional repo root path. Sets @pilot-repo pane variable.
        agent_args: Optional extra CLI arguments passed to the agent binary
                    (e.g. "--subtree-only --no-show-model-warnings" for aider).
    """
    # Explicit owner overrides auto-detection.
    # Fall back to $TMUX_PANE (works when the MCP
    # server runs inside tmux on the same machine).
    effective_owner = (
        owner or os.environ.get("TMUX_PANE", "")
    )

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
    if effective_owner:
        cmd += ["--owner", effective_owner]
    if tier:
        cmd += ["--tier", tier]
    if trust:
        cmd += ["--trust", trust]
    if review_target:
        cmd += [
            "--review-target", review_target,
        ]
    if review_context:
        cmd += [
            "--review-context", review_context,
        ]
    if issue:
        cmd += ["--issue", issue]
    if worktree:
        cmd += ["--worktree", worktree]
    if repo:
        cmd += ["--repo", repo]
    if agent_args:
        cmd += ["--agent-args", agent_args]

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
    agents = list_agent_panes()
    if not agents:
        return "No agent sessions found."

    lines: list[str] = []
    for a in agents:
        host_info = (
            f"  host={a.host} ({a.mode})"
            if a.host else ""
        )
        issue_info = (
            f"  issue={a.issue}" if a.issue else ""
        )
        status_info = (
            f"  status={a.status}" if a.status else ""
        )
        owner_info = (
            f"  owner={a.owner}" if a.owner else ""
        )
        tier_info = (
            f"  tier={a.tier}" if a.tier else ""
        )
        trust_info = (
            f"  trust={a.trust}" if a.trust else ""
        )
        review_target_info = (
            f"  review_target={a.review_target}"
            if a.review_target else ""
        )
        review_context_info = (
            f"  review_ctx={a.review_context}"
            if a.review_context else ""
        )
        worktree_info = (
            f"  worktree={a.worktree}" if a.worktree else ""
        )
        repo_info = (
            f"  repo={a.repo}" if a.repo else ""
        )
        pane_id_info = (
            f"  pane_id={a.pane_id}" if a.pane_id else ""
        )
        uuid_info = (
            f"  uuid={a.uuid}" if a.uuid else ""
        )
        entry = (
            f"  {a.target}"
            f"  agent={a.agent or '?'}"
            f"  desc=\"{a.desc}\""
            f"  dir={a.workdir}"
            f"  age={a.age}"
            f"  cpu={a.cpu}"
            f"  mem={a.memory}"
            f"{pane_id_info}"
            f"{uuid_info}"
            f"{host_info}"
            f"{issue_info}"
            f"{status_info}"
            f"{owner_info}"
            f"{tier_info}"
            f"{trust_info}"
            f"{review_target_info}"
            f"{review_context_info}"
            f"{worktree_info}"
            f"{repo_info}"
        )
        lines.append(entry)

    return (
        f"{len(lines)} pane(s):\n"
        + "\n".join(lines)
    )


# ---------------------------------------------------------------------------
# pause_agent
# ---------------------------------------------------------------------------
@mcp.tool()
def pause_agent(target: str | None = None, uuid: str | None = None) -> str:
    """Gracefully pause a running agent (sends the agent's quit command, keeps the pane alive for resume).

    Args:
        target: tmux pane target (e.g. "my-session:0.0").
        uuid: Optional UUID to resolve to target if target is not provided.
    """
    if not target and uuid:
        try:
            from agents import resolve_uuid
            target = resolve_uuid(uuid)
        except ValueError as e:
            return f"Error: {str(e)}"
    
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
def resume_agent(target: str | None = None, uuid: str | None = None) -> str:
    """Resume a previously paused agent.

    Args:
        target: tmux pane target (e.g. "my-session:0.0").
        uuid: Optional UUID to resolve to target if target is not provided.
    """
    if not target and uuid:
        try:
            from agents import resolve_uuid
            target = resolve_uuid(uuid)
        except ValueError as e:
            return f"Error: {str(e)}"
    
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
def kill_agent(target: str | None = None, uuid: str | None = None) -> str:
    """Kill an agent session and clean up its worktree.

    Args:
        target: tmux pane target (e.g. "my-session:0.0").
        uuid: Optional UUID to resolve to target if target is not provided.
    """
    if not target and uuid:
        try:
            from agents import resolve_uuid
            target = resolve_uuid(uuid)
        except ValueError as e:
            return f"Error: {str(e)}"
    
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
def capture_pane(target: str | None = None, lines: int = 20, uuid: str | None = None) -> str:
    """Capture terminal text content from a tmux pane.

    Args:
        target: tmux pane target (e.g. "my-session:0.0").
        lines: Number of lines to capture from bottom (default 20).
        uuid: Optional UUID to resolve to target if target is not provided.
    """
    if not target and uuid:
        try:
            from agents import resolve_uuid
            target = resolve_uuid(uuid)
        except ValueError as e:
            return f"Error: {str(e)}"
    
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
def send_keys(keys: str, target: str | None = None, uuid: str | None = None) -> str:
    """Send text or key names to a tmux pane.

    For multi-line text, uses load-buffer + paste-buffer to write directly to
    the pane PTY, bypassing tmux popup/overlay interception. For single
    control keys (Enter, C-c, etc.), uses send-keys directly.

    Args:
        target: tmux pane target (e.g. "my-session:0.0").
        keys: Text or key names to send (e.g. "Enter", "BTab", "C-c", or arbitrary text).
        uuid: Optional UUID to resolve to target if target is not provided.
    """
    if not target and uuid:
        try:
            from agents import resolve_uuid
            target = resolve_uuid(uuid)
        except ValueError as e:
            return f"Error: {str(e)}"
    
    if err := _validate_target(target):
        return f"Error: {err}"
    if not keys:
        return "Error: keys must not be empty"

    if _TMUX_SPECIAL_KEY_RE.match(keys):
        # Single control/special key — send directly via send-keys.
        result = _run(["tmux", "send-keys", "-t", target, keys])
    else:
        # Text payload — paste via load-buffer and
        # send Enter to submit. Uses _keys.sh which
        # handles agent-specific submit sequences
        # (e.g. delay for Vibe TUI).
        cmd = [
            "bash", "-c",
            'source "$1/_keys.sh" && send_text "$2" "$3"',
            "--", SCRIPTS_DIR, target, keys,
        ]
        result = _run(cmd)

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
# transfer_ownership
# ---------------------------------------------------------------------------
@mcp.tool()
def transfer_ownership(old_owner: str, new_owner: str) -> str:
    """Update @pilot-owner on all panes matching an old owner.

    Used during orchestrator handoff to re-route escalations to a new
    orchestrator session.

    Args:
        old_owner: Current owner session name to match.
        new_owner: New owner session name to set.
    """
    if not old_owner:
        return "Error: old_owner must not be empty"
    if not new_owner:
        return "Error: new_owner must not be empty"

    sep = "\x1f"
    fmt = f"#{{session_name}}:#{{window_index}}.#{{pane_index}}{sep}#{{@pilot-owner}}"
    result = _run(["tmux", "list-panes", "-a", "-F", fmt])
    if result.returncode != 0:
        return f"Error: {result.stderr.strip()}"

    updated: list[str] = []
    for raw_line in result.stdout.strip().splitlines():
        raw_line = raw_line.replace("\\037", sep)
        parts = raw_line.split(sep)
        if len(parts) < 2:
            continue
        target, owner = parts[0], parts[1]
        if owner == old_owner:
            set_result = _run([
                "tmux", "set-option", "-p", "-t", target,
                "@pilot-owner", new_owner,
            ])
            if set_result.returncode == 0:
                updated.append(target)

    if not updated:
        return f"No panes found with @pilot-owner={old_owner!r}"
    return f"Updated {len(updated)} pane(s): {', '.join(updated)}"


# ---------------------------------------------------------------------------
# run_command_silent
# ---------------------------------------------------------------------------
@mcp.tool()
def run_command_silent(
    command: str,
    directory: str,
    timeout_minutes: int = 15,
    uuid: str | None = None,
) -> str:
    """Run a command silently, return exit code and tail of output. Full output saved to a log file.

    The command's stdout/stderr go to a temp file, not to the MCP response.
    Only the exit code and last N lines are returned — keeping LLM context clean.

    Args:
        command: Shell command to execute.
        directory: Working directory for the command.
        timeout_minutes: Max execution time (default 15).
        uuid: Optional UUID (not used in this tool, kept for consistency).
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
