# tmux-pilot

AI agent manager for tmux. Launch, monitor, and orchestrate multiple coding agents from your terminal.

Supports **Claude Code**, **Gemini CLI**, **Aider**, **Codex**, **Goose**, and **Open Interpreter** — auto-detects which agents are installed.

## Features

### New agent launcher (`prefix+a`)

Opens a centered popup that walks you through a guided flow with step indicators and Esc-to-cancel on each step:

1. Type a prompt (e.g. "fix issue #42") — press `Ctrl+E` to open `$EDITOR` for multiline prompts
2. Pick an agent (skipped if only one is installed)
3. Pick a working directory ([zoxide](https://github.com/ajeetdsouza/zoxide)+fzf if available, manual entry otherwise)
4. Review a summary and confirm or edit the auto-generated session name

Each agent gets its own tmux session. The session name is derived from the prompt — action verb + ticket number or keywords (e.g. `claude-fix-42`, `gemini-refactor-auth`). Names are capped at 17 characters to fit the deck's column layout.

### Agent deck (`prefix+g`)

An fzf-based popup listing all panes across all sessions, sorted by most recent activity, with a live preview of each pane's output.

Columns: **Session:Index** | **Window** | **Title** | **Age** | **CPU** | **RAM**

CPU and RAM are computed per pane by summing the entire process tree (shell + agent + child processes), so you can spot runaway agents at a glance.

| Key | Action |
|-----|--------|
| `Enter` | Attach to selected pane |
| `Ctrl+E` / `Ctrl+Y` | Scroll preview (line) |
| `Ctrl+D` / `Ctrl+U` | Scroll preview (half-page) |
| `Alt+D` | Git diff popup for that pane's directory |
| `Alt+S` | Commit + push worktree (WIP commit) |
| `Alt+X` | Kill pane + cleanup worktree |
| `Alt+P` | Pause agent (sends `/exit`) |
| `Alt+R` | Resume agent (sends `claude --continue`) |
| `Alt+N` | Launch new agent |
| `Esc` | Close deck |

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
set -g @pilot-key-deck "g"
set -g @pilot-key-vcs "d"

# Popup sizes
set -g @pilot-popup-new-width "40%"
set -g @pilot-popup-new-height "30%"
set -g @pilot-popup-deck-width "90%"
set -g @pilot-popup-deck-height "90%"
set -g @pilot-popup-vcs-width "80%"
set -g @pilot-popup-vcs-height "80%"
```

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
        "matcher": "Write",
        "hooks": [{
          "type": "command",
          "command": "tmux set-option -p @pilot-workdir \"$(dirname \"$CLAUDE_FILE_PATH\")\" 2>/dev/null; true"
        }]
      },
      {
        "matcher": "Edit",
        "hooks": [{
          "type": "command",
          "command": "tmux set-option -p @pilot-workdir \"$(dirname \"$CLAUDE_FILE_PATH\")\" 2>/dev/null; true"
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
          "command": "jq -r '.tool_input.file_path // empty' | xargs -I{} sh -c 'tmux set-option -p @pilot-workdir \"$(dirname \"{}\")\" 2>/dev/null; true'"
        }]
      }
    ]
  }
}
```

> **Note**: The Gemini CLI hook reads `tool_input` from stdin as JSON. The exact field name may vary — use a debug hook (`cat > /tmp/gemini-hook-debug.json`) to confirm the schema.

## How it compares to Claude Squad

| Feature | tmux-pilot | Claude Squad |
|---------|-----------|--------------|
| Agent support | Claude, Gemini, Aider, Codex, Goose, Open Interpreter | Claude only |
| VCS support | git + Mercurial (via neovim) | git only |
| Architecture | Extends tmux (plugin) | Replaces tmux (standalone TUI) |
| Agent isolation | tmux sessions | tmux sessions |
| Live preview | fzf preview pane | Built-in TUI |
| Pause/resume | Alt+P / Alt+R | c / r |
| New agent | Guided flow: prompt, agent picker, directory picker, smart naming | n |
| Commit | Alt+S (WIP commit + push) | s |

## Scripts

| Script | Purpose |
|--------|---------|
| `pilot.tmux` | Plugin entry point — reads config, sets keybindings |
| `scripts/deck.sh` | Agent deck (fzf popup with preview and actions) |
| `scripts/new-agent.sh` | New agent launcher (prompt, agent picker, session naming) |
| `scripts/vcs-status.sh` | VCS status popup (fugitive / lawrencium) |
| `scripts/commit.sh` | WIP commit + push for a worktree |
| `scripts/kill.sh` | Kill pane + cleanup worktree |

## License

[Apache 2.0](LICENSE)
