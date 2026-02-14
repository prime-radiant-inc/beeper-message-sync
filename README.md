# beeper-message-sync

A macOS command-line tool that syncs your [Beeper](https://www.beeper.com) chat history to local JSONL files. Talks to Beeper's local API, downloads attachments, and organizes everything into a directory structure you can back up, search, or feed to LLMs.

## What it does

- Syncs messages from all your Beeper-connected networks (iMessage, WhatsApp, Signal, Slack, etc.)
- Stores messages as compact JSONL files organized by `{network}/{chat}/{date}.jsonl`
- Downloads attachments to date-based subdirectories
- Resolves iMessage phone numbers to contact names via macOS Contacts
- Runs as a launchd daemon for continuous syncing, or one-shot for backfills
- Filters by network, chat title, and date range

## Output format

Each chat directory contains a `metadata.json` and daily `.jsonl` files:

```
logs/
  whatsapp/
    Off-topic/
      metadata.json
      2026-02-12.jsonl
      2026-02-13.jsonl
      2026-02-13/        # attachments
        image.jpg
  signal/
    Alice/
      metadata.json
      2026-02-13.jsonl
```

Messages are one JSON object per line, optimized for compactness:

```json
{"from":{"id":"@user:beeper.local","name":"Alice"},"id":"123","text":"Hello!","ts":"2026-02-13T10:00:00Z"}
{"from":{"id":"@me:beeper.com","name":"Jesse","self":true},"id":"124","replyTo":"123","text":"Hey!","ts":"2026-02-13T10:01:00Z"}
{"attachments":[{"fileName":"photo.jpg","localPath":"2026-02-13/photo.jpg","mimeType":"image/jpeg","type":"img"}],"from":{"id":"@user:beeper.local","name":"Alice"},"id":"125","ts":"2026-02-13T10:02:00Z","type":"IMAGE"}
```

Default values are omitted to keep lines short: `type` is omitted when `TEXT`, `attachments` when empty, `self` when false, `replyTo` when null.

## Requirements

- macOS 14+
- Swift 6.0+
- [Beeper Desktop](https://www.beeper.com/download) running locally (exposes API on `localhost:23373`)

## Setup

1. **Get your Beeper token** from Beeper Desktop's developer tools or API.

2. **Create a `.env` file** in the project root:
   ```
   BEEPER_TOKEN=your-token-here
   ```

3. **Build:**
   ```bash
   swift build -c release
   ```

4. **(Optional) Grant Contacts access** for iMessage phone number resolution:
   ```bash
   .build/release/beeper-message-sync grant-contacts
   ```

## Usage

```
beeper-message-sync [watch|backfill|grant-contacts] [options]
```

### Modes

| Mode | Description |
|------|-------------|
| `watch` | Poll for new messages continuously (default). Runs backfill first if no prior state. |
| `backfill` | Fetch full history for all chats, then exit. |
| `grant-contacts` | Request macOS Contacts permission (run from Terminal). |

### Filtering

```bash
# Only sync iMessage chats
beeper-message-sync backfill --network imessage

# Only sync specific chats (substring match)
beeper-message-sync backfill --chat "Off-topic,vibez"

# Only messages from the last week
beeper-message-sync backfill --since 2026-02-06

# Combine filters
beeper-message-sync backfill --network whatsapp --chat "Off-topic" --since 2026-02-01
```

### Configuration

Environment variables (or `.env` file):

| Variable | Default | Description |
|----------|---------|-------------|
| `BEEPER_TOKEN` | *(required)* | Beeper API token |
| `BEEPER_URL` | `http://localhost:23373` | Beeper API base URL |
| `LOG_DIR` | `~/Dropbox/Beeper-Sync/logs` | Where to write message logs |
| `STATE_FILE` | `~/Dropbox/Beeper-Sync/state.json` | Sync state (tracks last-seen messages) |
| `POLL_INTERVAL` | `5` | Seconds between polls in watch mode |

## Running as a daemon

The included install script builds the binary and sets up a launchd agent:

```bash
# Edit the plist to set your paths first
vim com.primeradiant.beeper-message-sync.plist

# Install and start
scripts/install.sh
```

To stop:
```bash
launchctl bootout gui/$(id -u)/com.primeradiant.beeper-message-sync.plist
```

## Tests

```bash
swift test
```

Note: `SyncEngineTests` hit the real Beeper API and require a running Beeper Desktop instance with a valid token.

## License

MIT
