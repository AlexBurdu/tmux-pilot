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

key_new=$(get_opt "@pilot-key-new" "a")
key_deck=$(get_opt "@pilot-key-deck" "g")
key_vcs=$(get_opt "@pilot-key-vcs" "d")

popup_new_w=$(get_opt "@pilot-popup-new-width" "40%")
popup_new_h=$(get_opt "@pilot-popup-new-height" "30%")
popup_deck_w=$(get_opt "@pilot-popup-deck-width" "90%")
popup_deck_h=$(get_opt "@pilot-popup-deck-height" "90%")
popup_vcs_w=$(get_opt "@pilot-popup-vcs-width" "80%")
popup_vcs_h=$(get_opt "@pilot-popup-vcs-height" "80%")

# Keybindings
tmux bind-key "$key_new" display-popup \
  -w "$popup_new_w" -h "$popup_new_h" \
  -d '#{pane_current_path}' -E \
  "$CURRENT_DIR/scripts/new-agent.sh"

tmux bind-key "$key_deck" display-popup \
  -w "$popup_deck_w" -h "$popup_deck_h" -E \
  "$CURRENT_DIR/scripts/deck.sh"

tmux bind-key "$key_vcs" run-shell "\
  dir=\"\$(tmux display-message -p '#{@pilot-workdir}')\";\
  [ -z \"\$dir\" ] && dir=\"\$(tmux display-message -p '#{pane_current_path}')\";\
  tmux display-popup -w '$popup_vcs_w' -h '$popup_vcs_h' -d \"\$dir\" -E \
    '$CURRENT_DIR/scripts/vcs-status.sh'"
