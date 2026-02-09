#!/usr/bin/env bash
# Launch a new AI agent in its own tmux session with
# an initial prompt.
# -e is intentionally omitted — fzf exits non-zero on empty input
set -uo pipefail

# Detect available coding agents
agents=""
command -v claude &>/dev/null && agents+="claude"$'\n'
command -v gemini &>/dev/null && agents+="gemini"$'\n'
command -v aider &>/dev/null && agents+="aider"$'\n'
command -v codex &>/dev/null && agents+="codex"$'\n'
command -v goose &>/dev/null && agents+="goose"$'\n'
command -v interpreter &>/dev/null && agents+="interpreter"$'\n'
agents="${agents%$'\n'}"

if [[ -z "$agents" ]]; then
  printf '\n  No AI agents found.\n'
  printf '  Install claude, gemini, aider, or codex.\n\n'
  printf '  Press Enter to close.'
  read -r
  exit 1
fi

# Determine total steps (skip agent picker if only one)
multi_agent=false
[[ "$agents" == *$'\n'* ]] && multi_agent=true
if $multi_agent; then
  total=3; step=1
else
  total=2; step=1
fi

esc_hint="(Esc to cancel)"

printf '\n  [%d/%d] Enter a prompt %s\n' \
  "$step" "$total" "$esc_hint"
printf '  Ctrl+E for editor\n'

# fzf --print-query --expect output:
#   line 1: query text
#   line 2: expected key pressed (or empty)
#   line 3: selected item (empty here, no list)
fzf_out=$(fzf --print-query --prompt "  > " \
  --no-info --no-separator --height=2 --reverse \
  --expect ctrl-e \
  < /dev/null || true)

query=$(sed -n '1p' <<< "$fzf_out")
key=$(sed -n '2p' <<< "$fzf_out")

if [[ "$key" == "ctrl-e" ]]; then
  tmpfile=$(mktemp)
  trap 'rm -f "$tmpfile"' EXIT
  [[ -n "$query" ]] && printf '%s' "$query" > "$tmpfile"
  ${EDITOR:-vim} "$tmpfile"
  prompt=$(<"$tmpfile")
  rm -f "$tmpfile"
  trap - EXIT
else
  prompt="$query"
fi

if [[ -z "$prompt" ]]; then
  exit 0
fi
((step++))

# Skip picker if only one agent is available
if $multi_agent; then
  printf '\n  [%d/%d] Select an agent %s\n' \
    "$step" "$total" "$esc_hint"
  agent=$(fzf --no-info --no-separator --height=4 --reverse <<< "$agents")
  ((step++))
else
  agent="$agents"
fi

if [[ -z "$agent" ]]; then
  exit 0
fi

# Directory picker
printf '\n  [%d/%d] Working directory %s\n' \
  "$step" "$total" "$esc_hint"
if command -v zoxide &>/dev/null; then
  dir=$(zoxide query -l |
    fzf --no-info --no-separator --height=10 \
      --reverse --print-query \
      --query "$PWD" |
    tail -1)
else
  read -rp "  [$PWD]: " dir
  if [[ "$dir" == $'\e'* ]]; then
    exit 0
  fi
fi

if [[ -z "$dir" || "$dir" == "exit" ]]; then
  exit 0
fi
dir="${dir:-$PWD}"

if [[ ! -d "$dir" ]]; then
  mkdir -p "$dir"
fi

# Build agent command as an array — no eval needed.
cmd_args=()
case "$agent" in
  claude)      cmd_args=(claude "$prompt") ;;
  gemini)      cmd_args=(gemini "$prompt") ;;
  aider)       cmd_args=(aider --message "$prompt") ;;
  codex)       cmd_args=(codex "$prompt") ;;
  goose)       cmd_args=(goose run "$prompt") ;;
  interpreter) cmd_args=(interpreter --message "$prompt") ;;
  *)           cmd_args=("$agent" "$prompt") ;;
esac

# Generate session name: agent-action-number or agent-action-words
prompt_lower=$(tr '[:upper:]' '[:lower:]' <<< "$prompt")

# Extract action verb
action=$(grep -oE '\b(fix|review|implement|add|update|refactor|remove|delete|debug|test|create|build|migrate|upgrade|optimize|document|improve|rewrite|move|rename|replace|clean|setup|configure)\b' <<< "$prompt_lower" | head -1)

# Extract ticket/issue number (last number in prompt)
num=$(grep -oE '[0-9]+' <<< "$prompt" | tail -1)

if [[ -n "$action" && -n "$num" ]]; then
  suggestion="${agent}-${action}-${num}"
elif [[ -n "$action" ]]; then
  # Action + first 2 non-action words
  words=$(sed -E 's|https?://[^ ]*||g' <<< "$prompt_lower" | \
    tr -cs '[:alnum:]' ' ' | tr -s ' ' | \
    grep -oE '\b[a-z]{2,}\b' | grep -v "^${action}$" | head -2 | tr '\n' '-' | sed 's/-$//')
  suggestion="${agent}-${action}-${words}"
elif [[ -n "$num" ]]; then
  suggestion="${agent}-${num}"
else
  # First 3 words
  suggestion="${agent}-$(sed -E 's|https?://[^ ]*||g' <<< "$prompt_lower" | \
    awk '{for(i=1;i<=3&&i<=NF;i++) printf "%s-",$i}' | sed 's/-$//')"
fi
# Strict sanitize: only alphanumerics, underscore, hyphen
suggestion=$(tr -cd '[:alnum:]_-' <<< "$suggestion")
# Cap length so session:idx fits the deck column (20 chars)
suggestion="${suggestion:0:17}"

# Summary with editable session name
short_dir="${dir/#$HOME/\~}"
printf '\n  Agent:    %s\n' "$agent"
printf '  Dir:      %s\n' "$short_dir"
printf '  Prompt:   %s\n\n' "$prompt"
printf '  Session name (edit or Enter to confirm, Esc to cancel):\n'
session_name=$(fzf --print-query --query "$suggestion" --prompt "  " \
  --no-info --no-separator --height=2 --reverse < /dev/null || true)

if [[ -z "$session_name" ]]; then
  exit 0
fi

# Sanitize session name with the same strict filter
session_name=$(tr -cd '[:alnum:]_-' <<< "$session_name")
session_name="${session_name:0:17}"

if [[ -z "$session_name" ]]; then
  exit 0
fi

if [[ -n "$TMUX" ]]; then
  # Serialize array for tmux's shell string argument
  tmux_cmd=$(printf '%q ' "${cmd_args[@]}")
  tmux new-session -d -s "$session_name" \
    -c "$dir" "$tmux_cmd"
  tmux switch-client -t "$session_name"
else
  "${cmd_args[@]}"
fi
