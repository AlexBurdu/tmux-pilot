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

printf '\n  Enter a prompt (e.g. fix issue #42)\n\n'
read -rp '  > ' prompt

if [[ -z "$prompt" ]]; then
  exit 0
fi

# Skip picker if only one agent is available
if [[ $(echo "$agents" | wc -l) -eq 1 ]]; then
  agent="$agents"
else
  printf '\n  Agent:\n'
  agent=$(echo "$agents" | fzf --no-info --no-separator --height=4 --reverse)
fi

if [[ -z "$agent" ]]; then
  exit 0
fi

# Build agent command as a safe shell snippet using printf %q to
# escape the prompt, preventing injection from special characters.
escaped_prompt=$(printf '%q' "$prompt")
case "$agent" in
  claude)      cmd="claude $escaped_prompt" ;;
  gemini)      cmd="gemini $escaped_prompt" ;;
  aider)       cmd="aider --message $escaped_prompt" ;;
  codex)       cmd="codex $escaped_prompt" ;;
  goose)       cmd="goose run $escaped_prompt" ;;
  interpreter) cmd="interpreter --message $escaped_prompt" ;;
  *)           cmd="$agent $escaped_prompt" ;;
esac

# Generate session name: agent-action-number or agent-action-words
prompt_lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')

# Extract action verb
action=$(echo "$prompt_lower" | grep -oE '\b(fix|review|implement|add|update|refactor|remove|delete|debug|test|create|build|migrate|upgrade|optimize|document|improve|rewrite|move|rename|replace|clean|setup|configure)\b' | head -1)

# Extract ticket/issue number (last number in prompt)
num=$(echo "$prompt" | grep -oE '[0-9]+' | tail -1)

if [[ -n "$action" && -n "$num" ]]; then
  suggestion="${agent}-${action}-${num}"
elif [[ -n "$action" ]]; then
  # Action + first 2 non-action words
  words=$(echo "$prompt_lower" | sed -E 's|https?://[^ ]*||g' | \
    tr -cs '[:alnum:]' ' ' | tr -s ' ' | \
    grep -oE '\b[a-z]{2,}\b' | grep -v "^${action}$" | head -2 | tr '\n' '-' | sed 's/-$//')
  suggestion="${agent}-${action}-${words}"
elif [[ -n "$num" ]]; then
  suggestion="${agent}-${num}"
else
  # First 3 words
  suggestion="${agent}-$(echo "$prompt_lower" | sed -E 's|https?://[^ ]*||g' | \
    awk '{for(i=1;i<=3&&i<=NF;i++) printf "%s-",$i}' | sed 's/-$//')"
fi
# Sanitize for tmux (no dots, colons, or spaces)
suggestion="${suggestion//[.:]/_}"
suggestion="${suggestion// /-}"

printf '\n'
session_name=$(: | fzf --print-query --query "$suggestion" --prompt "  Session: " \
  --no-info --no-separator --height=2 --reverse || true)

if [[ -z "$session_name" ]]; then
  exit 0
fi

if [[ -n "$TMUX" ]]; then
  tmux new-session -d -s "$session_name" -c "$(pwd)" "$cmd"
  tmux switch-client -t "$session_name"
else
  eval "$cmd"
fi
