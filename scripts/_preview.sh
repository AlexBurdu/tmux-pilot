#!/usr/bin/env bash
# Safe preview helper for deck.sh.
# Looks up a pane target by numeric index from a data
# file and captures its output.
#
# Usage: _preview.sh <index> <data-file>
set -euo pipefail

idx="${1:?index required}"
data_file="${2:?data file required}"

# Validate index is numeric
if [[ ! "$idx" =~ ^[0-9]+$ ]]; then
  echo "invalid index"
  exit 1
fi

# Validate data file exists
if [[ ! -f "$data_file" ]]; then
  echo "data file not found"
  exit 1
fi

# Look up target (field 1) from the data file by line number
target=$(sed -n "${idx}p" "$data_file" | cut -d$'\t' -f1)

if [[ -z "$target" ]]; then
  echo "no pane at index $idx"
  exit 1
fi

tmux capture-pane -t "$target" -p -e -S -500
