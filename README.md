# tmux-pilot

AI agent manager for tmux. Launch, monitor, and orchestrate multiple coding agents from your terminal.

Supports **Claude Code**, **Gemini CLI**, **Aider**, **Codex**, **Goose**, and **Open Interpreter** — auto-detects which agents are installed.

WARNING: THIS PLUGIN IS VIBE-CODED. USE IT AT YOUR OWN RISK. 

## Features

### New agent launcher (`prefix+a`)

Opens a centered popup that walks you through a guided flow with step indicators and Esc-to-cancel on each step:

1. Type a prompt (e.g. "fix issue #42") — press `Ctrl+E` to open `$EDITOR` for multiline prompts
2. Pick an agent (skipped if only one is installed)
3. Pick a working directory ([zoxide](https://github.com/ajeetdsouza/zoxide)+fzf if available, manual entry otherwise)
4. Review a summary and confirm or edit the auto-generated session name

Each agent gets its own tmux session. The session name is derived from the prompt — action verb + ticket number or keywords (e.g. `claude-fix-42`, `gemini-refactor-auth`). Names are capped at 17 characters to fit the deck's column layout.

### Agent deck (`prefix+e`)

An fzf-based popup listing all panes (local and remote) with type, status, CPU, and memory. Sorted alphabetically by session with owner-based grouping. Repeated session and agent names are dimmed for readability.

Columns: **Pane** | **Type** | **Status** | **CPU** | **MEM**

- **Pane**: session name, with window/pane index for multi-pane sessions
- **Type**: icon + agent name (`🤖 claude`, `⚙ daemon`, `$` shell)
- **Status**: merged from `@pilot-status` (if set by external tools) or output-age heuristic
- **CPU/MEM**: summed across the entire process tree per pane

Orchestrator panes are marked with `★`, peer orchestrators with `★⇄`. Panes owned by an orchestrator are grouped under that orchestrator's section. Remote panes (fetched via SSH) appear in a separate host section.

Example:

```
PANE                  TYPE           ST  CPU   MEM
──────────────────────────────────────────────────
api-server            🤖 claude      ▶   5%  1.2G
frontend              🤖 vibe        ·   0%  236M
shell                  $                 0%   62M

── my-orch (2 agents) ────────────────────────
my-orch           ★   🤖 claude      ▶   1%  800M
my-orch.1              $             ▶   0%   90M
task-42               🤖 gemini      ⧖  45%  512M
task-99               🤖 vibe        !  23%  348M

── server01 ──────────────────────────────────
ci-runner@server01    🤖 gemini      ⧖
worker@server01       🤖 vibe        !
```

| Key | Action |
|-----|--------|
| `Enter` | Attach to pane (SSH for remote) |
| `Ctrl+R` | Refresh preview |
| `Ctrl+E` / `Ctrl+Y` | Scroll preview (line) |
| `Ctrl+D` / `Ctrl+U` | Scroll preview (half-page) |
| `Ctrl+W` | Toggle line wrap in preview |
| `Alt+D` | Git diff popup |
| `Alt+S` | Commit + push worktree |
| `Alt+X` | Kill pane + cleanup worktree |
| `Alt+P` | Pause agent (sends `Escape`) |
| `Alt+R` | Resume agent (sends `resume`) |
| `Alt+N` | Launch new agent |
| `Alt+E` | Edit session description |
| `Alt+Y` | Approve (send Enter to pane) |
| `Alt+T` | Change pane type (shell/agent/daemon) |
| `Alt+U` | Copy pane UUID to clipboard |
| `Alt+L` | View log |
| `Esc` | Close deck |

The preview panel (right side, 60%) shows metadata:

- **SES/WIN/PANE/UUID** — session, window, pane index, pane ID, UUID
- **CMD** — running command with runtime (e.g. `vibe (Python)`), agent name if different
- **DESC** — task description (auto-set from prompt)
- **STATUS** — merged status with owner and tier
- **PID/CPU/MEM/UP** — process info
- **ISSUE/TRUST** — task metadata
- **HOST/MODE** — remote host and execution mode
- **WORKDIR/VCS** — working directory and git status

All fields are shown only when set — empty fields are hidden.

### VCS status (`prefix+d`)

Opens neovim in a popup with:

- **Git repos**: `:Git` (vim-fugitive) — stage, diff, commit, blame
- **Mercurial repos**: `:Hgstatus` (vim-lawrencium)
- **Neither**: shows a message and waits for a keypress

Reads the `@pilot-workdir` pane variable first (set by agent hooks), falling back to `pane_current_path`. This ensures the popup opens in the repo the agent is actually working in, not just where it was launched.

## Requirements

- [tmux](https://github.com/tmux/tmux) >= 3.2 (uses `display-popup`)
- [fzf](https://github.com/junegunn/fzf) (agent deck and agent picker)
- [git](https://git-scm.com/) (worktree cleanup, commit, diff)
- At least one AI coding agent installed:
  [Claude Code](https://docs.anthropic.com/en/docs/claude-code),
  [Gemini CLI](https://github.com/google-gemini/gemini-cli),
  [Aider](https://github.com/paul-gauthier/aider),
  [Codex](https://github.com/openai/codex),
  [Goose](https://github.com/block/goose), or
  [Open Interpreter](https://github.com/OpenInterpreter/open-interpreter)

**Optional:**

- [zoxide](https://github.com/ajeetdsouza/zoxide) — fuzzy directory picker for new agent launcher (falls back to manual entry)

**For VCS status (`prefix+d`):**

- [Neovim](https://neovim.io/) with [vim-fugitive](https://github.com/tpope/vim-fugitive) (git)
- Optional: [vim-lawrencium](https://github.com/ludovicchabant/vim-lawrencium) (Mercurial)

## Installation

### With [TPM](https://github.com/tmux-plugins/tpm)

Add to your `tmux.conf` (before the `run '~/.tmux/plugins/tpm/tpm'` line):

```tmux
set -g @plugin 'AlexBurdu/tmux-pilot'
```

Then press `prefix+I` to install.

### Manual

```bash
git clone https://github.com/AlexBurdu/tmux-pilot ~/.tmux/plugins/tmux-pilot
```

Add to your `tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-pilot/pilot.tmux
```

### Development

Clone the repo anywhere and symlink it into TPM's plugin directory:

```bash
git clone https://github.com/AlexBurdu/tmux-pilot ~/projects/tmux-pilot
cd ~/projects/tmux-pilot
./dev-setup.sh
```

## Configuration

All options are set via tmux options in your `tmux.conf`. Defaults are shown below — you only need to add lines for values you want to change.

```tmux
# Keybindings
set -g @pilot-key-new "a"
set -g @pilot-key-deck "e"
set -g @pilot-key-vcs "d"

# Popup sizes
set -g @pilot-popup-new-width "40%"
set -g @pilot-popup-new-height "30%"
set -g @pilot-popup-deck-width "95%"
set -g @pilot-popup-deck-height "90%"
set -g @pilot-popup-vcs-width "95%"
set -g @pilot-popup-vcs-height "90%"

# Status icons: use BMP symbols instead of emojis
# (for terminals with poor emoji rendering)
set -g @pilot-status-ascii "1"
```

## Session descriptions

Each agent session can have a short description (the `@pilot-desc` pane variable) displayed in the deck preview header as **DESC**. When you launch an agent via `prefix+a`, the description is auto-set from the first 80 characters of your prompt.

You can edit descriptions from the deck with `Alt+E`, or set them manually on any pane:

```bash
tmux set-option -p @pilot-desc "migrate auth to Compose"
```

Only panes with a description show the DESC line — others are unaffected.

### Pane Variables

tmux-pilot uses pane-level variables for metadata.
External tools can set additional variables that
tmux-pilot will display in the deck.

| Variable | Set by | Read by | Values |
|----------|--------|---------|--------|
| `@pilot-uuid` | pilot.tmux (auto) | deck, spawn | Unique pane identifier (12-char hex) |
| `@pilot-agent` | spawn.sh, auto-detect | deck, monitor | claude, gemini, vibe, ... |
| `@pilot-desc` | spawn.sh, agent | deck | Task description |
| `@pilot-workdir` | agent hook | deck, kill.sh | Current dir |
| `@pilot-status` | external tool, deck | deck | Status enum (see below) |
| `@pilot-type` | spawn.sh, Alt+T | deck | shell, agent, daemon |
| `@pilot-owner` | spawn.sh (MCP) | deck, watchdog | UUID of the orchestrator that owns this agent |
| `@pilot-issue` | spawn.sh (MCP) | deck | Issue number |
| `@pilot-tier` | spawn.sh (MCP) | deck | Tier label |
| `@pilot-trust` | spawn.sh (MCP) | deck | Trust level |
| `@pilot-needs-help` | external tool | deck | "" or description |
| `@pilot-review-target` | orchestrator | external tool | Pane target for reviews |
| `@pilot-review-context` | orchestrator | external tool | Task-specific review hints |
| `@pilot-worktree` | spawn.sh (MCP) | deck | Worktree path |
| `@pilot-repo` | spawn.sh (MCP) | deck | Repo root path |

`@pilot-uuid` is assigned automatically to every pane on tmux startup and when new panes are created. It provides a stable identity that survives pane reordering (unlike `%NNN` pane IDs which tmux can reassign).

### Status enum

`@pilot-status` accepts a fixed set of values. The deck renders each as an emoji icon in the list and shows the raw value in the preview panel.

| Value | Icon | Meaning |
|-------|------|---------|
| `working` | `▶` | Agent is actively running |
| `watching` | `▶` | Being monitored |
| `waiting` | `!` | Needs human attention |
| `paused` | `‖` | Suspended (via pause) |
| `done` | `✓` | Task completed |
| `stuck` | `!` | Agent is stuck |
| *(empty)* | `·` | Idle, or derived from output age |

When `@pilot-status` is not set, the deck uses a heuristic based on the pane's last output time: recent output (`< 60s`) shows `▶`, older shows `·`. This ensures meaningful status for panes not managed by external tools.

External tools (monitoring daemons, orchestrators) write `@pilot-status` to communicate agent state. The deck sets it on pause (`paused`) and resume (`working`).

When `@pilot-needs-help` is set, `!` is shown regardless of `@pilot-status`.

```bash
# Examples
tmux set-option -p @pilot-status "working"
tmux set-option -p @pilot-status "waiting"
tmux set-option -p @pilot-needs-help "high-risk: rm -rf /"
```

### Review target

`@pilot-review-target` is an optional pane variable for routing review notifications. When set on an orchestrator pane, monitoring tools can route review-related events directly to this target instead of the orchestrator. This avoids consuming orchestrator context for review relay.

```bash
# Set on the orchestrator pane after spawning a review agent
tmux set-option -p @pilot-review-target "my-reviewer:0.0"
```

### Review context

`@pilot-review-context` is an optional pane variable for attaching task-specific review hints to a worker pane. When monitoring tools route review notifications to a review target, they can read this variable from the source pane and include it in the notification. This makes the review agent stateless — it receives fresh context with each event.

```bash
# Set on the worker pane after spawning
tmux set-option -p -t <worker-pane> @pilot-review-context "verify threshold stays at 10"
```

tmux-pilot does not read these variables itself — they are conventions for external monitoring tools that route events between panes.

## Working directory tracking

AI agents don't change their process's working directory, so tmux's `pane_current_path` stays at the launch directory even when the agent writes files elsewhere. tmux-pilot reads a pane-level variable `@pilot-workdir` to find the actual working directory.

To enable automatic tracking, add a PostToolUse hook to your agent's config. The hook fires after every file write/edit and stores the file's directory in the tmux pane variable.

### Claude Code

Add to `~/.claude/settings.json` (merge with existing hooks):

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [{
          "type": "command",
          "command": "jq -r '.tool_input.file_path // empty' | while IFS= read -r f; do [ -n \"$f\" ] && tmux set-option -p @pilot-workdir \"$(dirname \"$f\")\" 2>/dev/null; done; true"
        }]
      }
    ]
  }
}
```

### Gemini CLI

Add to `~/.gemini/settings.json`:

```json
{
  "hooks": {
    "AfterTool": [
      {
        "matcher": "write_file|edit_file",
        "hooks": [{
          "type": "command",
          "command": "jq -r '.tool_input.file_path // empty' | while IFS= read -r f; do [ -n \"$f\" ] && tmux set-option -p @pilot-workdir \"$(dirname \"$f\")\" 2>/dev/null; done; true"
        }]
      }
    ]
  }
}
```

> **Note**: The Gemini CLI hook reads `tool_input` from stdin as JSON. The exact field name may vary — use a debug hook (`cat > /tmp/gemini-hook-debug.json`) to confirm the schema.

## Scripts

| Script | Purpose |
|--------|---------|
| `pilot.tmux` | Plugin entry point — reads config, sets keybindings |
| `scripts/deck.sh` | Agent deck (fzf popup with preview and actions) |
| `scripts/new-agent.sh` | New agent launcher (prompt, agent picker, session naming) |
| `scripts/vcs-status.sh` | VCS status popup (fugitive / lawrencium) |
| `scripts/commit.sh` | WIP commit + push for a worktree |
| `scripts/kill.sh` | Kill pane + cleanup worktree |
| `scripts/spawn.sh` | Headless agent spawner (non-interactive, used by MCP server) |
| `mcp/server.py` | MCP server exposing agent lifecycle tools |

## MCP Server

The MCP server lets any MCP-capable client (Claude Code, Gemini CLI, etc.) spawn and manage sibling agents programmatically — no interactive tmux popups needed.

This is also useful when developing tmux-pilot itself: an AI agent with the MCP server registered can spawn test sessions, inspect their state with `list_agents`, and clean them up — all without leaving the conversation.

### Install fastmcp

**macOS (Homebrew):**

```bash
brew install fastmcp
```

**Linux (pip):**

```bash
pip install fastmcp
```

Or with [pipx](https://pipx.pypa.io/) to avoid polluting your system Python:

```bash
pipx install fastmcp
```

### Registration

Register the server with your MCP client using the CLI or by editing the config file directly.

Adjust the path below if you installed tmux-pilot elsewhere.

**Claude Code:**

```bash
claude mcp add --scope user tmux-pilot -- \
  python3 ~/.tmux/plugins/tmux-pilot/mcp/server.py
```

Or add to `~/.claude/settings.json`:

```json
{
  "mcpServers": {
    "tmux-pilot": {
      "command": "python3",
      "args": ["~/.tmux/plugins/tmux-pilot/mcp/server.py"]
    }
  }
}
```

**Gemini CLI:**

```bash
gemini mcp add tmux-pilot -- \
  python3 ~/.tmux/plugins/tmux-pilot/mcp/server.py
```

Or add to `~/.gemini/settings.json`:

```json
{
  "mcpServers": {
    "tmux-pilot": {
      "command": "python3",
      "args": ["~/.tmux/plugins/tmux-pilot/mcp/server.py"]
    }
  }
}
```

### Tools

| Tool | Description |
|------|-------------|
| `spawn_agent` | Create a new agent tmux session (agent, prompt, directory, optional session name) |
| `list_agents` | List all running panes with agent, owner, description, directory, age, CPU, memory |
| `pause_agent` | Gracefully pause a running agent (keeps pane alive for resume) |
| `resume_agent` | Resume a previously paused agent |
| `kill_agent` | Kill an agent session and clean up its worktree |
| `capture_pane` | Capture terminal text from a pane (target, optional line count) |
| `send_keys` | Send text or control keys to a pane (uses paste-buffer for text to bypass popups) |
| `monitor_agents` | Monitor all agent panes for permission prompts (risk-classified) and lifecycle events |
| `transfer_ownership` | Update @pilot-owner on all panes matching an old owner value (orchestrator handoff) |
| `run_command_silent` | Run a command silently, return exit code and tail of output (full output saved to log file) |

## License

[Apache 2.0](LICENSE)
