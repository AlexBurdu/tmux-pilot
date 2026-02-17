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
target="${line%%	*}"
path="${line#*	}"

if [[ -z "$target" ]]; then
  echo "no pane at index $idx"
  exit 1
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
pilot_status=$(tmux display-message -t "$target" -p '#{@pilot-status}' 2>/dev/null) || pilot_status=""
pilot_needs_help=$(tmux display-message -t "$target" -p '#{@pilot-needs-help}' 2>/dev/null) || pilot_needs_help=""

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

# Preview header — always exactly 7 lines (padded) to match ~7 in deck.sh
printf '\033[1mPANE:\033[0m    %s  %s  %s\n' "$target" "$window" "$age"
printf '\033[1mTITLE:\033[0m   %s\n' "$title"
host_suffix=""
if [[ -n "$pilot_host" ]]; then
  host_suffix="  [$pilot_host via $pilot_mode]"
fi
if [[ -n "$desc" ]]; then
  printf '\033[1mDESC:\033[0m    %s%s\n' "$desc" "$host_suffix"
elif [[ -n "$pilot_needs_help" ]]; then
  printf '\033[1;33mSTATUS:\033[0m  ⚠ NEEDS HELP: %s\n' "$pilot_needs_help"
elif [[ -n "$pilot_status" ]]; then
  printf '\033[1mSTATUS:\033[0m  %s%s\n' "$pilot_status" "$host_suffix"
elif [[ -n "$pilot_host" ]]; then
  printf '\033[1mHOST:\033[0m    %s (%s)\n' "$pilot_host" "$pilot_mode"
else
  printf '\n'
fi
printf '\033[1mWORKDIR:\033[0m \033[2m%s\033[0m\n' "$display_path"
cmd_line="$pane_cmd"
if [[ -n "$uptime_str" ]]; then
  cmd_line+="  uptime:$uptime_str"
fi
printf '\033[1mCMD:\033[0m     %s\n' "$cmd_line"
if [[ -n "$vcs_info" ]]; then
  printf '\033[1mVCS:\033[0m     %s\n' "$vcs_info"
else
  printf '\n'
fi
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
