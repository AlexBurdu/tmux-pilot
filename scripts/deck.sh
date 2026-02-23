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
source "$CURRENT_DIR/_agents.sh"
# Unit separator — safe delimiter
SEP=$'\x1f'

# Status enum → emoji mapping.
# External tools write semantic values to @pilot-status;
# the deck renders them as icons.
# Set @pilot-status-ascii "1" in tmux.conf for BMP fallback.
USE_ASCII=$(tmux show-option -gqv @pilot-status-ascii 2>/dev/null)
status_icon() {
  local raw="$1"
  if [[ "$USE_ASCII" == "1" ]]; then
    case "$raw" in
      working)  printf '\033[32m●\033[0m' ;;  # green
      watching) printf '\033[34m◉\033[0m' ;;  # blue
      waiting)  printf '\033[33m⚠\033[0m' ;;  # yellow
      paused)   printf '\033[90m‖\033[0m' ;;  # gray
      done)     printf '\033[32m✔\033[0m' ;;  # green
      *)        printf ' ' ;;
    esac
  else
    case "$raw" in
      working)  printf '▶️' ;;
      watching) printf '👀' ;;
      waiting)  printf '✋' ;;
      paused)   printf '⏸️' ;;
      done)     printf '✅' ;;
      *)        printf ' ' ;;
    esac
  fi
}

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
# Sets globals: COL_SES COL_PANE COL_STATUS COL_AGE COL_CPU COL_MEM
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
  COL_PANE=14  # window_name:win_idx.pane_idx
  COL_STATUS=4 # status emoji
  local gaps=10  # column-t 2-space gaps between 6 columns (5 gaps)
  local fixed=$(( COL_PANE + COL_STATUS + COL_AGE + COL_CPU + COL_MEM + gaps ))

  # Session column gets whatever space remains after fixed columns
  COL_SES=$(( list_w - fixed ))
  if [[ $COL_SES -lt 8 ]]; then COL_SES=8; fi
}
compute_layout

# Column header with bold styling (fzf --ansi processes escape codes)
COL_HEADER=$(printf '\033[1m%-*.*s  %-*.*s  %-*.*s  %-*.*s  %-*.*s  %-*.*s\033[0m' \
  "$COL_SES" "$COL_SES" "SESSION" "$COL_PANE" "$COL_PANE" "PANE" \
  "$COL_STATUS" "$COL_STATUS" "STAT" \
  "$COL_AGE" "$COL_AGE" "AGE" "$COL_CPU" "$COL_CPU" "CPU" "$COL_MEM" "$COL_MEM" "MEM")

# Separator line matching column header width
COL_SEP_W=$(( COL_SES + COL_PANE + COL_STATUS + COL_AGE + COL_CPU + COL_MEM + 10 ))
COL_SEP=$(printf '─%.0s' $(seq 1 "$COL_SEP_W"))

# Align pre-truncated columns (column -t handles emoji/wide chars).
# A ruler row forces column-t to allocate full budgeted widths
# even when actual data is shorter.
format_display() {
  local ruler
  ruler=$(printf '%*s\t%*s\t%*s\t%*s\t%*s\t%*s' \
    "$COL_SES" "" "$COL_PANE" "" "$COL_STATUS" "" \
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
    "#{session_name}:#{window_index}.#{pane_index}${SEP}#{session_name}${SEP}#{window_index}${SEP}#{window_name}${SEP}#{pane_current_command}${SEP}#{pane_index}${SEP}#{pane_title}${SEP}#{pane_current_path}${SEP}#{@pilot-workdir}${SEP}#{window_activity}${SEP}#{pane_pid}${SEP}#{@pilot-host}${SEP}#{@pilot-status}${SEP}#{@pilot-needs-help}" |
  while IFS= read -r _line; do
    # tmux <3.5 escapes 0x1F to literal \037 in format output; decode it
    _line="${_line//\\037/$SEP}"
    IFS="$SEP" read -r target session win_idx win_name pane_cmd pane_idx title path workdir activity pane_pid pilot_host pilot_status pilot_needs_help <<< "$_line"
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
    # Append @host suffix when running on a remote host
    if [[ -n "$pilot_host" ]]; then
      session="${session}@${pilot_host}"
    fi
    [[ ${#session} -gt $COL_SES ]] && session="${session:0:$((COL_SES - 2))}.."
    local pane_col="${win_name}:${win_idx}.${pane_idx}"
    [[ ${#pane_col} -gt $COL_PANE ]] && pane_col="${pane_col:0:$((COL_PANE - 2))}.."
    local status
    if [[ -n "$pilot_needs_help" ]]; then
      status=$(status_icon "waiting")
    elif [[ -n "$pilot_status" ]]; then
      status=$(status_icon "$pilot_status")
    else
      status=" "
    fi
    local mem cpu
    mem=$(pane_tree_mem "$pane_pid" <<< "$ps_data")
    cpu=$(pane_tree_cpu "$pane_pid" <<< "$ps_data")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$activity" "$target" "$path" \
      "$session" "$pane_col" "$status" "$age" "$cpu" "$mem"
  done
}

PILOT_DATA=$(mktemp)
trap 'rm -f "$PILOT_DATA"' EXIT

# Build indexed data file and display list.
# Usage: build_data [data_file]
# Writes target<TAB>path to data_file (defaults to $PILOT_DATA).
build_data() {
  local data_file="${1:-$PILOT_DATA}"
  local tmpfile sorted
  tmpfile=$(mktemp)
  sorted=$(mktemp)

  list_panes > "$tmpfile"
  sort -t$'\t' -k1,1 -rn "$tmpfile" > "$sorted"
  rm -f "$tmpfile"

  # Data file: target<TAB>path (one per line, indexed)
  cut -d$'\t' -f2,3 "$sorted" > "$data_file"

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
  build_data "$data_file"
  exit 0
fi

# Current pane target (set by pilot.tmux via set-environment before popup opens)
CURRENT_TARGET=$(tmux show-environment -g PILOT_DECK_ORIGIN 2>/dev/null | sed 's/^[^=]*=//')

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

# Find the 1-based position of $CURRENT_TARGET in the data file.
# Returns "" if not found (fzf defaults to first item).
find_current_pos() {
  [[ -z "$CURRENT_TARGET" ]] && return
  local idx=1
  while IFS=$'\t' read -r target _; do
    if [[ "$target" == "$CURRENT_TARGET" ]]; then
      echo "$idx"
      return
    fi
    idx=$((idx + 1))
  done < "$PILOT_DATA"
}

# Build initial data
display=$(build_data)

# Main dispatch loop — fzf exits, we read the key +
# selection, perform the action, then re-launch fzf
# (except for enter/esc which break out).
while true; do
  # Position cursor on the current pane (requires fzf 0.53+)
  start_pos=$(find_current_pos)
  fzf_start_bind=()
  if [[ -n "$start_pos" ]]; then
    fzf_start_bind=(--bind "load:pos($start_pos)+refresh-preview")
  fi

  result=$(fzf --ansi --no-sort --layout=reverse \
      --delimiter '\t' --with-nth 2 \
      --header "Enter=attach  Ctrl-e/y=scroll  Ctrl-d/u=page  Ctrl-w=wrap
Alt-d=diff  Alt-s=commit  Alt-x=kill  Alt-l=log
Alt-p=pause  Alt-r=resume  Alt-n=new  Alt-e=desc  Alt-y=approve
$COL_SEP" \
      --header-lines=1 \
      --preview "$CURRENT_DIR/_preview.sh {1} $PILOT_DATA" \
      --preview-window=right:60%:follow:~10 \
      --bind "ctrl-e:preview-down,ctrl-y:preview-up" \
      --bind "ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up" \
      --bind "ctrl-w:change-preview-window(wrap|nowrap)" \
      --expect "enter,alt-d,alt-s,alt-x,alt-p,alt-r,alt-n,alt-e,alt-y,alt-l" \
      "${fzf_start_bind[@]}" \
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
      agent_pause "$target" "$agent"
      ;;
    alt-r)
      target=$(lookup "$idx" target) || continue
      agent=$(detect_agent "$target") || agent=""
      agent_resume "$target" "$agent"
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
    alt-y)
      target=$(lookup "$idx" target) || continue
      tmux send-keys -t "$target" Enter
      ;;
    alt-l)
      if [[ -f /tmp/tmux-pilot-watchdog.log ]]; then
        less +G /tmp/tmux-pilot-watchdog.log
      else
        echo "No watchdog log found"
        sleep 1
      fi
      ;;
    *)
      break
      ;;
  esac
done
