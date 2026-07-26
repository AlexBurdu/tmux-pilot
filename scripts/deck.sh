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
    oid=$(uuidgen | tr '[:upper:]' '[:lower:]')
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
    # @pilot-owner stores UUID. Legacy panes may
    # still have pane IDs (%NNN) — resolve those.
    local owner_uuid="$owner"
    if [[ "$owner" == %* ]]; then
      owner_uuid=$(command tmux display-message \
        -t "$owner" -p '#{@pilot-uuid}' \
        2>/dev/null) || owner_uuid="$owner"
    fi
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

# Remote pane collection (collect_remote_panes,
# collect_remote_all) lives in _hosts.sh so it is bounded,
# parallel, and unit-testable.

PILOT_DATA=$(mktemp)
# Session cache of the last remote fetch. Lets a local-only
# render (used for the instant initial paint and after
# actions) include remote panes from the previous fetch, so
# they don't flicker out on every relaunch.
PILOT_RCACHE=$(mktemp)
trap 'rm -f "$PILOT_DATA" "$PILOT_RCACHE"' EXIT

# Build indexed data + display via the Python formatter, which
# sorts, groups, dims, and aligns columns. It needs the whole
# pane set before emitting anything, so progressive streaming
# is not possible — instead we choose a remote strategy per
# call ($1):
#   local  local panes + cached remote (instant, no SSH)
#   full   local panes + a fresh bounded parallel remote fetch
# The data file is written to a temp then moved into place so a
# concurrent preview never reads a half-written file.
render_data() {
  local mode="$1"
  local data_file="${2:-$PILOT_DATA}"
  local rcache="${3:-$PILOT_RCACHE}"
  local tmp_data
  tmp_data=$(mktemp)
  {
    collect_panes
    if [[ "$mode" == full ]]; then
      # Fresh fetch: buffer to a temp, emit it, then swap
      # it into the cache atomically (mv) so a concurrent
      # local render never reads a half-written cache.
      local rtmp
      rtmp=$(mktemp)
      collect_remote_all >"$rtmp"
      cat "$rtmp"
      mv -f "$rtmp" "$rcache"
    else
      cat "$rcache" 2>/dev/null || true
    fi
  } | python3 \
    "$CURRENT_DIR/deck_format.py" \
    --data-file "$tmp_data" \
    --col-pane 26 --col-type 14
  mv -f "$tmp_data" "$data_file"
}

# --list mode: full (local + remote) rebuild, used as fzf's
# async reload so the initial popup paints from local data
# immediately while remote panes stream in a moment later.
# Optional 3rd arg is the parent deck's remote cache path so
# this refresh populates it for the parent's later renders.
if [[ "${1:-}" == "--list" ]]; then
  data_file="${2:-}"
  if [[ -z "$data_file" ]]; then
    echo "error: --list requires data file path" >&2
    exit 1
  fi
  render_data full "$data_file" "${3:-}"
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

# Build initial data from local panes only — this paints the
# popup immediately. Remote panes (if any hosts are configured)
# stream in via the async reload wired below, so a slow or
# unreachable SSH host never delays the initial render.
display=$(render_data local)

# Only wire the async remote refresh when hosts are configured;
# otherwise the local render above is already complete and no
# SSH is ever attempted (behaviour identical to a host-less
# setup). The reload runs deck.sh --list in the background; fzf
# keeps showing the local list until the fresh full list (local
# + bounded parallel remote) is ready, then swaps it in.
remote_reload_bind=()
if [[ -n "$(cached_hosts 2>/dev/null)" ]]; then
  reload_cmd="$CURRENT_DIR/deck.sh --list"
  reload_cmd+=" $PILOT_DATA $PILOT_RCACHE"
  remote_reload_bind=(--bind "start:reload($reload_cmd)")
fi

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
      "${remote_reload_bind[@]}" \
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
      # Rebuild data after kill; remote refreshes via reload.
      display=$(render_data local)
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
      # Rebuild data after new agent; remote via reload.
      display=$(render_data local)
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
      display=$(render_data local)
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
