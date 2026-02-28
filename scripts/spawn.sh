#!/usr/bin/env bash
# Headless agent spawner — creates a new agent tmux session.
# Non-interactive counterpart to new-agent.sh.
#
# Usage:
#   spawn.sh --agent <name> --prompt <text> --dir <path> [--session <name>]
#            [--host <hostname>] [--mode local-ssh|remote-tmux]
#            [--owner <session-name>] [--tier <string>]
#            [--trust <string>]
#
# Outputs the session name to stdout on success.
set -euo pipefail

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$CURRENT_DIR/_agents.sh"
source "$CURRENT_DIR/_hosts.sh"

agent="" prompt="" dir="" session_override="" host="" mode="" owner=""
tier="" trust=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)   agent="$2"; shift 2 ;;
    --prompt)  prompt="$2"; shift 2 ;;
    --dir)     dir="$2"; shift 2 ;;
    --session) session_override="$2"; shift 2 ;;
    --host)    host="$2"; shift 2 ;;
    --mode)    mode="$2"; shift 2 ;;
    --owner)   owner="$2"; shift 2 ;;
    --tier)    tier="$2"; shift 2 ;;
    --trust)   trust="$2"; shift 2 ;;
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

# Validate host/mode combination
if [[ -n "$host" && -z "$mode" ]]; then
  mode="local-ssh"
fi
if [[ -n "$mode" && -z "$host" ]]; then
  echo "error: --mode requires --host" >&2; exit 1
fi
if [[ -n "$mode" && "$mode" != "local-ssh" && "$mode" != "remote-tmux" ]]; then
  echo "error: --mode must be 'local-ssh' or 'remote-tmux'" >&2; exit 1
fi

# Validate agent name against known list (before any system calls)
valid=false
for name in $KNOWN_AGENTS; do
  [[ "$name" == "$agent" ]] && valid=true
done
if ! $valid; then
  echo "error: unknown agent '$agent' (known: $KNOWN_AGENTS)" >&2; exit 1
fi

# Note: no local "command -v" check — the tmux server may
# be remote, so the binary only needs to exist there.

# Validate/create directory (skip for remote modes — directory is on the remote host)
if [[ -z "$host" ]]; then
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
  fi
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

# Resolve session name collisions (local tmux only)
if [[ "$mode" != "remote-tmux" ]]; then
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
fi

# Serialize array for tmux's shell string argument.
# Prepend common user binary dirs to PATH — tmux
# sessions inherit a minimal server environment that
# may not include ~/.local/bin or ~/bin.
# For other env vars (ANDROID_HOME, JAVA_HOME, etc.)
# use: tmux set-environment -g VAR value
tmux_cmd=$(printf '%q ' "${cmd_args[@]}")
path_prefix='PATH="$HOME/.local/bin:$HOME/bin:$HOME/go/bin:$PATH"'
if [[ "$agent" == "claude" ]]; then
  path_prefix="export CLAUDE_CODE_DISABLE_AUTOCOMPLETE=true; export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false; $path_prefix"
fi
desc="${prompt:0:80}"

if [[ "$mode" == "remote-tmux" ]]; then
  # Fully remote: create a tmux session on the remote host via SSH
  owner_cmd=""
  if [[ -n "$owner" ]]; then
    owner_cmd=" && tmux set-option -p -t '$session_name' @pilot-owner '$owner'"
  fi
  tier_cmd=""
  if [[ -n "$tier" ]]; then
    tier_cmd=" && tmux set-option -p -t '$session_name' @pilot-tier '$tier'"
  fi
  trust_cmd=""
  if [[ -n "$trust" ]]; then
    trust_cmd=" && tmux set-option -p -t '$session_name' @pilot-trust '$trust'"
  fi
  ssh -o ConnectTimeout=10 "$host" \
    "tmux new-session -d -s '$session_name' -c '$dir' '$path_prefix $tmux_cmd' && \
     tmux set-option -p -t '$session_name' @pilot-desc '$desc' && \
     tmux set-option -p -t '$session_name' @pilot-agent '$agent'$owner_cmd$tier_cmd$trust_cmd"
  cache_host "$host"
  printf '%s' "$session_name"
elif [[ "$mode" == "local-ssh" ]]; then
  # Local pane that SSHs into the remote host
  tmux new-session -d -s "$session_name" \
    "ssh -t $host 'cd $dir && $path_prefix $tmux_cmd'"
  tmux set-option -p -t "$session_name" @pilot-desc "$desc"
  tmux set-option -p -t "$session_name" @pilot-agent "$agent"
  tmux set-option -p -t "$session_name" @pilot-host "$host"
  tmux set-option -p -t "$session_name" @pilot-mode "$mode"
  [[ -n "$owner" ]] && tmux set-option -p -t "$session_name" @pilot-owner "$owner"
  [[ -n "$tier" ]] && tmux set-option -p -t "$session_name" @pilot-tier "$tier"
  [[ -n "$trust" ]] && tmux set-option -p -t "$session_name" @pilot-trust "$trust"
  cache_host "$host"
  printf '%s' "$session_name"
else
  # Local (default — unchanged behavior)
  tmux new-session -d -s "$session_name" \
    -c "$dir" \
    "$path_prefix $tmux_cmd"
  tmux set-option -p -t "$session_name" @pilot-desc "$desc"
  tmux set-option -p -t "$session_name" @pilot-agent "$agent"
  [[ -n "$owner" ]] && tmux set-option -p -t "$session_name" @pilot-owner "$owner"
  [[ -n "$tier" ]] && tmux set-option -p -t "$session_name" @pilot-tier "$tier"
  [[ -n "$trust" ]] && tmux set-option -p -t "$session_name" @pilot-trust "$trust"
  printf '%s' "$session_name"
fi
