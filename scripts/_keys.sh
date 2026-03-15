#!/usr/bin/env bash
# Shared key-sending logic. Source this file; do not execute directly.

# Send text to a pane via paste-buffer (bypasses popup overlays).
# Control keys still use send-keys since paste-buffer can't send them.
#
# Args:
#   $1 - target pane
#   $2 - text to send
#   $3 - (optional) if set, do NOT automatically send Enter at the end
#        unless the agent is 'vibe' (which always needs a separate Enter).
send_text() {
  local target="$1" text="$2" no_enter="${3:-}"
  printf '%s' "$text" | tmux load-buffer -
  tmux paste-buffer -d -p -t "$target"

  # Detect agent type
  local agent
  agent=$(tmux display-message -t "$target" -p '#{@pilot-agent}' 2>/dev/null)

  # Agent-specific submit sequences.
  case "$agent" in
    vibe)
      # Vibe TUI needs a delay before Enter.
      sleep 0.1
      tmux send-keys -t "$target" Enter
      return
      ;;
    gemini)
      # Gemini uses vim-like input: Escape to
      # NORMAL mode, Enter to submit.
      tmux send-keys -t "$target" Escape
      sleep 0.05
      tmux send-keys -t "$target" Enter
      return
      ;;
  esac

  # Default: send Enter unless suppressed.
  if [[ -z "$no_enter" ]]; then
    tmux send-keys -t "$target" Enter
  fi
}
