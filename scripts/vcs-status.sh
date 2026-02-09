#!/usr/bin/env bash
# Open VCS status in nvim — supports git (fugitive) and hg (lawrencium).
set -euo pipefail

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
