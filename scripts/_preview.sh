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

# Look up target and path from the data file by line number
line=$(sed -n "${idx}p" "$data_file")
IFS=$'\t' read -r target path host <<< "$line"

if [[ -z "$target" ]]; then
  echo "no pane at index $idx"
  exit 1
fi

# Remote pane: fetch metadata + content via SSH
if [[ -n "$host" ]]; then
  session="${target%%:*}"
  D="@@@"
  # Single SSH: metadata + pane capture
  remote_data=$(ssh \
    -o ConnectTimeout=2 -o BatchMode=yes \
    "$host" "
    tmux display-message -t '$target' -p \
      '#{window_name}${D}#{@pilot-agent}${D}#{@pilot-desc}${D}#{@pilot-status}${D}#{@pilot-tier}${D}#{@pilot-trust}${D}#{@pilot-owner}${D}#{@pilot-owner-session}${D}#{@pilot-issue}${D}#{@pilot-worktree}${D}#{@pilot-repo}${D}#{@pilot-review-target}${D}#{@pilot-review-context}${D}#{pane_current_command}${D}#{pane_current_path}' 2>/dev/null
    echo '${D}CAPTURE${D}'
    tmux capture-pane -t '$target' -p -S -50 \
      2>/dev/null
  " 2>/dev/null) || {
    echo "(could not reach $host)"
    exit 0
  }

  # Split metadata from capture
  meta="${remote_data%%${D}CAPTURE${D}*}"
  capture="${remote_data#*${D}CAPTURE${D}}"

  # Parse metadata
  IFS="$D" read -r r_window r_agent r_desc \
    r_status r_tier r_trust r_owner \
    r_owner_ses r_issue r_worktree r_repo \
    r_review_target r_review_ctx \
    r_cmd r_path \
    <<< "$meta"

  # Display header
  printf '\033[1mTARGET:\033[0m  %s@%s\n' \
    "$target" "$host"
  printf '\033[1mWINDOW:\033[0m  %s\n' \
    "${r_window:-—}"
  printf '\033[1mPATH:\033[0m    %s\n' \
    "${r_path:-—}"
  printf '\033[1mCOMMAND:\033[0m %s\n' \
    "${r_cmd:-—}"
  [[ -n "$r_agent" ]] && \
    printf '\033[1mAGENT:\033[0m   %s\n' "$r_agent"
  [[ -n "$r_desc" ]] && \
    printf '\033[1mDESC:\033[0m    %s\n' "$r_desc"
  [[ -n "$r_status" ]] && \
    printf '\033[1mSTATUS:\033[0m  %s\n' "$r_status"
  [[ -n "$r_tier" ]] && \
    printf '\033[1mTIER:\033[0m    %s\n' "$r_tier"
  [[ -n "$r_trust" ]] && \
    printf '\033[1mTRUST:\033[0m   %s\n' "$r_trust"
  [[ -n "$r_owner_ses" ]] && \
    printf '\033[1mOWNER:\033[0m   %s\n' \
      "$r_owner_ses"
  [[ -n "$r_issue" ]] && \
    printf '\033[1mISSUE:\033[0m   %s\n' "$r_issue"
  [[ -n "$r_worktree" ]] && \
    printf '\033[1mWORKTR:\033[0m  %s\n' \
      "$r_worktree"
  [[ -n "$r_repo" ]] && \
    printf '\033[1mREPO:\033[0m    %s\n' "$r_repo"
  [[ -n "$r_review_target" ]] && \
    printf '\033[1mREVIEW:\033[0m  %s\n' \
      "$r_review_target"
  [[ -n "$r_review_ctx" ]] && \
    printf '\033[1mREV CTX:\033[0m %s\n' \
      "$r_review_ctx"

  printf '─%.0s' {1..40}
  printf '\n'
  printf '%s\n' "$capture"
  exit 0
fi

# Compact path: replace $HOME with ~
display_path="${path/#$HOME/\~}"

# Fetch pane metadata from tmux
title=$(tmux display-message -t "$target" -p '#{pane_title}' 2>/dev/null) || title=""
window=$(tmux display-message -t "$target" -p '#{window_name}' 2>/dev/null) || window=""
activity=$(tmux display-message -t "$target" -p '#{window_activity}' 2>/dev/null) || activity=""
pane_cmd=$(tmux display-message -t "$target" -p '#{pane_current_command}' 2>/dev/null) || pane_cmd=""
pane_pid=$(tmux display-message -t "$target" -p '#{pane_pid}' 2>/dev/null) || pane_pid=""
pane_start=$(tmux display-message -t "$target" -p '#{pane_start_command}' 2>/dev/null) || pane_start=""
desc=$(tmux display-message -t "$target" -p '#{@pilot-desc}' 2>/dev/null) || desc=""
pilot_host=$(tmux display-message -t "$target" -p '#{@pilot-host}' 2>/dev/null) || pilot_host=""
pilot_mode=$(tmux display-message -t "$target" -p '#{@pilot-mode}' 2>/dev/null) || pilot_mode=""
# Resolve owner UUID to "name (uuid)" format
pilot_owner=""
_owner_uuid=$(tmux display-message -t "$target" \
  -p '#{@pilot-owner}' 2>/dev/null) \
  || _owner_uuid=""
if [[ -n "$_owner_uuid" ]]; then
  # Find pane with matching UUID
  _owner_name=$(tmux list-panes -a \
    -F '#{@pilot-uuid} #{session_name}' \
    2>/dev/null \
    | awk -v u="$_owner_uuid" \
      '$1==u {print $2; exit}')
  if [[ -n "$_owner_name" ]]; then
    pilot_owner="${_owner_name} (${_owner_uuid})"
  else
    pilot_owner="$_owner_uuid"
  fi
fi
pilot_status=$(tmux display-message -t "$target" -p '#{@pilot-status}' 2>/dev/null) || pilot_status=""
pilot_needs_help=$(tmux display-message -t "$target" -p '#{@pilot-needs-help}' 2>/dev/null) || pilot_needs_help=""
pilot_tier=$(tmux display-message -t "$target" -p '#{@pilot-tier}' 2>/dev/null) || pilot_tier=""
pilot_trust=$(tmux display-message -t "$target" -p '#{@pilot-trust}' 2>/dev/null) || pilot_trust=""
pilot_review_target=$(tmux display-message -t "$target" -p '#{@pilot-review-target}' 2>/dev/null) || pilot_review_target=""
pilot_review_context=$(tmux display-message -t "$target" -p '#{@pilot-review-context}' 2>/dev/null) || pilot_review_context=""
pilot_issue=$(tmux display-message -t "$target" -p '#{@pilot-issue}' 2>/dev/null) || pilot_issue=""
pilot_worktree=$(tmux display-message -t "$target" -p '#{@pilot-worktree}' 2>/dev/null) || pilot_worktree=""
pilot_repo=$(tmux display-message -t "$target" -p '#{@pilot-repo}' 2>/dev/null) || pilot_repo=""

now=$(date +%s)

# Compute age from activity timestamp
if [[ -n "$activity" ]]; then
  elapsed=$(( now - activity ))
  if [[ $elapsed -lt 60 ]]; then age="active"
  elif [[ $elapsed -lt 3600 ]]; then age="$((elapsed / 60))m ago"
  elif [[ $elapsed -lt 86400 ]]; then age="$((elapsed / 3600))h ago"
  else age="$((elapsed / 86400))d ago"
  fi
else
  age=""
fi

# Compute pane uptime from pane PID creation time
uptime_str=""
if [[ -n "$pane_pid" ]]; then
  if pid_start=$(ps -o lstart= -p "$pane_pid" 2>/dev/null); then
    pid_epoch=$(date -j -f "%a %b %d %T %Y" "$pid_start" +%s 2>/dev/null) || pid_epoch=""
    if [[ -n "$pid_epoch" ]]; then
      up=$(( now - pid_epoch ))
      if [[ $up -lt 60 ]]; then uptime_str="${up}s"
      elif [[ $up -lt 3600 ]]; then uptime_str="$((up / 60))m"
      elif [[ $up -lt 86400 ]]; then uptime_str="$((up / 3600))h$((up % 3600 / 60))m"
      else uptime_str="$((up / 86400))d$((up % 86400 / 3600))h"
      fi
    fi
  fi
fi

# Detect VCS status from the working directory
vcs_info=""
if [[ -n "$path" && -d "$path" ]]; then
  if git -C "$path" rev-parse --is-inside-work-tree &>/dev/null; then
    branch=$(git -C "$path" branch --show-current 2>/dev/null) || branch="detached"
    # Count staged, modified, untracked
    staged=$(git -C "$path" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
    modified=$(git -C "$path" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
    untracked=$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
    status=""
    [[ "$staged" -gt 0 ]] && status+="+$staged "
    [[ "$modified" -gt 0 ]] && status+="~$modified "
    [[ "$untracked" -gt 0 ]] && status+="?$untracked "
    # Ahead/behind remote
    ahead_behind=""
    if upstream=$(git -C "$path" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null); then
      counts=$(git -C "$path" rev-list --left-right --count "$upstream"...HEAD 2>/dev/null) || counts=""
      if [[ -n "$counts" ]]; then
        behind=${counts%%	*}
        ahead=${counts##*	}
        [[ "$ahead" -gt 0 ]] && ahead_behind+="↑$ahead "
        [[ "$behind" -gt 0 ]] && ahead_behind+="↓$behind "
      fi
    fi
    if [[ -n "$status" ]]; then
      vcs_info="git:$branch ($status) $ahead_behind"
    else
      vcs_info="git:$branch (clean) $ahead_behind"
    fi
  elif hg -R "$path" root &>/dev/null; then
    branch=$(hg -R "$path" branch 2>/dev/null) || branch="unknown"
    modified=$(hg -R "$path" status -m 2>/dev/null | wc -l | tr -d ' ')
    added=$(hg -R "$path" status -a 2>/dev/null | wc -l | tr -d ' ')
    untracked=$(hg -R "$path" status -u 2>/dev/null | wc -l | tr -d ' ')
    status=""
    [[ "$added" -gt 0 ]] && status+="+$added "
    [[ "$modified" -gt 0 ]] && status+="~$modified "
    [[ "$untracked" -gt 0 ]] && status+="?$untracked "
    if [[ -n "$status" ]]; then
      vcs_info="hg:$branch ($status)"
    else
      vcs_info="hg:$branch (clean)"
    fi
  fi
fi

# Preview header with all metadata fields.
B=$'\033[1m'
R=$'\033[0m'
DM=$'\033[2m'

# Status icon
# Merged status: semantic (@pilot-status) if set,
# otherwise output-age heuristic from tmux.
stat_str=""
if [[ -n "$pilot_needs_help" ]]; then
  stat_str="! waiting — $pilot_needs_help"
elif [[ -n "$pilot_status" ]]; then
  case "$pilot_status" in
    working)  si="▶" ;; watching) si="▶" ;;
    waiting)  si="!" ;; paused)   si="‖" ;;
    done)     si="✓" ;; stuck)    si="!" ;;
    *)        si="·" ;;
  esac
  stat_str="$si $pilot_status"
elif [[ -n "$age" ]]; then
  case "$age" in
    active)  stat_str="▶ active" ;;
    *)       stat_str="· quiet (${age})" ;;
  esac
fi

# Compute CPU/MEM from process tree
cpu_str="" mem_str=""
if [[ -n "$pane_pid" ]]; then
  ps_data=$(ps -ax -o pid=,ppid=,rss=,%cpu=)
  # Sum RSS of process tree
  mem_kb=$(awk -v root="$pane_pid" '
    {mem[$1]=$3; parent[$1]=$2}
    END {
      pids[root]=1; c=1
      while(c){c=0; for(p in parent)
        if(!(p in pids)&&parent[p] in pids)
          {pids[p]=1;c=1}}
      for(p in pids) t+=mem[p]
      print t+0
    }' <<< "$ps_data")
  if [[ "$mem_kb" -ge 1048576 ]]; then
    mem_str=$(printf "%.1fG" \
      "$(echo "$mem_kb/1048576" | bc -l)")
  elif [[ "$mem_kb" -ge 1024 ]]; then
    mem_str="$((mem_kb / 1024))M"
  else
    mem_str="${mem_kb}K"
  fi
  cpu_str=$(awk -v root="$pane_pid" '
    {cpu[$1]=$4; parent[$1]=$2}
    END {
      pids[root]=1; c=1
      while(c){c=0; for(p in parent)
        if(!(p in pids)&&parent[p] in pids)
          {pids[p]=1;c=1}}
      for(p in pids) t+=cpu[p]
      printf "%d%%", t+0
    }' <<< "$ps_data")
fi

# Display
session="${target%%:*}"
pane_num="${target#*:}"

# Line 1: identity
pane_tmux_id=$(tmux display-message -t "$target" \
  -p '#{pane_id}' 2>/dev/null) || pane_tmux_id=""
pilot_uuid=$(tmux display-message -t "$target" \
  -p '#{@pilot-uuid}' 2>/dev/null) || pilot_uuid=""
printf "${B}SES:${R} %s │ ${B}WIN:${R} %s │ ${B}PANE:${R} %s %s │ ${B}UUID:${R} %s\n" \
  "$session" "$window" "$pane_num" \
  "${pane_tmux_id}" "$pilot_uuid"

# Line 2: cmd + agent
pilot_agent=$(tmux display-message -t "$target" \
  -p '#{@pilot-agent}' 2>/dev/null) || pilot_agent=""
# Use start command's first word if current cmd
# is a runtime (node, python, bash, etc.)
display_cmd="$pane_cmd"
case "$pane_cmd" in
  Python|python*|node|bash|zsh|sh)
    _start=$(tmux display-message -t "$target" \
      -p '#{pane_start_command}' 2>/dev/null) \
      || _start=""
    if [[ -n "$_start" ]]; then
      # Find agent name in start command
      display_cmd=""
      if [[ -n "$pilot_agent" \
          && "$_start" == *"$pilot_agent"* ]]; then
        display_cmd="$pilot_agent"
      else
        for _a in claude gemini aider codex \
            goose interpreter vibe; do
          if [[ "$_start" == *"$_a"* ]]; then
            display_cmd="$_a"
            break
          fi
        done
      fi
      [[ -z "$display_cmd" ]] \
        && display_cmd="$pane_cmd"
    fi
    ;;
esac
if [[ -n "$display_cmd" ]]; then
  # Show runtime in parens if different from cmd
  cmd_str="$display_cmd"
  if [[ "$pane_cmd" != "$display_cmd" ]]; then
    cmd_str+=" (${pane_cmd})"
  fi
  if [[ -n "$pilot_agent" \
      && "$pilot_agent" != "$display_cmd" ]]; then
    printf "${B}CMD:${R}      %s │ ${B}AGENT:${R} %s\n" \
      "$cmd_str" "$pilot_agent"
  else
    printf "${B}CMD:${R}      %s\n" "$cmd_str"
  fi
fi

# Line 3: desc (if set)
[[ -n "$desc" ]] && \
  printf "${B}DESC:${R}     %s\n" "$desc"

# Line 4: status + owner + tier (grouped)
line4=""
[[ -n "$stat_str" ]] && \
  line4+="${B}STATUS:${R} ${stat_str}"
[[ -n "$pilot_owner" ]] && \
  line4+=" │ ${B}OWNER:${R} ${pilot_owner}"
[[ -n "$pilot_tier" ]] && \
  line4+=" │ ${B}TIER:${R} ${pilot_tier}"
[[ -n "$line4" ]] && printf '%s\n' "$line4"

# Line 5: process info (grouped)
line5=""
if [[ -n "$pane_pid" ]]; then
  line5+="${B}PID:${R} ${pane_pid}"
  [[ -n "$cpu_str" ]] && \
    line5+=" │ ${B}CPU:${R} ${cpu_str}"
  [[ -n "$mem_str" ]] && \
    line5+=" │ ${B}MEM:${R} ${mem_str}"
  [[ -n "$uptime_str" ]] && \
    line5+=" │ ${B}UP:${R} ${uptime_str}"
  printf '%s\n' "$line5"
fi

# Line 6: issue + trust (if set)
line6=""
[[ -n "$pilot_issue" ]] && \
  line6+="${B}ISSUE:${R} ${pilot_issue}"
[[ -n "$pilot_trust" ]] && \
  line6+=" │ ${B}TRUST:${R} ${pilot_trust}"
[[ -n "$line6" ]] && printf '%s\n' "$line6"

# Line 7: host + mode (if set)
line7=""
[[ -n "$pilot_host" ]] && \
  line7+="${B}HOST:${R} ${pilot_host}"
[[ -n "$pilot_mode" ]] && \
  line7+=" │ ${B}MODE:${R} ${pilot_mode}"
[[ -n "$line7" ]] && printf '%s\n' "$line7"

# Optional fields (only when set)
[[ -n "$pilot_review_target" ]] && \
  printf "${B}REVIEW:${R}   %s\n" \
    "$pilot_review_target"
[[ -n "$pilot_review_context" ]] && \
  printf "${B}REV CTX:${R}  %s\n" \
    "$pilot_review_context"
[[ -n "$pilot_worktree" ]] && \
  printf "${B}WORKTREE:${R} %s\n" \
    "$pilot_worktree"
[[ -n "$pilot_repo" ]] && \
  printf "${B}REPO:${R}     %s\n" "$pilot_repo"
[[ -n "$display_path" ]] && \
  printf "${B}WORKDIR:${R}  ${DM}%s${R}\n" \
    "$display_path"
[[ -n "$vcs_info" ]] && \
  printf "${B}VCS:${R}      %s\n" "$vcs_info"
preview_w=${FZF_PREVIEW_COLUMNS:-40}
label="┤ PREVIEW ├"
label_len=${#label}
left_len=$(( (preview_w - label_len) / 2 ))
right_len=$(( preview_w - label_len - left_len ))
if [[ $left_len -gt 0 ]]; then printf '─%.0s' $(seq 1 "$left_len"); fi
printf '\033[1m%s\033[0m' "$label"
if [[ $right_len -gt 0 ]]; then printf '─%.0s' $(seq 1 "$right_len"); fi
printf '\n'
# Strip trailing blank lines (empty area below cursor) via $(),
# then keep process alive so fzf's follow can hold scroll at bottom.
printf '%s\n' "$(tmux capture-pane -t "$target" -p -e -S -500)"
exec sleep infinity
