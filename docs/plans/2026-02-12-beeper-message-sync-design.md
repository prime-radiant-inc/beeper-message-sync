# Beeper Message Sync Design

## Overview

A Swift command-line daemon that polls the Beeper Desktop API, detects new messages across all accounts/chats, downloads attachments, and appends messages to per-chat JSONL files organized by network, contact, and date. Runs as a launchd daemon for always-on operation.

## Architecture

```
beeper-message-sync (Swift CLI)
  BeeperClient       — HTTP client wrapping the Beeper REST API
  ChatPoller         — Polls /v1/chats, detects activity changes
  MessageFetcher     — Fetches new messages per chat using cursor pagination
  AttachmentFetcher  — Downloads attachments via /v1/assets/download
  LogWriter          — Writes JSONL to the correct file path
  StateStore         — Tracks last-seen message sort keys/cursors per chat
```

## Polling Strategy

1. Every 5 seconds, fetch `/v1/chats` (sorted by last activity)
2. Compare `lastActivity` timestamps against stored state to find chats with new messages
3. For changed chats, fetch `/v1/chats/{chatID}/messages` using stored cursor to get only new messages
4. Download any attachments
5. Append new messages to the appropriate JSONL file
6. Update chat `metadata.json` if chat details changed
7. Update stored cursors/state

Only fetches message details for chats that have changed. Uses cursors to avoid re-fetching old messages.

## File Structure

```
~/beeper-message-sync/logs/
  signal/
    Alice/
      metadata.json
      2026-02-12.jsonl
      2026-02-12/
        attachment-id-1.png
        attachment-id-2.mp4
      2026-02-13.jsonl
      2026-02-13/
        attachment-id-3.jpg
  whatsapp/
    Family Group/
      metadata.json
      2026-02-12.jsonl
  slack/
    Keyboardio - jesse/
      metadata.json
      2026-02-12.jsonl
```

Contact/group names come from the chat `title` field, sanitized for filesystem safety.

## Chat Metadata File

Each chat directory gets a `metadata.json` updated when chat details change:

```json
{
  "chatId": "!NCdz...",
  "accountId": "local-signal_ba_...",
  "network": "signal",
  "title": "Alice",
  "type": "single",
  "participants": [
    {"id": "ba_...", "name": "Alice Smith", "phone": "+1..."},
    {"id": "ba_...", "name": "Jesse Vincent", "isSelf": true}
  ],
  "firstSeen": "2026-02-12T10:00:00Z",
  "lastUpdated": "2026-02-12T15:30:00Z"
}
```

## JSONL Record Format

Each line is a self-contained JSON object:

```json
{
  "id": "1343993",
  "chatId": "!NCdz...",
  "network": "signal",
  "chatTitle": "Alice",
  "senderId": "ba_...",
  "senderName": "Alice Smith",
  "timestamp": "2026-02-12T15:30:00Z",
  "text": "Hey, are you free for lunch?",
  "isSender": false,
  "type": "text",
  "attachments": [
    {
      "id": "mxc://...",
      "type": "img",
      "localPath": "2026-02-12/attachment-id-1.png",
      "mimeType": "image/png"
    }
  ],
  "replyTo": null
}
```

## Attachment Downloads

When a message has attachments, download via `POST /v1/assets/download` and store in a date-named directory alongside the JSONL file. JSONL records reference the relative local path.

## Backfill

On first run (no state file), full backfill: paginate backward through all messages in every chat until exhausted. After backfill completes, switch to incremental 5-second polling.

## State Persistence

`~/beeper-message-sync/state.json` tracks per-chat:
- Last seen message sort key
- Last activity timestamp
- Cursor for forward pagination

Enables clean resume after restarts without re-fetching.

## Configuration

`.env` in the project directory:
- `BEEPER_TOKEN` — bearer token for API auth
- `BEEPER_URL` — defaults to `http://localhost:23373`
- `LOG_DIR` — defaults to `~/beeper-message-sync/logs`
- `POLL_INTERVAL` — defaults to `5` (seconds)

## Deployment

launchd plist at `~/Library/LaunchAgents/com.primeradiant.beeper-message-sync.plist`:
- Starts on login
- Restarts on failure
- Logs stdout/stderr to `~/beeper-message-sync/daemon.log`

## Scope

In scope:
- All Beeper accounts (Signal, WhatsApp, Slack, LinkedIn, Matrix)
- All chats and messages (full firehose)
- Attachment downloading
- Full historical backfill
- Per-chat metadata
- launchd daemon deployment

Not in scope (future):
- macOS notification capture (separate effort, needs research)
- Sending messages (read-only)
- Real-time streaming (Beeper API is REST-only, polling required)
