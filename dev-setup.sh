#!/usr/bin/env bash
# Symlink this repo into TPM's plugin directory for local development.
# Usage: ./dev-setup.sh
set -euo pipefail

PLUGIN_DIR="$HOME/.tmux/plugins/tmux-pilot"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -L "$PLUGIN_DIR" ]; then
  echo "Symlink already exists: $PLUGIN_DIR → $(readlink "$PLUGIN_DIR")"
  exit 0
fi

if [ -d "$PLUGIN_DIR" ]; then
  echo "Error: $PLUGIN_DIR already exists (not a symlink)."
  echo "Remove it first if you want to use the local dev version:"
  echo "  rm -rf $PLUGIN_DIR"
  exit 1
fi

mkdir -p "$(dirname "$PLUGIN_DIR")"
ln -s "$REPO_DIR" "$PLUGIN_DIR"
echo "Linked: $PLUGIN_DIR → $REPO_DIR"
echo "Reload tmux config to activate: prefix+r"
