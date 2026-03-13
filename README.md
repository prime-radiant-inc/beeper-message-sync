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
- [Beeper Desktop](https://www.beeper.com/download) running locally with the API enabled

## Setup

### Install

```bash
brew install prime-radiant-inc/tap/beeper-message-sync
```

### Configure

The setup wizard checks that Beeper Desktop is running, walks you through
creating an API token, and saves everything to the Keychain and a config file:

```bash
beeper-message-sync setup
```

This will:
1. Verify Beeper Desktop is running with the API enabled
2. Guide you through creating a token in **Settings → Developers**
3. Validate the token works
4. Save the token to the macOS Keychain
5. Write config to `~/.config/beeper-message-sync/config.json`

### Start syncing

```bash
brew services start beeper-message-sync
```

### (Optional) Grant Contacts access

For iMessage phone number → contact name resolution:

```bash
beeper-message-sync grant-contacts
```

## Usage

```
beeper-message-sync [watch|backfill|setup|grant-contacts] [options]
```

### Modes

| Mode | Description |
|------|-------------|
| `watch` | Poll for new messages continuously (default). Runs backfill first if no prior state. |
| `backfill` | Fetch full history for all chats, then exit. |
| `setup` | Interactive setup wizard (token, paths, config file). |
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

Configuration is stored in `~/.config/beeper-message-sync/config.json` (created by `setup`).
The API token is stored in the macOS Keychain. Environment variables override both:

| Variable | Default | Description |
|----------|---------|-------------|
| `BEEPER_TOKEN` | *(Keychain)* | Beeper API token |
| `BEEPER_URL` | `http://localhost:23373` | Beeper API base URL |
| `LOG_DIR` | `~/Dropbox/Beeper-Sync/logs` | Where to write message logs |
| `STATE_FILE` | `~/Dropbox/Beeper-Sync/state.json` | Sync state (tracks last-seen messages) |
| `POLL_INTERVAL` | `5` | Seconds between polls in watch mode |

## Running as a daemon

```bash
brew services start beeper-message-sync
```

To stop:
```bash
brew services stop beeper-message-sync
```

## Tests

```bash
swift test
```

Note: `SyncEngineTests` hit the real Beeper API and require a running Beeper Desktop instance with a valid token.

## License

MIT
