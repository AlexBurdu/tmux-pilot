#!/usr/bin/env bash
# Shared host discovery and cache — SSH config + persistent cache.
# Source this file; do not execute directly.

PILOT_HOST_CACHE="${XDG_CONFIG_HOME:-$HOME/.config}/tmux-pilot/hosts"

# Parse ~/.ssh/config for Host entries, filtering out wildcards.
ssh_config_hosts() {
  local config="$HOME/.ssh/config"
  [[ -f "$config" ]] || return 0
  awk '/^[Hh]ost[[:space:]]/ {
    for (i = 2; i <= NF; i++)
      if ($i !~ /[*?!]/) print $i
  }' "$config"
}

# Read cached hosts (one per line).
cached_hosts() {
  [[ -f "$PILOT_HOST_CACHE" ]] || return 0
  cat "$PILOT_HOST_CACHE"
}

# Merge SSH config + cache, deduplicated and sorted.
all_known_hosts() {
  { ssh_config_hosts; cached_hosts; } | sort -u
}

# Append a host to the cache if not already present.
cache_host() {
  local host="$1"
  [[ -z "$host" ]] && return 0
  mkdir -p "$(dirname "$PILOT_HOST_CACHE")"
  touch "$PILOT_HOST_CACHE"
  if ! grep -qxF "$host" "$PILOT_HOST_CACHE"; then
    printf '%s\n' "$host" >> "$PILOT_HOST_CACHE"
  fi
}

# --- Remote pane collection ---------------------------------------
# Fetching panes from remote hosts must never freeze the deck. Each
# fetch is bounded by an overall wall-clock timeout (covers connect
# AND command run, so a host that accepts the connection but then
# stalls cannot block), and all hosts are fetched in parallel so the
# total wait is one timeout regardless of how many hosts are slow or
# unreachable.

# Overall timeout (seconds) for a single remote fetch. Override via
# env for slow links or tests. Kept short so an unreachable host
# costs at most this long.
PILOT_SSH_TIMEOUT="${PILOT_SSH_TIMEOUT:-3}"

# Collect panes from one remote tmux via SSH.
# Uses <~> as delimiter (unit separator doesn't survive SSH
# quoting); awk converts it to tabs and preserves empty fields
# (unlike bash read). Outputs the same tab format as the deck's
# local collector with empty CPU/MEM. A connect failure, a timeout,
# or any SSH error yields no output and a success return, so callers
# treat an unreachable host as "no panes" rather than an error.
collect_remote_panes() {
  local host="$1"
  local D="<~>"
  local output
  output=$(timeout "$PILOT_SSH_TIMEOUT" ssh \
    -o ConnectTimeout=2 \
    -o BatchMode=yes \
    "$host" \
    "tmux list-panes -a -F '#{session_name}${D}#{window_index}${D}#{window_name}${D}#{pane_index}${D}#{pane_current_path}${D}#{@pilot-agent}${D}#{@pilot-status}${D}#{@pilot-desc}${D}#{@pilot-type}${D}#{@pilot-owner}${D}#{@pilot-uuid}'" \
    2>/dev/null) || return 0
  echo "$output" | awk -F'<~>' -v h="$host" \
    'NF>0 {
      ses=$1; wi=$2; wn=$3; pi=$4; pa=$5
      ag=$6; st=$7; de=$8; pt=$9; ou=$10; su=$11
      tgt=ses":"wi"."pi
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\t\t%s\t%s\t%s\t%s\t%s\t\n", \
        tgt, ses, wi, wn, pi, pa, \
        ag, st, ou, de, pt, h, su
    }'
}

# Fetch panes from every cached host in parallel and print the
# merged result. Each host runs in a background job bounded by
# collect_remote_panes' own timeout, so the whole call returns
# within one timeout no matter how many hosts are unreachable.
# Per-host output is buffered to temp files so parallel jobs never
# interleave lines.
collect_remote_all() {
  local hosts
  hosts=$(cached_hosts 2>/dev/null) || hosts=""
  [[ -z "${hosts//[[:space:]]/}" ]] && return 0
  local h out pid
  local outs=() pids=()
  for h in $hosts; do
    out=$(mktemp)
    outs+=("$out")
    collect_remote_panes "$h" >"$out" 2>/dev/null &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  cat "${outs[@]}" 2>/dev/null || true
  rm -f "${outs[@]}"
}
