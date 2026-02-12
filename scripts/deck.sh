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

# Get human-readable RSS of a process tree.
# Reads ps output from stdin, takes root PID as $1.
pane_tree_mem() {
  awk -v root="$1" '
    { mem[$1]=$3; parent[$1]=$2 }
    END {
      pids[root]=1; changed=1
      while (changed) { changed=0; for (p in parent) if (!(p in pids) && parent[p] in pids) { pids[p]=1; changed=1 } }
      for (p in pids) kb+=mem[p]
      if (kb >= 1048576) printf "%.1fG", kb/1048576
      else if (kb >= 1024) printf "%dM", kb/1024
      else printf "%dK", kb+0
    }'
}

# Sum CPU% of a process tree.
# Reads ps output from stdin, takes root PID as $1.
pane_tree_cpu() {
  awk -v root="$1" '
    { cpu[$1]=$4; parent[$1]=$2 }
    END {
      pids[root]=1; changed=1
      while (changed) { changed=0; for (p in parent) if (!(p in pids) && parent[p] in pids) { pids[p]=1; changed=1 } }
      for (p in pids) t+=cpu[p]
      printf "%d%%", t+0
    }'
}

# Compute column widths from terminal size.
# Sets globals: COL_SES COL_WIN COL_AGE COL_CPU COL_MEM
compute_layout() {
  local total_cols popup_w client_w pct
  # Query tmux directly (tput unreliable during popup PTY init)
  popup_w=$(tmux show-option -gqv @pilot-popup-deck-width 2>/dev/null)
  : "${popup_w:=95%}"
  if [[ "$popup_w" == *% ]]; then
    client_w=$(tmux display-message -p '#{client_width}' 2>/dev/null) || client_w=120
    pct=${popup_w%'%'}
    total_cols=$(( client_w * pct / 100 ))
  else
    total_cols=$popup_w
  fi
  # List panel: 40% of popup minus fzf chrome (preview gets 60%)
  local list_w=$(( total_cols * 40 / 100 - 4 ))

  # Fixed-width columns (never truncated)
  COL_AGE=7    # "active", "5m ago", "12h ago"
  COL_CPU=4    # "0%", "100%"
  COL_MEM=5    # "1.3G", "429M"
  COL_WIN=8    # window name
  local gaps=8  # column-t 2-space gaps between 5 columns (4 gaps)
  local fixed=$(( COL_WIN + COL_AGE + COL_CPU + COL_MEM + gaps ))

  # Session column gets whatever space remains after fixed columns
  COL_SES=$(( list_w - fixed ))
  if [[ $COL_SES -lt 8 ]]; then COL_SES=8; fi
}
compute_layout

# Column header with bold styling (fzf --ansi processes escape codes)
COL_HEADER=$(printf '\033[1m%-*.*s  %-*.*s  %-*.*s  %-*.*s  %-*.*s\033[0m' \
  "$COL_SES" "$COL_SES" "SESSION" "$COL_WIN" "$COL_WIN" "WINDOW" \
  "$COL_AGE" "$COL_AGE" "AGE" "$COL_CPU" "$COL_CPU" "CPU" "$COL_MEM" "$COL_MEM" "MEM")

# Separator line matching column header width
COL_SEP_W=$(( COL_SES + COL_WIN + COL_AGE + COL_CPU + COL_MEM + 8 ))
COL_SEP=$(printf '─%.0s' $(seq 1 "$COL_SEP_W"))

# Align pre-truncated columns (column -t handles emoji/wide chars).
# A ruler row forces column-t to allocate full budgeted widths
# even when actual data is shorter.
format_display() {
  local ruler
  ruler=$(printf '%*s\t%*s\t%*s\t%*s\t%*s' \
    "$COL_SES" "" "$COL_WIN" "" \
    "$COL_AGE" "" "$COL_CPU" "" "$COL_MEM" "" | tr ' ' '_')
  { echo "$ruler"; cat; } | column -t -s$'\t' | tail -n +2
}

# Build an indexed data file:
#   line N = target<TAB>path
# and a display list:
#   line N = index<TAB>display columns
# The index is a simple line number — never contains
# user-controlled data, so it's safe in fzf fields.

list_panes() {
  local now ps_data
  now=$(date +%s)
  ps_data=$(ps -ax -o pid=,ppid=,rss=,%cpu=)
  tmux list-panes -a -F \
    "#{session_name}:#{window_index}.#{pane_index}${SEP}#{session_name}${SEP}#{window_index}${SEP}#{window_name}${SEP}#{pane_title}${SEP}#{pane_current_path}${SEP}#{@pilot-workdir}${SEP}#{window_activity}${SEP}#{pane_pid}" |
  while IFS="$SEP" read -r target session win_idx name title path workdir activity pane_pid; do
    [[ -n "$workdir" ]] && path="$workdir"
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
    local max_ses=$((COL_SES - ${#win_idx} - 1))
    [[ $max_ses -lt 2 ]] && max_ses=2
    [[ ${#session} -gt $max_ses ]] && session="${session:0:$((max_ses - 2))}.."
    [[ ${#name} -gt $COL_WIN ]] && name="${name:0:$((COL_WIN - 2))}.."
    local mem cpu
    mem=$(pane_tree_mem "$pane_pid" <<< "$ps_data")
    cpu=$(pane_tree_cpu "$pane_pid" <<< "$ps_data")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$activity" "$target" "$path" \
      "$session:$win_idx" "$name" "$age" "$cpu" "$mem"
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
  cut -d$'\t' -f4- "$sorted" | format_display |
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
  ps_data=$(ps -ax -o pid=,ppid=,rss=,%cpu=)

  tmux list-panes -a -F \
    "#{session_name}:#{window_index}.#{pane_index}${SEP}#{session_name}${SEP}#{window_index}${SEP}#{window_name}${SEP}#{pane_title}${SEP}#{pane_current_path}${SEP}#{@pilot-workdir}${SEP}#{window_activity}${SEP}#{pane_pid}" |
  while IFS="$SEP" read -r target session win_idx name title path workdir activity pane_pid; do
    [[ -n "$workdir" ]] && path="$workdir"
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
    max_ses=$((COL_SES - ${#win_idx} - 1))
    [[ $max_ses -lt 2 ]] && max_ses=2
    [[ ${#session} -gt $max_ses ]] && session="${session:0:$((max_ses - 2))}.."
    [[ ${#name} -gt $COL_WIN ]] && name="${name:0:$((COL_WIN - 2))}.."
    mem=$(pane_tree_mem "$pane_pid" <<< "$ps_data")
    cpu=$(pane_tree_cpu "$pane_pid" <<< "$ps_data")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$activity" "$target" "$path" \
      "$session:$win_idx" "$name" "$age" "$cpu" "$mem"
  done > "$tmpfile"

  sort -t$'\t' -k1,1 -rn "$tmpfile" > "$sorted"
  rm -f "$tmpfile"

  # Overwrite the data file
  cut -d$'\t' -f2,3 "$sorted" > "$data_file"

  idx=1
  cut -d$'\t' -f4- "$sorted" | format_display |
  while IFS= read -r display_line; do
    printf '%s\t%s\n' "$idx" "$display_line"
    idx=$((idx + 1))
  done

  rm -f "$sorted"
  exit 0
fi

# Detect which agent is running in a pane.
# Checks @pilot-agent option first, then falls back to
# scanning the pane's child processes for known agent names.
detect_agent() {
  local target="$1"
  local agent
  agent=$(tmux display-message -t "$target" -p '#{@pilot-agent}' 2>/dev/null)
  if [[ -n "$agent" ]]; then
    printf '%s' "$agent"
    return
  fi
  # Fallback: scan child commands of pane PID
  local pane_pid children
  pane_pid=$(tmux display-message -t "$target" -p '#{pane_pid}' 2>/dev/null) || return 1
  children=$(pgrep -P "$pane_pid" 2>/dev/null) || return 1
  local child_cmds
  child_cmds=$(ps -o comm= -p $children 2>/dev/null) || return 1
  local name
  for name in claude gemini aider codex goose interpreter; do
    if grep -qw "$name" <<< "$child_cmds"; then
      printf '%s' "$name"
      return
    fi
  done
  return 1
}

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
  result=$(fzf --ansi --no-sort --layout=reverse \
      --delimiter '\t' --with-nth 2 \
      --header "Enter=attach  Ctrl-e/y=scroll  Ctrl-d/u=page  Ctrl-w=wrap
Alt-d=diff  Alt-s=commit  Alt-x=kill
Alt-p=pause  Alt-r=resume  Alt-n=new  Alt-e=desc
$COL_SEP" \
      --header-lines=1 \
      --preview "$CURRENT_DIR/_preview.sh {1} $PILOT_DATA" \
      --preview-window=right:60%:follow:~7 \
      --bind "ctrl-e:preview-down,ctrl-y:preview-up" \
      --bind "ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up" \
      --bind "ctrl-w:change-preview-window(wrap|nowrap)" \
      --expect "enter,alt-d,alt-s,alt-x,alt-p,alt-r,alt-n,alt-e" \
    <<< "0	$COL_HEADER
$display") || break  # esc / ctrl-c → exit

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
      agent=$(detect_agent "$target") || agent=""
      case "$agent" in
        claude)      tmux send-keys -t "$target" '/exit' Enter ;;
        gemini)      tmux send-keys -t "$target" '/quit' Enter ;;
        aider)       tmux send-keys -t "$target" '/exit' Enter ;;
        goose)       tmux send-keys -t "$target" C-d ;;
        *)           tmux send-keys -t "$target" C-c ;;
      esac
      ;;
    alt-r)
      target=$(lookup "$idx" target) || continue
      agent=$(detect_agent "$target") || agent=""
      case "$agent" in
        claude)      tmux send-keys -t "$target" 'claude --continue' Enter ;;
        gemini)      tmux send-keys -t "$target" 'gemini' Enter ;;
        aider)       tmux send-keys -t "$target" 'aider' Enter ;;
        codex)       tmux send-keys -t "$target" 'codex' Enter ;;
        goose)       tmux send-keys -t "$target" 'goose session resume' Enter ;;
        interpreter) tmux send-keys -t "$target" 'interpreter' Enter ;;
        *)           tmux send-keys -t "$target" "$agent" Enter ;;
      esac
      ;;
    alt-n)
      "$CURRENT_DIR/new-agent.sh"
      # Rebuild data after new agent
      display=$(build_data)
      ;;
    alt-e)
      target=$(lookup "$idx" target) || continue
      cur=$(tmux display-message -t "$target" -p '#{@pilot-desc}' 2>/dev/null) || cur=""
      printf '\n  Description: '
      read -rei "$cur" new_desc
      if [[ -n "$new_desc" ]]; then
        tmux set-option -p -t "$target" @pilot-desc "$new_desc"
      fi
      ;;
    *)
      break
      ;;
  esac
done
