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

### Agent deck (`prefix+g`)

An fzf-based popup listing all panes across all sessions, sorted by most recent activity, with a live preview of each pane's output. Column widths adapt dynamically to the terminal size.

Columns: **Session:Index** | **Window** | **Age** | **CPU** | **RAM**

CPU and RAM are computed per pane by summing the entire process tree (shell + agent + child processes), so you can spot runaway agents at a glance.

Example:

```
Enter=attach  Ctrl-e/y=scroll  Ctrl-d/u=page
Alt-d=diff  Alt-s=commit  Alt-x=kill
Alt-p=pause  Alt-r=resume  Alt-n=new
────────────────────────────────────────────────────
SESSION            WINDOW    AGE     CPU  MEM
 cld-fix-login:0    🔥18:42  active  31%  2.1G
 gem-refactor-au:0  running  3m ago   5%  826M
 aider-docs:0       editing  8m ago   0%  412M
 cld-issue-42:0     🖐️18:30  15m ago  0%  1.3G
 app:0              zsh      2h ago   0%  106M
```

| Key | Action |
|-----|--------|
| `Enter` | Attach to selected pane |
| `Ctrl+E` / `Ctrl+Y` | Scroll preview (line) |
| `Ctrl+D` / `Ctrl+U` | Scroll preview (half-page) |
| `Alt+D` | Git diff popup for that pane's directory |
| `Alt+S` | Commit + push worktree (WIP commit) |
| `Alt+X` | Kill pane + cleanup worktree (permanent, cannot resume) |
| `Alt+P` | Pause agent (sends `/exit`, keeps pane alive for resume) |
| `Alt+R` | Resume agent (sends `claude --continue`, only works after pause) |
| `Alt+N` | Launch new agent |
| `Alt+E` | Edit session description |
| `Esc` | Close deck |

The preview panel (right side, 60%) shows metadata for the selected pane:

- **PANE** — target, window name, last activity
- **TITLE** — pane title (set by the agent)
- **DESC** — session description (auto-set from prompt, or manually via `@pilot-desc`)
- **WORKDIR** — working directory (full path, wraps if long)
- **CMD** — running command and uptime
- **VCS** — branch, dirty status (+staged ~modified ?untracked), ahead/behind remote (↑↓)

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
set -g @pilot-popup-deck-width "95%"
set -g @pilot-popup-deck-height "90%"
set -g @pilot-popup-vcs-width "95%"
set -g @pilot-popup-vcs-height "90%"
```

## Session descriptions

Each agent session can have a short description (the `@pilot-desc` pane variable) displayed in the deck preview header as **DESC**. When you launch an agent via `prefix+a`, the description is auto-set from the first 80 characters of your prompt.

You can edit descriptions from the deck with `Alt+E`, or set them manually on any pane:

```bash
tmux set-option -p @pilot-desc "migrate auth to Compose"
```

Only panes with a description show the DESC line — others are unaffected.

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

## License

[Apache 2.0](LICENSE)
