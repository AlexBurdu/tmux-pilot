#!/usr/bin/env bash
# Headless agent spawner — creates a new agent tmux session.
# Non-interactive counterpart to new-agent.sh.
#
# Usage:
#   spawn.sh --agent <name> --prompt <text> --dir <path> [--session <name>]
#
# Outputs the session name to stdout on success.
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/_agents.sh"

agent="" prompt="" dir="" session_override=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)  agent="$2"; shift 2 ;;
    --prompt) prompt="$2"; shift 2 ;;
    --dir)    dir="$2"; shift 2 ;;
    --session) session_override="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$agent" ]]; then
  echo "error: --agent is required" >&2; exit 1
fi
if [[ -z "$prompt" ]]; then
  echo "error: --prompt is required" >&2; exit 1
fi
if [[ -z "$dir" ]]; then
  echo "error: --dir is required" >&2; exit 1
fi

# Validate agent name against known list (before any system calls)
valid=false
for name in $KNOWN_AGENTS; do
  [[ "$name" == "$agent" ]] && valid=true
done
if ! $valid; then
  echo "error: unknown agent '$agent' (known: $KNOWN_AGENTS)" >&2; exit 1
fi

# Validate agent is installed
if ! command -v "$agent" &>/dev/null; then
  echo "error: agent '$agent' is not installed" >&2; exit 1
fi

# Validate/create directory
if [[ ! -d "$dir" ]]; then
  mkdir -p "$dir"
fi

# Build agent command
cmd_args=()
agent_build_cmd "$agent" "$prompt"

# Generate session name (same algorithm as new-agent.sh)
if [[ -n "$session_override" ]]; then
  session_name=$(tr -cd '[:alnum:]_-' <<< "$session_override")
  session_name="${session_name:0:17}"
else
  prompt_lower=$(tr '[:upper:]' '[:lower:]' <<< "$prompt")

  action=$(grep -oE '\b(fix|review|implement|add|update|refactor|remove|delete|debug|test|create|build|migrate|upgrade|optimize|document|improve|rewrite|move|rename|replace|clean|setup|configure)\b' <<< "$prompt_lower" | head -1 || true)
  num=$(grep -oE '[0-9]+' <<< "$prompt" | tail -1 || true)

  if [[ -n "$action" && -n "$num" ]]; then
    suggestion="${agent}-${action}-${num}"
  elif [[ -n "$action" ]]; then
    words=$(sed -E 's|https?://[^ ]*||g' <<< "$prompt_lower" | \
      tr -cs '[:alnum:]' ' ' | tr -s ' ' | \
      grep -oE '\b[a-z]{2,}\b' | grep -v "^${action}$" | head -2 | tr '\n' '-' | sed 's/-$//' || true)
    suggestion="${agent}-${action}-${words}"
  elif [[ -n "$num" ]]; then
    suggestion="${agent}-${num}"
  else
    suggestion="${agent}-$(sed -E 's|https?://[^ ]*||g' <<< "$prompt_lower" | \
      awk '{for(i=1;i<=3&&i<=NF;i++) printf "%s-",$i}' | sed 's/-$//')"
  fi

  session_name=$(tr -cd '[:alnum:]_-' <<< "$suggestion")
  session_name="${session_name:0:17}"
fi

if [[ -z "$session_name" ]]; then
  echo "error: could not generate session name" >&2; exit 1
fi

# Resolve session name collisions
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

printf '%s' "$session_name"
