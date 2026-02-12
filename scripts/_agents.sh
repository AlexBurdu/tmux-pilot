#!/usr/bin/env bash
# Shared agent configuration — launch commands, pause/resume.
# Source this file; do not execute directly.

# Build the command array for launching an agent with a prompt.
# Sets the caller's cmd_args array.
agent_build_cmd() {
  local agent="$1" prompt="$2"
  case "$agent" in
    aider)       cmd_args=(aider --message "$prompt") ;;
    goose)       cmd_args=(goose run "$prompt") ;;
    interpreter) cmd_args=(interpreter --message "$prompt") ;;
    *)           cmd_args=("$agent" "$prompt") ;;
  esac
}

# Send the appropriate stop command to a pane.
agent_pause() {
  local target="$1" agent="$2"
  case "$agent" in
    claude)      tmux send-keys -t "$target" '/exit' Enter ;;
    gemini)      tmux send-keys -t "$target" '/quit' Enter ;;
    aider)       tmux send-keys -t "$target" '/exit' Enter ;;
    goose)       tmux send-keys -t "$target" C-d ;;
    *)           tmux send-keys -t "$target" C-c ;;
  esac
}

# Send the appropriate resume/restart command to a pane.
agent_resume() {
  local target="$1" agent="$2"
  case "$agent" in
    claude)      tmux send-keys -t "$target" 'claude --continue' Enter ;;
    goose)       tmux send-keys -t "$target" 'goose session resume' Enter ;;
    *)           tmux send-keys -t "$target" "$agent" Enter ;;
  esac
}
