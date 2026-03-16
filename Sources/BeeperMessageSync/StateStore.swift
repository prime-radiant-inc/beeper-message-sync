import Foundation

struct ChatState: Codable {
    var lastSortKey: String?
    var lastActivity: String?
}

class StateStore {
    private let path: String
    private var chats: [String: ChatState]

    var hasState: Bool { !chats.isEmpty }

    init(path: String) {
        self.path = path
        if let data = FileManager.default.contents(atPath: path),
           let decoded = try? JSONDecoder().decode([String: ChatState].self, from: data) {
            self.chats = decoded
        } else {
            self.chats = [:]
        }
    }

    func lastSortKey(for chatID: String) -> String? {
        chats[chatID]?.lastSortKey
    }

    func lastActivity(for chatID: String) -> String? {
        chats[chatID]?.lastActivity
    }

    func update(chatID: String, lastSortKey: String?, lastActivity: String?) {
        var state = chats[chatID] ?? ChatState()
        if let lastSortKey { state.lastSortKey = lastSortKey }
        if let lastActivity { state.lastActivity = lastActivity }
        chats[chatID] = state
    }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(chats)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Use FileManager.createFile instead of Data.write(to:) to avoid
        // NSFileCoordinator, which deadlocks with Dropbox's File Provider
        FileManager.default.createFile(atPath: path, contents: data)
    }
}
