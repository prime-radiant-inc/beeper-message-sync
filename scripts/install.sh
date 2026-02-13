#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_NAME="com.primeradiant.beeper-message-sync.plist"
PLIST_SRC="$SCRIPT_DIR/$PLIST_NAME"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "Building release binary..."
cd "$SCRIPT_DIR"
swift build -c release

echo "Creating log directory..."
mkdir -p "$HOME/Dropbox/Beeper-Sync"

echo "Installing launchd plist..."
# Unload if already loaded
launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
cp "$PLIST_SRC" "$PLIST_DEST"
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

echo "Done. Service is running."
echo "  Logs: $HOME/Dropbox/Beeper-Sync/daemon.log"
echo "  Stop: launchctl bootout gui/$(id -u)/$PLIST_NAME"
