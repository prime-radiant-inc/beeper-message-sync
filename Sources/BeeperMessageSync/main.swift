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
case "watch":
    if !engine.stateStore.hasState {
        print("No state found. Running initial backfill...")
        try await runBackfill(engine: engine)
    }
    print("Watching for new messages (poll interval: \(config.pollInterval)s)...")
    try await runWatch(engine: engine, interval: config.pollInterval)
default:
    print("Usage: beeper-message-sync [watch|backfill|setup|grant-contacts] [options]")
    print("  watch           - Poll for new messages (default). Runs backfill first if no state.")
    print("  backfill        - Full historical backfill, then exit.")
    print("  setup           - Interactive setup wizard (token, paths, config file).")
    print("  grant-contacts  - Request Contacts access (run interactively from Terminal).")
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
    // Backfill per-account to ensure we get all chats.
    // The global /v1/chats endpoint caps results and drops older chats
    // from accounts with less recent activity.
    // Discover account IDs from both /v1/accounts AND from the chat list
    // (some accounts like iMessage appear in chats but not in /v1/accounts).
    let accountIDs = try await engine.discoverAccountIDs()
    var chatIndex = 0
    var failCount = 0
    var skipCount = 0
    var seenIDs = Set<String>()

    for accountID in accountIDs {
        print("Account: \(accountID)")
        var cursor: String? = nil

        repeat {
            let response = try await engine.client.listChats(
                cursor: cursor, accountIDs: [accountID]
            )
            for chat in response.items {
                guard seenIDs.insert(chat.id).inserted else { continue }
                chatIndex += 1
                let resolved = engine.resolvedTitle(for: chat)
                if !engine.filter.matchesChat(chat, resolvedTitle: resolved) {
                    skipCount += 1
                    continue
                }
                print("  [\(chatIndex)] \(chat.title)...", terminator: "")
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
    }

    var summary = "Backfill complete. \(chatIndex) chats"
    if skipCount > 0 { summary += ", \(skipCount) skipped" }
    if failCount > 0 { summary += ", \(failCount) failed" }
    summary += "."
    print(summary)
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

