#!/bin/bash
#
# Install local Git hooks for geistty.
#
# Usage: ./scripts/install-hooks.sh
#
# This configures Git to use .githooks/ as the hooks directory.
# Hooks are version-controlled so all developers get them automatically.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"

if [ -z "$REPO_ROOT" ]; then
    echo "Error: not inside a Git repository."
    exit 1
fi

HOOKS_DIR="$REPO_ROOT/.githooks"

if [ ! -d "$HOOKS_DIR" ]; then
    echo "Error: $HOOKS_DIR directory not found."
    exit 1
fi

# Point Git at our hooks directory
git config core.hooksPath "$HOOKS_DIR"

# Make hooks executable
chmod +x "$HOOKS_DIR"/*

echo "Git hooks installed."
echo "  Hooks directory: $HOOKS_DIR"
echo "  Active hooks:"
ls -1 "$HOOKS_DIR" | sed 's/^/    /'
