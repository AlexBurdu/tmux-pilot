#!/usr/bin/env bash
# Kill a tmux pane/window and clean up its worktree.
# Usage: kill.sh <pane-target> <worktree-path>
set -euo pipefail

target="${1:?pane target required}"
wt_path="${2:?worktree path required}"

# Kill the tmux pane
tmux kill-pane -t "$target" 2>/dev/null || true

# Clean up the worktree if it looks like one
if [[ "$wt_path" == *-worktree/* ]]; then
  repo_root="${wt_path%%-worktree/*}"
  if [[ -d "$repo_root" ]]; then
    err=""
    if ! err=$(git -C "$repo_root" worktree remove \
        "$wt_path" 2>&1); then
      echo "WARNING: worktree removal failed: $err"
    fi
    git -C "$repo_root" worktree prune 2>/dev/null || true
    echo "Cleaned up worktree: $wt_path"
  fi
fi
