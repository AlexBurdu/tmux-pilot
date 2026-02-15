#!/usr/bin/env bash
# Launch a new AI agent in its own tmux session with
# an initial prompt.
# -e is intentionally omitted — fzf exits non-zero on empty input
set -uo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/_agents.sh"
source "$CURRENT_DIR/_hosts.sh"

# Detect available coding agents from the shared list
agents=""
for name in $KNOWN_AGENTS; do
  command -v "$name" &>/dev/null && agents+="${name}"$'\n'
done
agents="${agents%$'\n'}"

if [[ -z "$agents" ]]; then
  printf '\n  No AI agents found.\n'
  printf '  Install claude, gemini, aider, or codex.\n\n'
  printf '  Press Enter to close.'
  read -r
  exit 1
fi

# Determine total steps dynamically
# Base: prompt + location + directory = 3
# Optional: agent picker (+1), host (+1), mode (+1)
multi_agent=false
[[ "$agents" == *$'\n'* ]] && multi_agent=true
total=3  # prompt + location + directory
$multi_agent && total=$((total + 1))
# location=remote adds host + mode steps (adjusted later)
step=1

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
  "${EDITOR:-vim}" "$tmpfile"
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

# Location picker: local or remote
printf '\n  [%d/%d] Location %s\n' \
  "$step" "$total" "$esc_hint"
location=$(printf 'local\nremote\n' | \
  fzf --no-info --no-separator --height=3 --reverse)

if [[ -z "$location" ]]; then
  exit 0
fi
((step++))

host="" mode=""
if [[ "$location" == "remote" ]]; then
  # Add host + mode steps to total
  total=$((total + 2))

  # Host picker
  printf '\n  [%d/%d] Host %s\n' \
    "$step" "$total" "$esc_hint"
  known=$(all_known_hosts)
  if [[ -n "$known" ]]; then
    fzf_out=$(fzf --print-query --no-info --no-separator \
      --height=8 --reverse --prompt "  > " \
      <<< "$known" || true)
  else
    printf '  Type a hostname:\n'
    fzf_out=$(fzf --print-query --no-info --no-separator \
      --height=2 --reverse --prompt "  > " \
      < /dev/null || true)
  fi
  # --print-query: line 1 = query, line 2 = selected (or empty)
  typed=$(sed -n '1p' <<< "$fzf_out")
  selected=$(sed -n '2p' <<< "$fzf_out")
  host="${selected:-$typed}"

  if [[ -z "$host" ]]; then
    exit 0
  fi
  ((step++))

  # Mode picker
  printf '\n  [%d/%d] Execution mode %s\n' \
    "$step" "$total" "$esc_hint"
  mode=$(printf 'local-ssh\nremote-tmux\n' | \
    fzf --no-info --no-separator --height=3 --reverse)

  if [[ -z "$mode" ]]; then
    exit 0
  fi
  ((step++))
fi

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
if [[ -n "$host" ]]; then
  # Remote: no zoxide, let user type a remote path
  printf '  Remote path on %s:\n' "$host"
  fzf_out=$(fzf --print-query --no-info --no-separator \
    --height=2 --reverse --prompt "  > " \
    --query "\$HOME" \
    < /dev/null || true)
  dir=$(sed -n '1p' <<< "$fzf_out")
else
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
fi

if [[ -z "$dir" || "$dir" == "exit" ]]; then
  exit 0
fi
dir="${dir:-$PWD}"

if [[ -z "$host" && ! -d "$dir" ]]; then
  mkdir -p "$dir"
fi

# Build agent command as an array — no eval needed.
cmd_args=()
agent_build_cmd "$agent" "$prompt"

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
if [[ -n "$host" ]]; then
  printf '  Host:     %s (%s)\n' "$host" "$mode"
fi
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
  if [[ -n "$host" ]]; then
    # Delegate to spawn.sh for remote launches
    result=$("$CURRENT_DIR/spawn.sh" \
      --agent "$agent" --prompt "$prompt" --dir "$dir" \
      --session "$session_name" --host "$host" --mode "$mode")

    if [[ "$mode" == "remote-tmux" ]]; then
      printf '\n  Remote session created: %s\n' "$result"
      printf '  Attach with: ssh %s -t "tmux attach -t %s"\n\n' "$host" "$result"
      printf '  Press Enter to close.'
      read -r
    else
      tmux switch-client -t "$result"
    fi
  else
    # Local launch (unchanged behavior)
    # Resolve session name collisions by appending a numeric suffix
    if tmux has-session -t "=$session_name" 2>/dev/null; then
      n=2
      while (( n <= 99 )); do
        suffix="-${n}"
        candidate="${session_name:0:$((17 - ${#suffix}))}${suffix}"
        if ! tmux has-session -t "=$candidate" 2>/dev/null; then
          session_name="$candidate"
          break
        fi
        ((n++))
      done
    fi

    # Serialize array for tmux's shell string argument
    tmux_cmd=$(printf '%q ' "${cmd_args[@]}")
    tmux new-session -d -s "$session_name" \
      -c "$dir" "$tmux_cmd"
    desc="${prompt:0:80}"
    tmux set-option -p -t "$session_name" @pilot-desc "$desc"
    tmux set-option -p -t "$session_name" @pilot-agent "$agent"
    tmux switch-client -t "$session_name"
  fi
else
  "${cmd_args[@]}"
fi
