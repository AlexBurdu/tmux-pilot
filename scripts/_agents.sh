#!/usr/bin/env bash
# Shared agent configuration — launch commands, pause/resume.
# Source this file; do not execute directly.

# Single source of truth for supported agent names.
KNOWN_AGENTS="claude gemini aider codex goose interpreter"

# Build the command array for launching an agent with a prompt.
# Sets the caller's cmd_args array.
agent_build_cmd() {
  local agent="$1" prompt="$2"
  case "$agent" in
    gemini)      cmd_args=(bash -lc 'exec gemini -y "$0"' "$prompt") ;;
    aider)       cmd_args=(aider --message "$prompt") ;;
    goose)       cmd_args=(goose run "$prompt") ;;
    interpreter) cmd_args=(interpreter --message "$prompt") ;;
    *)           cmd_args=("$agent" "$prompt") ;;
  esac
}

# Send text to a pane via paste-buffer (bypasses popup overlays).
# Control keys still use send-keys since paste-buffer can't send them.
_send_text() {
  local target="$1" text="$2"
  printf '%s' "$text" | tmux load-buffer -
  tmux paste-buffer -d -p -t "$target"
  tmux send-keys -t "$target" Enter
}

# Send the appropriate stop command to a pane.
agent_pause() {
  local target="$1" agent="$2"
  case "$agent" in
    claude)      _send_text "$target" '/exit' ;;
    gemini)      _send_text "$target" '/quit' ;;
    aider)       _send_text "$target" '/exit' ;;
    goose)       tmux send-keys -t "$target" C-d ;;
    *)           tmux send-keys -t "$target" C-c ;;
  esac
  tmux set-option -p -t "$target" @pilot-status "paused" 2>/dev/null || true
}

# Send the appropriate resume/restart command to a pane.
agent_resume() {
  local target="$1" agent="$2"
  tmux set-option -p -t "$target" @pilot-status "working" 2>/dev/null || true
  case "$agent" in
    claude)      _send_text "$target" 'claude --continue' ;;
    gemini)      _send_text "$target" "bash -lc 'gemini -y'" ;;
    goose)       _send_text "$target" 'goose session resume' ;;
    *)           _send_text "$target" "$agent" ;;
  esac
}

# Detect which agent is running in a pane.
# Checks @pilot-agent option first, then falls back to
# scanning the pane's child processes for known agent names.
detect_agent() {
  local target="$1"
  local agent
  agent=$(tmux display-message -t "$target" -p '#{@pilot-agent}' 2>/dev/null)
  if [[ -n "$agent" ]]; then
    printf '%s' "$agent"
    return
  fi
  # Fallback: walk the full process tree under the pane PID
  # and match command names against known agents.
  local pane_pid
  pane_pid=$(tmux display-message -t "$target" -p '#{pane_pid}' 2>/dev/null) || return 1
  agent=$(ps -ax -o pid=,ppid=,comm= | awk \
    -v root="$pane_pid" \
    -v agents="$KNOWN_AGENTS" '
    { ppid[$1]=$2; comm[$1]=$3 }
    END {
      pids[root]=1; changed=1
      while (changed) {
        changed=0
        for (p in ppid)
          if (!(p in pids) && ppid[p] in pids) { pids[p]=1; changed=1 }
      }
      n=split(agents, names, " ")
      for (p in pids)
        for (i=1; i<=n; i++)
          if (comm[p] == names[i]) { print names[i]; exit }
    }')
  if [[ -n "$agent" ]]; then
    printf '%s' "$agent"
    return
  fi
  return 1
}
