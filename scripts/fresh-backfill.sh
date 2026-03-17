#!/bin/bash
set -e

cd "$(dirname "$0")/.."

echo "Stopping any running daemon..."
pkill -f "beeper-message-sync" 2>/dev/null || true
sleep 1

echo "Clearing logs and state..."
rm -rf ~/Dropbox/Message-Sync/logs/ ~/Dropbox/Message-Sync/state.json
mkdir -p ~/Dropbox/Message-Sync/logs

echo "Running backfill..."
.build/release/beeper-message-sync backfill

echo ""
echo "Starting watch daemon..."
nohup .build/release/beeper-message-sync watch >> ~/Dropbox/Message-Sync/daemon.log 2>&1 &
echo "Daemon started (PID: $!)"
