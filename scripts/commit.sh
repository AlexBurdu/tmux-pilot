#!/usr/bin/env bash
# Commit + push a worktree's changes as WIP.
# Usage: commit.sh <worktree-path>
set -euo pipefail

wt_path="${1:-.}"

cd "$wt_path"

branch=$(git branch --show-current)
if [[ -z "$branch" || "$branch" == "main" || "$branch" == "master" ]]; then
  echo "Error: refusing to commit on ${branch:-detached HEAD}"
  exit 1
fi

git add -A
git commit -m "WIP: progress on $branch" || {
  echo "Nothing to commit"; exit 0
}
git push -u origin "$branch"
echo "Committed and pushed $branch"
