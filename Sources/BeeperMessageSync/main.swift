import Foundation

setbuf(stdout, nil)

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "watch"

let envPath = findEnvFile()
let config = Config.load(from: envPath)

guard config.beeperToken != nil else {
    print("Error: BEEPER_TOKEN not set. Add it to .env or set the environment variable.")
    exit(1)
}

let engine = SyncEngine(config: config)
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
    print("Usage: beeper-message-sync [watch|backfill]")
    print("  watch    - Poll for new messages (default). Runs backfill first if no state.")
    print("  backfill - Full historical backfill, then exit.")
    exit(1)
}

// MARK: - Functions

func runBackfill(engine: SyncEngine) async throws {
    var cursor: String? = nil
    var chatIndex = 0
    var failCount = 0

    repeat {
        let response = try await engine.client.listChats(cursor: cursor)
        for chat in response.items {
            chatIndex += 1
            print("  [\(chatIndex)] \(chat.network): \(chat.title)...", terminator: "")
            do {
                let count = try await engine.backfillChat(chat)
                print(" \(count) messages")
            } catch {
                print(" ERROR: \(error.localizedDescription)")
                failCount += 1
            }
        }
        if response.hasMore, let last = response.items.last?.lastActivity {
            cursor = last
        } else {
            break
        }
    } while true

    print("Backfill complete. \(chatIndex) chats, \(failCount) failed.")
}

func runWatch(engine: SyncEngine, interval: Int) async throws {
    while true {
        do {
            try await engine.pollOnce()
        } catch {
            print("Poll error: \(error.localizedDescription)")
        }
        try await Task.sleep(for: .seconds(interval))
    }
}

func findEnvFile() -> String {
    let cwd = FileManager.default.currentDirectoryPath
    let cwdEnv = "\(cwd)/.env"
    if FileManager.default.fileExists(atPath: cwdEnv) {
        return cwdEnv
    }
    let execDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
    return "\(execDir)/.env"
}
