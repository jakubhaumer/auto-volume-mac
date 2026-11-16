#!/bin/sh
# Builds auto-volume and installs it as a command. Usage: ./install.sh [install-dir]
# Default install dir: ~/.local/bin   (uninstall: rm <dir>/auto-volume)
set -e
cd "$(dirname "$0")"
DEST="${1:-$HOME/.local/bin}"
swift build -c release
mkdir -p "$DEST"
install -m 755 .build/release/auto-volume "$DEST/auto-volume"
echo "Installed: $DEST/auto-volume"
case ":$PATH:" in *":$DEST:"*) ;; *) echo "Note: $DEST is not on your PATH; add it to ~/.zshrc" ;; esac
