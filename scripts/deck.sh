#!/usr/bin/env bash
# Agent dashboard — fzf-based tmux agent manager.
# Lists all panes across sessions, previews output,
# and provides inline actions.
#
# Usage:
#   deck.sh          Launch interactive dashboard
#   deck.sh --list   Output pane list only (used by fzf reload)
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEP=$'\x1f'  # Unit separator — safe delimiter (won't appear in pane titles)

# Raw output fields (tab-separated):
#   activity_timestamp (stripped after sorting)
#   session:win.pane   → {1} after sort/strip (hidden — used by bindings)
#   full_path          → {2} after sort/strip (hidden — used by bindings)
#   aligned display    → {3} after sort/strip (visible)
list_panes() {
  local now
  now=$(date +%s)
  tmux list-panes -a -F \
    "#{session_name}:#{window_index}.#{pane_index}${SEP}#{session_name}${SEP}#{window_name}${SEP}#{pane_title}${SEP}#{pane_current_path}${SEP}#{window_activity}" |
  while IFS="$SEP" read -r target session name title path activity; do
    local elapsed=$((now - activity))
    local age
    if [ "$elapsed" -lt 60 ]; then
      age="active"
    elif [ "$elapsed" -lt 3600 ]; then
      age="$((elapsed / 60))m ago"
    elif [ "$elapsed" -lt 86400 ]; then
      age="$((elapsed / 3600))h ago"
    else
      age="$((elapsed / 86400))d ago"
    fi
    local short_path="${path/#$HOME/\~}"
    # Sort key (activity timestamp), then hidden fields, then visible (tab-separated for column)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$activity" "$target" "$path" "$session" "$name" "$title" "$age" "$short_path"
  done
}

build_list() {
  local tmpfile
  tmpfile=$(mktemp)
  # Sort by activity timestamp (field 1) descending, then strip it
  list_panes | sort -t$'\t' -k1,1 -rn > "$tmpfile"
  paste \
    <(cut -d$'\t' -f2,3 "$tmpfile") \
    <(cut -d$'\t' -f4- "$tmpfile" | column -t)
  rm -f "$tmpfile"
}

# Allow fzf reload to call this script directly
if [[ "${1:-}" == "--list" ]]; then
  build_list
  exit 0
fi

build_list |
fzf --ansi --no-sort --delimiter '\t' --with-nth 3 \
  --header "enter=attach  ^e/^y=scroll  ^d/^u=page  M-d=diff  M-s=commit  M-x=kill  M-p=pause  M-r=resume  M-n=new" \
  --preview 'tmux capture-pane -t {1} -p -e -S -500' \
  --preview-window=right:60%:follow \
  --bind "ctrl-e:preview-down,ctrl-y:preview-up" \
  --bind "ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up" \
  --bind "enter:execute-silent(tmux switch-client -t {1})+abort" \
  --bind "alt-d:execute-silent(tmux display-popup -w 80% -h 80% -E \
    'cd {2} && git diff --color=always | less -R')" \
  --bind "alt-s:execute($CURRENT_DIR/commit.sh {2})" \
  --bind "alt-x:execute($CURRENT_DIR/kill.sh {1} {2})+reload($CURRENT_DIR/deck.sh --list)" \
  --bind "alt-p:execute(tmux send-keys -t {1} '/exit' Enter)" \
  --bind "alt-r:execute(tmux send-keys -t {1} 'claude --continue' Enter)" \
  --bind "alt-n:execute($CURRENT_DIR/new-agent.sh)"
