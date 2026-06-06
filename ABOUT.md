# beeper-message-sync

> A macOS command-line tool that syncs your Beeper chat history to local JSONL files, downloading attachments and organizing messages by network, chat, and date.

**Family:** dev-tools · **Type:** tool · **Lifecycle:** production · **Owner:** obra

## What it does
beeper-message-sync talks to Beeper Desktop's local API and syncs messages from all connected networks (iMessage, WhatsApp, Signal, Slack, etc.) into compact JSONL files organized as `{network}/{chat}/{date}.jsonl`, with attachments in date-based subdirectories. It resolves iMessage phone numbers to contact names via macOS Contacts and can run as a launchd daemon for continuous syncing or one-shot for backfills, with filtering by network, chat title, and date range.

## How it fits
- Depends on: — (no internal prime-radiant-inc dependencies; Package.swift declares no external SwiftPM deps)
- Used by: —
- External: Beeper Desktop local API; macOS Contacts; macOS Keychain (credentials)

## Runtime & data
- Runs: Swift CLI on macOS 14+, one-shot or as a launchd daemon
- Data in: Beeper Desktop local API messages and attachments; macOS Contacts
- Data out: local JSONL message logs, downloaded attachments, per-chat metadata.json

<!-- Maintained by the maintaining-project-map skill. Do not hand-edit; regenerated. -->
