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
