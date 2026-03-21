import Contacts
import Foundation

setbuf(stdout, nil)

let (mode, filter) = parseArgs()

// Handle modes that don't need a Beeper connection
if mode == "grant-contacts" {
    try await grantContacts()
    exit(0)
}

if mode == "setup" {
    SetupCommand.run()
    exit(0)
}

let config = Config.load()

guard config.beeperToken != nil else {
    print("Error: BEEPER_TOKEN not set. Run `beeper-message-sync setup` to configure.")
    exit(1)
}

let engine = SyncEngine(config: config, filter: filter)
print("beeper-message-sync starting (mode: \(mode))")
print("  Beeper API: \(config.beeperURL)")
print("  Log dir: \(config.logDir)")
print("  State file: \(config.stateFile)")

switch mode {
case "backfill":
    try await runBackfill(engine: engine)
case "backfill-imessage":
    try runImessageBackfill(engine: engine)
case "watch":
    try acquirePidLock(pidFile: NSHomeDirectory() + "/.config/beeper-message-sync/daemon.pid")
    if !engine.stateStore.hasState {
        print("No state found. Running initial backfill...")
        try await runBackfill(engine: engine)
    }
    print("Watching for new messages (poll interval: \(config.pollInterval)s)...")
    try await runWatch(engine: engine, interval: config.pollInterval)
default:
    print("Usage: beeper-message-sync [watch|backfill|setup|grant-contacts] [options]")
    print("  watch              - Poll for new messages (default). Runs backfill first if no state.")
    print("  backfill           - Full historical backfill from Beeper API, then exit.")
    print("  backfill-imessage  - Backfill iMessage history from local Messages database.")
    print("  setup              - Interactive setup wizard (token, paths, config file).")
    print("  grant-contacts     - Request Contacts access (run interactively from Terminal).")
    print("")
    print("Options:")
    print("  --network <names>  Comma-separated networks (e.g. \"imessage,signal\")")
    print("  --chat <titles>    Comma-separated chat titles (substring match)")
    print("  --since <date>     Only messages after this date (YYYY-MM-DD)")
    print("  --until <date>     Only messages before this date (YYYY-MM-DD)")
    exit(1)
}

// MARK: - Functions

func runBackfill(engine: SyncEngine) async throws {
    var cursor: String? = nil
    var chatIndex = 0
    var failCount = 0
    var skipCount = 0
    var seenIDs = Set<String>()

    repeat {
        let response = try await engine.client.listChats(cursor: cursor)
        for chat in response.items {
            guard seenIDs.insert(chat.id).inserted else { continue }
            chatIndex += 1
            let resolved = engine.resolvedTitle(for: chat)
            if !engine.filter.matchesChat(chat, resolvedTitle: resolved) {
                skipCount += 1
                continue
            }
            print("  [\(chatIndex)] \(chat.network): \(chat.title)...", terminator: "")
            do {
                let count = try await engine.backfillChat(chat)
                print(" \(count) messages")
            } catch {
                print(" ERROR: \(error.localizedDescription)")
                failCount += 1
            }
        }
        if response.hasMore, let nextCursor = response.oldestCursor {
            cursor = nextCursor
        } else {
            break
        }
    } while true

    var summary = "Backfill complete. \(chatIndex) chats"
    if skipCount > 0 { summary += ", \(skipCount) skipped" }
    if failCount > 0 { summary += ", \(failCount) failed" }
    summary += "."
    print(summary)
}

func runImessageBackfill(engine: SyncEngine) throws {
    let reader = ChatDBReader()
    let chats = try reader.listChats()
    let contactResolver = engine.contactResolver

    var chatIndex = 0
    var msgTotal = 0
    var failCount = 0
    let networkDir = "imessage"

    print("Reading from \(reader.dbPath)")
    print("Found \(chats.count) chats in Messages database")

    for chat in chats {
        guard chat.messageCount > 0 else { continue }
        chatIndex += 1

        // Resolve chat title from participants
        let displayName = chat.displayName.flatMap { $0.isEmpty ? nil : $0 }
        let rawTitle = displayName
            ?? chat.participantIDs.first
            ?? chat.chatIdentifier
        let resolvedTitle: String
        if ContactResolver.looksLikePhoneNumber(rawTitle) {
            resolvedTitle = contactResolver.resolve(rawTitle) ?? rawTitle
        } else if rawTitle.contains("@") {
            // Email-based iMessage — try to resolve via contacts
            resolvedTitle = rawTitle
        } else {
            resolvedTitle = rawTitle
        }

        if !engine.filter.matchesChat(networkName: networkDir, title: resolvedTitle) {
            continue
        }

        let chatDir = engine.logWriter.chatDir(
            network: networkDir, chatTitle: resolvedTitle
        )
        try createDirectoryWithPOSIX(atPath: chatDir)

        print("  [\(chatIndex)] \(resolvedTitle)...", terminator: "")

        do {
            let messages = try reader.listMessages(chatRowID: chat.rowID)
            var written = 0
            for msg in messages {
                let date = extractDateFromTimestamp(msg.timestamp)

                var attachmentRecords: [AttachmentRecord] = []
                for att in msg.attachments {
                    let srcPath = att.filename.map { expandTilde($0) }
                    var localPath: String? = nil
                    if let src = srcPath,
                       FileManager.default.fileExists(atPath: src) {
                        let destDir = engine.logWriter.attachmentDir(
                            network: networkDir, chatTitle: resolvedTitle, date: date
                        )
                        let fileName = att.transferName
                            ?? URL(fileURLWithPath: src).lastPathComponent
                        do {
                            let dest = try AttachmentFetcher.copyAttachment(
                                from: src, toDir: destDir, fileName: fileName
                            )
                            let chatDirPath = engine.logWriter.chatDir(
                                network: networkDir, chatTitle: resolvedTitle
                            )
                            localPath = dest.hasPrefix(chatDirPath)
                                ? String(dest.dropFirst(chatDirPath.count + 1))
                                : dest
                        } catch {
                            // Attachment copy failed — record without local path
                        }
                    }
                    attachmentRecords.append(AttachmentRecord(
                        id: nil,
                        type: att.mimeType?.hasPrefix("image") == true ? "img"
                            : att.mimeType?.hasPrefix("video") == true ? "video"
                            : "file",
                        localPath: localPath,
                        mimeType: att.mimeType,
                        fileName: att.transferName
                    ))
                }

                let senderName: String?
                if msg.isFromMe {
                    senderName = nil
                } else if let sid = msg.senderID {
                    senderName = ContactResolver.looksLikePhoneNumber(sid)
                        ? contactResolver.resolve(sid) : nil
                } else {
                    senderName = nil
                }

                let record = MessageRecord(
                    id: msg.guid,
                    ts: msg.timestamp,
                    from: Sender(
                        id: msg.senderID,
                        name: senderName,
                        self: msg.isFromMe
                    ),
                    text: msg.text,
                    type: msg.attachments.isEmpty ? nil : "MEDIA",
                    attachments: attachmentRecords,
                    replyTo: msg.replyToGuid
                )
                try engine.logWriter.write(record: record, toDir: chatDir)
                written += 1
            }
            msgTotal += written
            print(" \(written) messages")
        } catch {
            print(" ERROR: \(error.localizedDescription)")
            failCount += 1
        }
    }

    print("iMessage backfill complete. \(chatIndex) chats, \(msgTotal) messages, \(failCount) failed.")
}

private func extractDateFromTimestamp(_ timestamp: String) -> String {
    if let tIndex = timestamp.firstIndex(of: "T") {
        return String(timestamp[timestamp.startIndex..<tIndex])
    }
    return String(timestamp.prefix(10))
}

private func expandTilde(_ path: String) -> String {
    if path.hasPrefix("~") {
        return NSHomeDirectory() + path.dropFirst()
    }
    return path
}

func runWatch(engine: SyncEngine, interval: Int) async throws {
    var consecutiveErrors = 0
    var lastErrorMessage = ""

    while true {
        do {
            try await engine.pollOnce()
            if consecutiveErrors > 0 {
                if consecutiveErrors > 1 {
                    print("Connection restored (suppressed \(consecutiveErrors - 1) repeated errors)")
                }
                consecutiveErrors = 0
                lastErrorMessage = ""
            }
        } catch {
            let msg = error.localizedDescription
            consecutiveErrors += 1
            if consecutiveErrors == 1 || msg != lastErrorMessage {
                print("Poll error: \(msg)")
                lastErrorMessage = msg
            } else if consecutiveErrors & (consecutiveErrors - 1) == 0 {
                // Log at powers of 2: 2, 4, 8, 16, ...
                print("Poll error (repeated \(consecutiveErrors)x): \(msg)")
            }
        }
        // Exponential backoff on errors: 5s, 10s, 20s, ... up to 5 minutes
        let backoff = consecutiveErrors > 0
            ? min(interval * (1 << min(consecutiveErrors - 1, 6)), 300)
            : interval
        try await Task.sleep(for: .seconds(backoff))
    }
}

func parseArgs() -> (mode: String, filter: SyncFilter) {
    let args = CommandLine.arguments
    var mode = "watch"
    var networks: [String]?
    var chatTitles: [String]?
    var since: Date?
    var until: Date?

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.timeZone = TimeZone(identifier: "UTC")

    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--network":
            i += 1
            guard i < args.count else {
                print("Error: --network requires a value")
                exit(1)
            }
            networks = args[i].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "--chat":
            i += 1
            guard i < args.count else {
                print("Error: --chat requires a value")
                exit(1)
            }
            chatTitles = args[i].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "--since":
            i += 1
            guard i < args.count, let date = dateFormatter.date(from: args[i]) else {
                print("Error: --since requires a date in YYYY-MM-DD format")
                exit(1)
            }
            since = date
        case "--until":
            i += 1
            guard i < args.count, let date = dateFormatter.date(from: args[i]) else {
                print("Error: --until requires a date in YYYY-MM-DD format")
                exit(1)
            }
            until = date
        default:
            if arg.hasPrefix("-") {
                print("Unknown option: \(arg)")
                exit(1)
            }
            mode = arg
        }
        i += 1
    }

    let filter = SyncFilter(
        networks: networks,
        chatTitles: chatTitles,
        since: since,
        until: until
    )
    return (mode, filter)
}

nonisolated(unsafe) var activePidFile: String?

func acquirePidLock(pidFile: String) throws {
    let fm = FileManager.default
    let pid = ProcessInfo.processInfo.processIdentifier

    if let existingData = fm.contents(atPath: pidFile),
       let existingStr = String(data: existingData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       let existingPid = Int32(existingStr) {
        // Check if that process is still running
        if kill(existingPid, 0) == 0 {
            print("Error: another daemon is already running (PID \(existingPid), pidfile: \(pidFile))")
            exit(1)
        }
    }

    try createDirectoryWithPOSIX(atPath: URL(fileURLWithPath: pidFile).deletingLastPathComponent().path)
    try writeDataToPath(Data("\(pid)\n".utf8), path: pidFile)
    activePidFile = pidFile
    atexit { if let path = activePidFile { unlink(path) } }
}

func grantContacts() async throws {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    print("Current Contacts authorization: \(status.rawValue)")

    if status == .authorized {
        print("Contacts access already granted.")
        return
    }

    print("Requesting Contacts access...")
    let store = CNContactStore()
    let granted = try await store.requestAccess(for: .contacts)
    print(granted ? "Contacts access granted." : "Contacts access denied.")
}

