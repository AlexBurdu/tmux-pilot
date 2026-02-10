#!/usr/bin/env bash
# Open VCS status in nvim — supports git (fugitive)
# and hg (lawrencium).
set -euo pipefail

# Working directory is set by display-popup -d '#{pane_current_path}'
# which resolves to the caller pane's path at bind-time.
cd "$PWD"

if ! command -v nvim &>/dev/null; then
  printf '\n  nvim is not installed.\n\n'
  printf '  Press any key to close.'
  read -t 5 -n1
  exit 1
fi

if git rev-parse --show-toplevel &>/dev/null; then
  nvim +Git +only
elif hg root &>/dev/null; then
  nvim +Hgstatus
else
  printf '\n  Not a git or hg repository.\n\n'
  printf '  Press any key to close.'
  read -t 5 -n1
fi
