#!/usr/bin/env bash
# Agent dashboard — fzf-based tmux agent manager.
# Lists all panes across sessions, previews output,
# and provides inline actions.
#
# Usage:
#   deck.sh          Launch interactive dashboard
#   deck.sh --list   Output pane list only (reload)
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Unit separator — safe delimiter
SEP=$'\x1f'

# Build an indexed data file:
#   line N = target<TAB>path
# and a display list:
#   line N = index<TAB>display columns
# The index is a simple line number — never contains
# user-controlled data, so it's safe in fzf fields.

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
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$activity" "$target" "$path" \
      "$session" "$name" "$title" "$age" "$short_path"
  done
}

PILOT_DATA=$(mktemp)
trap 'rm -f "$PILOT_DATA"' EXIT

build_data() {
  local tmpfile sorted
  tmpfile=$(mktemp)
  sorted=$(mktemp)

  list_panes > "$tmpfile"
  sort -t$'\t' -k1,1 -rn "$tmpfile" > "$sorted"
  rm -f "$tmpfile"

  # Data file: target<TAB>path (one per line, indexed)
  cut -d$'\t' -f2,3 "$sorted" > "$PILOT_DATA"

  # Display: index<TAB>visible columns
  local idx=1
  cut -d$'\t' -f4- "$sorted" | column -t |
  while IFS= read -r display_line; do
    printf '%s\t%s\n' "$idx" "$display_line"
    idx=$((idx + 1))
  done

  rm -f "$sorted"
}

# --list mode for reload: rebuild data + display
if [[ "${1:-}" == "--list" ]]; then
  data_file="${2:-}"
  if [[ -z "$data_file" ]]; then
    echo "error: --list requires data file path" >&2
    exit 1
  fi

  tmpfile=$(mktemp)
  sorted=$(mktemp)
  now=$(date +%s)

  tmux list-panes -a -F \
    "#{session_name}:#{window_index}.#{pane_index}${SEP}#{session_name}${SEP}#{window_name}${SEP}#{pane_title}${SEP}#{pane_current_path}${SEP}#{window_activity}" |
  while IFS="$SEP" read -r target session name title path activity; do
    elapsed=$((now - activity))
    if [ "$elapsed" -lt 60 ]; then
      age="active"
    elif [ "$elapsed" -lt 3600 ]; then
      age="$((elapsed / 60))m ago"
    elif [ "$elapsed" -lt 86400 ]; then
      age="$((elapsed / 3600))h ago"
    else
      age="$((elapsed / 86400))d ago"
    fi
    short_path="${path/#$HOME/\~}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$activity" "$target" "$path" \
      "$session" "$name" "$title" "$age" "$short_path"
  done > "$tmpfile"

  sort -t$'\t' -k1,1 -rn "$tmpfile" > "$sorted"
  rm -f "$tmpfile"

  # Overwrite the data file
  cut -d$'\t' -f2,3 "$sorted" > "$data_file"

  idx=1
  cut -d$'\t' -f4- "$sorted" | column -t |
  while IFS= read -r display_line; do
    printf '%s\t%s\n' "$idx" "$display_line"
    idx=$((idx + 1))
  done

  rm -f "$sorted"
  exit 0
fi

# Lookup target and path from data file by index
lookup() {
  local idx="$1" field="$2"
  if [[ ! "$idx" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  local line
  line=$(sed -n "${idx}p" "$PILOT_DATA")
  case "$field" in
    target) printf '%s' "${line%%	*}" ;;
    path)   printf '%s' "${line#*	}" ;;
  esac
}

# Build initial data
display=$(build_data)

# Main dispatch loop — fzf exits, we read the key +
# selection, perform the action, then re-launch fzf
# (except for enter/esc which break out).
while true; do
  result=$(echo "$display" |
    fzf --ansi --no-sort \
      --delimiter '\t' --with-nth 2 \
      --header "enter=attach  ^e/^y=scroll  ^d/^u=page  M-d=diff  M-s=commit  M-x=kill  M-p=pause  M-r=resume  M-n=new" \
      --preview "$CURRENT_DIR/_preview.sh {1} $PILOT_DATA" \
      --preview-window=right:60%:follow \
      --bind "ctrl-e:preview-down,ctrl-y:preview-up" \
      --bind "ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up" \
      --expect "enter,alt-d,alt-s,alt-x,alt-p,alt-r,alt-n" \
    ) || break  # esc / ctrl-c → exit

  # Parse: first line = key pressed, second line = selected
  key=$(head -1 <<< "$result")
  selection=$(tail -1 <<< "$result")
  idx=${selection%%	*}

  case "$key" in
    enter)
      target=$(lookup "$idx" target) || break
      tmux switch-client -t "$target"
      break
      ;;
    alt-d)
      path=$(lookup "$idx" path) || continue
      (cd "$path" && git diff --color=always | less -R)
      ;;
    alt-s)
      path=$(lookup "$idx" path) || continue
      "$CURRENT_DIR/commit.sh" "$path"
      ;;
    alt-x)
      target=$(lookup "$idx" target) || continue
      path=$(lookup "$idx" path) || continue
      "$CURRENT_DIR/kill.sh" "$target" "$path"
      # Rebuild data after kill
      display=$(build_data)
      ;;
    alt-p)
      target=$(lookup "$idx" target) || continue
      tmux send-keys -t "$target" '/exit' Enter
      ;;
    alt-r)
      target=$(lookup "$idx" target) || continue
      tmux send-keys -t "$target" 'claude --continue' Enter
      ;;
    alt-n)
      "$CURRENT_DIR/new-agent.sh"
      # Rebuild data after new agent
      display=$(build_data)
      ;;
    *)
      break
      ;;
  esac
done
