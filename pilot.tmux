#!/usr/bin/env bash
# tmux-pilot — AI agent manager for tmux
# https://github.com/AlexBurdu/tmux-pilot
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read user options with defaults
get_opt() {
  local option="$1"
  local default="$2"
  local value
  value=$(tmux show-option -gqv "$option")
  echo "${value:-$default}"
}

# Source user configuration for private overrides
# (e.g. ~/.config/tmux-pilot/config.conf)
tmux source-file -q \
  "$HOME/.config/tmux-pilot/config.conf" \
  2>/dev/null || true

key_new=$(get_opt "@pilot-key-new-agent" "a")
key_deck=$(get_opt "@pilot-key-deck" "e")
key_vcs=$(get_opt "@pilot-key-vcs-status" "d")
key_dash=$(get_opt "@pilot-key-dashboard" "")
dash_cmd=$(get_opt "@pilot-dashboard-cmd" "")

popup_new_w=$(get_opt "@pilot-popup-new-agent-width" "40%")
popup_new_h=$(get_opt "@pilot-popup-new-agent-height" "50%")
popup_deck_w=$(get_opt "@pilot-popup-deck-width" "95%")
popup_deck_h=$(get_opt "@pilot-popup-deck-height" "90%")
popup_vcs_w=$(get_opt "@pilot-popup-vcs-status-width" "95%")
popup_vcs_h=$(get_opt "@pilot-popup-vcs-status-height" "90%")

# Keybindings
tmux bind-key "$key_new" display-popup \
  -w "$popup_new_w" -h "$popup_new_h" \
  -d '#{pane_current_path}' -E \
  "$CURRENT_DIR/scripts/new-agent.sh"

tmux bind-key "$key_deck" run-shell \
  "tmux set-environment -g PILOT_DECK_ORIGIN '#{session_name}:#{window_index}.#{pane_index}'; tmux display-popup -w '$popup_deck_w' -h '$popup_deck_h' -y '##{e|+|:##{popup_centre_y},1}' -E '$CURRENT_DIR/scripts/deck.sh'"

tmux bind-key "$key_vcs" display-popup \
  -w "$popup_vcs_w" -h "$popup_vcs_h" \
  -y '#{e|+|:#{popup_centre_y},1}' \
  -d '#{?@pilot-workdir,#{@pilot-workdir},#{pane_current_path}}' -E \
  "$CURRENT_DIR/scripts/vcs-status.sh"

# User-configured dashboard keybinding
if [ -n "$key_dash" ] && [ -n "$dash_cmd" ]; then
  tmux bind-key "$key_dash" run-shell "$dash_cmd"
fi
