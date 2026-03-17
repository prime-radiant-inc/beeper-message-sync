#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "Stopping any running daemon..."
pkill -f "beeper-message-sync" 2>/dev/null || true
sleep 1

echo "Clearing logs and state..."
osascript -e 'tell application "Dropbox" to quit' 2>/dev/null || killall Dropbox 2>/dev/null || true
sleep 2
rm -rf ~/Dropbox/Beeper-Sync/logs/ ~/Dropbox/Beeper-Sync/state.json
mkdir -p ~/Dropbox/Beeper-Sync/logs
open -a Dropbox
sleep 5

echo "Running backfill..."
.build/release/beeper-message-sync backfill

echo ""
echo "Starting watch daemon..."
nohup .build/release/beeper-message-sync watch >> ~/Dropbox/Beeper-Sync/daemon.log 2>&1 &
echo "Daemon started (PID: $!)"
