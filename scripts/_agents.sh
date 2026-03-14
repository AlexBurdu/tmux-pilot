#!/usr/bin/env bash
# Shared agent configuration — launch commands, pause/resume.
# Source this file; do not execute directly.
CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Single source of truth for supported agent names.
KNOWN_AGENTS="claude gemini aider codex goose interpreter vibe"

# Check if an agent binary is available.
# Searches PATH, npm global bin, nvm, and common
# install locations.
agent_available() {
  local name="$1"
  command -v "$name" &>/dev/null && return 0
  local npm_bin
  npm_bin=$(npm bin -g 2>/dev/null) || npm_bin=""
  [[ -n "$npm_bin" && -x "$npm_bin/$name" ]] \
    && return 0
  for d in \
    "$HOME/.nvm/versions/node"/*/bin \
    /usr/local/bin \
    "$HOME/.local/bin" \
    "$HOME/.cargo/bin"; do
    [[ -x "$d/$name" ]] && return 0
  done
  return 1
}

# List all available agents (known + user-configured).
list_available_agents() {
  local agents=""
  for name in $KNOWN_AGENTS; do
    agent_available "$name" \
      && agents+="${name}"$'\n'
  done
  local extra
  extra="${PILOT_EXTRA_AGENTS:-}"
  if [[ -z "$extra" ]]; then
    extra=$(tmux show-option -gqv \
      @pilot-extra-agents 2>/dev/null) || true
  fi
  for name in $extra; do
    agent_available "$name" \
      && agents+="${name}"$'\n'
  done
  printf '%s' "${agents%$'\n'}" | sort
}

source "$CURRENT_DIR/_keys.sh"

# Build the command array for launching an agent with a prompt.
# Sets the caller's cmd_args array.
#
# Args:
#   $1 - agent name
#   $2 - prompt text
#   $3 - optional extra CLI args (space-separated) appended
#        before the prompt/message flag. Useful for passing
#        agent-specific flags like --subtree-only for aider.
agent_build_cmd() {
  local agent="$1" prompt="$2" extra_args="${3:-}"
  # shellcheck disable=SC2086
  case "$agent" in
    gemini)      cmd_args=(bash -lc 'exec gemini -y "$0"' "$prompt") ;;
    vibe)        cmd_args=(vibe --agent auto-approve "$prompt") ;;
    aider)       cmd_args=(bash -lc "exec aider $extra_args --message \"\$0\"" "$prompt") ;;
    goose)       cmd_args=(goose run "$prompt") ;;
    interpreter) cmd_args=(interpreter --message "$prompt") ;;
    claude)      cmd_args=(env CLAUDE_CODE_DISABLE_AUTOCOMPLETE=true CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude $extra_args "$prompt") ;;
    *)           cmd_args=("$agent" $extra_args "$prompt") ;;
  esac
}

# Send text to a pane via paste-buffer (bypasses popup overlays).
# Control keys still use send-keys since paste-buffer can't send them.
_send_text() {
  send_text "$1" "$2"
}

# Send the appropriate stop command to a pane.
# Pause: send Escape to interrupt the agent without
# killing it. The agent stays alive with full context.
agent_pause() {
  local target="$1" agent="$2"
  tmux send-keys -t "$target" Escape
  tmux set-option -p -t "$target" \
    @pilot-status "paused" 2>/dev/null || true
}

# Resume: send "resume" to the agent. All agents
# understand this as a natural language instruction
# to continue their previous task.
agent_resume() {
  local target="$1" agent="$2"
  tmux set-option -p -t "$target" \
    @pilot-status "working" 2>/dev/null || true
  _send_text "$target" 'resume'
}

# Detect which agent is running in a pane.
# Checks @pilot-agent option first, then falls back to
# scanning the pane's child processes for known agent names.
detect_agent() {
  local target="$1"
  local agent
  agent=$(tmux display-message -t "$target" -p '#{@pilot-agent}' 2>/dev/null)
  if [[ -n "$agent" ]]; then
    printf '%s' "$agent"
    return
  fi
  # Check pane_start_command for agent name
  local start_cmd
  start_cmd=$(tmux display-message -t "$target" \
    -p '#{pane_start_command}' 2>/dev/null) \
    || start_cmd=""
  if [[ -n "$start_cmd" ]]; then
    for name in $KNOWN_AGENTS; do
      if [[ "$start_cmd" == *"$name"* ]]; then
        printf '%s' "$name"
        return
      fi
    done
  fi

  # Fallback: walk the full process tree under the
  # pane PID and match against known agents.
  # Checks both the binary name (comm) and the full
  # command line (args) — catches agents launched
  # via runtime wrappers (node, python3, bash).
  local pane_pid
  pane_pid=$(tmux display-message -t "$target" \
    -p '#{pane_pid}' 2>/dev/null) || return 1
  agent=$(ps -ax -o pid=,ppid=,args= | awk \
    -v root="$pane_pid" \
    -v agents="$KNOWN_AGENTS" '
    {
      ppid[$1]=$2
      # args= includes the full command line
      cmd=""
      for (i=3; i<=NF; i++) cmd=cmd " " $i
      args[$1]=cmd
      # Extract just the binary name
      split($3, parts, "/")
      comm[$1]=parts[length(parts)]
    }
    END {
      pids[root]=1; changed=1
      while (changed) {
        changed=0
        for (p in ppid)
          if (!(p in pids) && ppid[p] in pids) {
            pids[p]=1; changed=1
          }
      }
      n=split(agents, names, " ")
      for (p in pids)
        for (i=1; i<=n; i++) {
          if (comm[p] == names[i]) {
            print names[i]; exit
          }
          # Check full args for agent name
          # (e.g. node /path/to/gemini/cli.js)
          if (index(args[p], names[i]) > 0) {
            print names[i]; exit
          }
        }
    }')
  if [[ -n "$agent" ]]; then
    printf '%s' "$agent"
    return
  fi
  return 1
}
