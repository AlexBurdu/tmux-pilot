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
source "$CURRENT_DIR/_hosts.sh"
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

# Ensure all panes have a UUID (@pilot-uuid)
tmux list-panes -a \
  -F '#{session_name}:#{window_index}.#{pane_index} #{@pilot-uuid}' |
while read -r t oid; do
  if [[ -z "$oid" ]]; then
    oid=$(uuidgen | tr '[:upper:]' '[:lower:]' \
      | cut -c1-12)
    tmux set-option -p -t "$t" \
      @pilot-uuid "$oid" 2>/dev/null || true
  fi
done

# Separator for fzf header (fixed width).
COL_SEP=$(printf '─%.0s' $(seq 1 60))

# Collect raw pane data for deck_format.py.
# Output format (tab-separated):
#   target session win_idx win_name pane_idx
#   path agent status cpu mem owner desc type
collect_panes() {
  local ps_data
  ps_data=$(ps -ax -o pid=,ppid=,rss=,%cpu=)
  tmux list-panes -a -F \
    "#{session_name}:#{window_index}.#{pane_index}${SEP}#{session_name}${SEP}#{window_index}${SEP}#{window_name}${SEP}#{pane_index}${SEP}#{pane_current_path}${SEP}#{@pilot-workdir}${SEP}#{pane_pid}${SEP}#{@pilot-agent}${SEP}#{@pilot-status}${SEP}#{@pilot-needs-help}${SEP}#{@pilot-owner}${SEP}#{@pilot-desc}${SEP}#{@pilot-type}${SEP}#{@pilot-uuid}${SEP}#{window_activity}" |
  while IFS= read -r _line; do
    _line="${_line//\\037/$SEP}"
    IFS="$SEP" read -r target session \
      win_idx win_name pane_idx \
      path workdir pane_pid \
      agent status needs_help \
      owner desc ptype self_uuid activity \
      <<< "$_line"
    [[ -n "$workdir" ]] && path="$workdir"
    if [[ -n "$needs_help" ]]; then
      status="waiting"
    fi
    # @pilot-owner stores UUID directly
    local owner_uuid="$owner"
    local mem cpu
    mem=$(pane_tree_mem "$pane_pid" \
      <<< "$ps_data")
    cpu=$(pane_tree_cpu "$pane_pid" \
      <<< "$ps_data")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$target" "$session" "$win_idx" \
      "$win_name" "$pane_idx" "$path" \
      "$agent" "$status" "$cpu" "$mem" \
      "$owner_uuid" "$desc" "$ptype" "" \
      "$self_uuid" "$activity"
  done
}

# Collect panes from a remote tmux via SSH.
# Uses ||| as delimiter (unit separator doesn't
# survive SSH quoting). Converts to tabs for
# parsing. Outputs same format as collect_panes
# with empty CPU/MEM.
collect_remote_panes() {
  local host="$1"
  local D="@@@"
  local output
  output=$(ssh \
    -o ConnectTimeout=2 \
    -o BatchMode=yes \
    "$host" \
    "tmux list-panes -a -F '#{session_name}${D}#{window_index}${D}#{window_name}${D}#{pane_index}${D}#{pane_current_path}${D}#{@pilot-agent}${D}#{@pilot-status}${D}#{@pilot-desc}${D}#{@pilot-type}${D}#{@pilot-owner}${D}#{@pilot-uuid}'" \
    2>/dev/null) || return 0
  # Reformat with awk (preserves empty fields).
  # awk preserves empty fields (unlike bash read).
  echo "$output" | awk -F'@@@' -v h="$host" \
    'NF>0 {
      ses=$1; wi=$2; wn=$3; pi=$4; pa=$5
      ag=$6; st=$7; de=$8; pt=$9; ou=$10; su=$11
      tgt=ses":"wi"."pi
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t\t%s\t%s\t%s\t%s\t%s\t\n", \
        tgt, ses, wi, wn, pi, pa, \
        ag, st, ou, de, pt, h, su
    }'
}

PILOT_DATA=$(mktemp)
trap 'rm -f "$PILOT_DATA"' EXIT

# Build indexed data + display via Python
# formatter. Handles sorting, grouping, dimming,
# column alignment, and emoji width.
build_data() {
  local data_file="${1:-$PILOT_DATA}"
  {
    collect_panes
    # Remote panes (sequential)
    local hosts
    hosts=$(cached_hosts 2>/dev/null) || hosts=""
    for h in $hosts; do
      collect_remote_panes "$h" || true
    done
  } | python3 \
    "$CURRENT_DIR/deck_format.py" \
    --data-file "$data_file" \
    --col-pane 26 --col-type 14
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
# Data file format: target<TAB>path<TAB>host
# Host is empty for local panes.
lookup() {
  local idx="$1" field="$2"
  if [[ ! "$idx" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  local line
  line=$(sed -n "${idx}p" "$PILOT_DATA")
  local target path host
  IFS=$'\t' read -r target path host <<< "$line"
  case "$field" in
    target) printf '%s' "$target" ;;
    path)   printf '%s' "$path" ;;
    host)   printf '%s' "$host" ;;
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
      --header "Enter=attach  Ctrl-r=refresh
Alt-d=diff  Alt-s=commit  Alt-x=kill  Alt-l=log
Alt-p=pause  Alt-r=resume  Alt-n=new
Alt-e=desc  Alt-y=approve  Alt-t=type  Alt-u=uuid
$COL_SEP" \
      --header-lines=1 \
      --preview "$CURRENT_DIR/_preview.sh {1} $PILOT_DATA" \
      --preview-window=right:60%:follow:~10 \
      --bind "ctrl-e:preview-down" \
      --bind "ctrl-y:preview-up" \
      --bind "ctrl-d:preview-half-page-down" \
      --bind "ctrl-u:preview-half-page-up" \
      --bind "ctrl-w:change-preview-window(wrap|nowrap)" \
      --bind "ctrl-r:refresh-preview" \
      --expect "enter,alt-d,alt-s,alt-x,alt-p,alt-r,alt-n,alt-e,alt-y,alt-l,alt-t,alt-u" \
      "${fzf_start_bind[@]}" \
    <<< "$display") || break  # esc / ctrl-c → exit

  # Parse: first line = key pressed, second line = selected
  key=$(head -1 <<< "$result")
  selection=$(tail -1 <<< "$result")
  idx=${selection%%	*}

  case "$key" in
    enter)
      target=$(lookup "$idx" target) || break
      host=$(lookup "$idx" host) || true
      if [[ -n "$host" ]]; then
        # Remote: open SSH attach in new window
        session="${target%%:*}"
        win_name="${session}@${host}"
        # Option C: exec into SSH attach.
        # Replaces the deck process — the popup
        # becomes the remote session. Detaching
        # (Ctrl+B d or 'd' in remote) closes the
        # popup and returns to where you were.
        exec ssh "$host" -t \
          "tmux attach -t $session"
      else
        tmux switch-client -t "$target"
      fi
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
    alt-t)
      target=$(lookup "$idx" target) || continue
      printf '\n  Type: [s]hell  [a]gent  [d]aemon: '
      read -rn1 choice
      case "$choice" in
        s) tmux set-option -p -t "$target" \
             @pilot-type shell ;;
        a) tmux set-option -p -t "$target" \
             @pilot-type agent ;;
        d) tmux set-option -p -t "$target" \
             @pilot-type daemon ;;
      esac
      display=$(build_data)
      ;;
    alt-u)
      target=$(lookup "$idx" target) || continue
      uuid=$(tmux display-message -t "$target" \
        -p '#{@pilot-uuid}' 2>/dev/null) || uuid=""
      if [[ -n "$uuid" ]]; then
        printf '%s' "$uuid" | pbcopy 2>/dev/null \
          || printf '%s' "$uuid" \
            | xclip -sel clip 2>/dev/null \
          || printf '%s' "$uuid" \
            | xsel --clipboard 2>/dev/null \
          || true
        printf '\n  Copied: %s\n' "$uuid"
        sleep 0.5
      fi
      ;;
    *)
      break
      ;;
  esac
done
