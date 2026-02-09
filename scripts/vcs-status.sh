#!/usr/bin/env bash
# Open VCS status in nvim — supports git (fugitive)
# and hg (lawrencium).
set -euo pipefail

# Resolve working directory from the client's active pane
# (not the popup pane). pilot-workdir takes priority,
# then pane_current_path, then $HOME.
dir=""
client_pane=$(tmux display-message -p \
  '#{client_last_session}:#{client_last_window}.#{client_last_pane}' \
  2>/dev/null) || client_pane=""

if [ -n "$client_pane" ]; then
  dir=$(tmux display-message -t "$client_pane" \
    -p '#{@pilot-workdir}' 2>/dev/null) || dir=""
  if [ -z "$dir" ]; then
    dir=$(tmux display-message -t "$client_pane" \
      -p '#{pane_current_path}' 2>/dev/null) || dir=""
  fi
fi
[ -z "$dir" ] && dir="$HOME"
[ -d "$dir" ] && cd "$dir"

if ! command -v nvim &>/dev/null; then
  printf '\n  nvim is not installed.\n\n'
  printf '  Press any key to close.'
  read -n1
  exit 1
fi

if git rev-parse --show-toplevel &>/dev/null; then
  nvim +Git
elif hg root &>/dev/null; then
  nvim +Hgstatus
else
  printf '\n  Not a git or hg repository.\n\n'
  printf '  Press any key to close.'
  read -n1
fi
