# Beeper Message Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Swift daemon that polls the Beeper Desktop API, logs all messages to per-chat JSONL files with attachment downloads, and runs as a launchd service.

**Architecture:** Swift Package Manager executable using async/await and Foundation's URLSession. Polls Beeper REST API at `localhost:23373`, writes JSONL log files organized by `network/contact/date.jsonl`, persists cursor state to resume across restarts.

**Tech Stack:** Swift 6.2, Swift Package Manager, Foundation (URLSession, JSONEncoder/Decoder, FileManager), XCTest

---

### Task 1: Swift Package Manager Project Scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/BeeperMessageSync/main.swift`
- Create: `Tests/BeeperMessageSyncTests/PlaceholderTests.swift`

**Step 1: Create Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "beeper-message-sync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "beeper-message-sync",
            path: "Sources/BeeperMessageSync"
        ),
        .testTarget(
            name: "BeeperMessageSyncTests",
            dependencies: ["beeper-message-sync"],
            path: "Tests/BeeperMessageSyncTests"
        ),
    ]
)
```

**Step 2: Create minimal main.swift**

```swift
import Foundation

print("beeper-message-sync starting...")
```

**Step 3: Create placeholder test**

```swift
import XCTest

final class PlaceholderTests: XCTestCase {
    func testPackageBuilds() {
        XCTAssertTrue(true)
    }
}
```

**Step 4: Build and test**

Run: `cd /Users/jesse/prime-radiant/beeper-message-sync && swift build`
Expected: Build Succeeded

Run: `swift test`
Expected: Test Suite passed

**Step 5: Commit**

```bash
git add Package.swift Sources/ Tests/
git commit -m "scaffold: Swift Package Manager project"
```

---

### Task 2: Configuration Loading

Load settings from `.env` file and environment variables.

**Files:**
- Create: `Sources/BeeperMessageSync/Config.swift`
- Create: `Tests/BeeperMessageSyncTests/ConfigTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import beeper_message_sync

final class ConfigTests: XCTestCase {
    func testDefaultValues() {
        let config = Config(env: [:])
        XCTAssertEqual(config.beeperURL, "http://localhost:23373")
        XCTAssertEqual(config.pollInterval, 5)
        XCTAssertTrue(config.logDir.hasSuffix("beeper-message-sync/logs"))
    }

    func testLoadFromEnv() {
        let env: [String: String] = [
            "BEEPER_TOKEN": "test-token-123",
            "BEEPER_URL": "http://localhost:9999",
            "LOG_DIR": "/tmp/test-logs",
            "POLL_INTERVAL": "10",
        ]
        let config = Config(env: env)
        XCTAssertEqual(config.beeperToken, "test-token-123")
        XCTAssertEqual(config.beeperURL, "http://localhost:9999")
        XCTAssertEqual(config.logDir, "/tmp/test-logs")
        XCTAssertEqual(config.pollInterval, 10)
    }

    func testLoadFromDotEnvFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let envFile = tmpDir.appendingPathComponent(".env")
        try "BEEPER_TOKEN=from-file\nBEEPER_URL=http://localhost:1111\n"
            .write(to: envFile, atomically: true, encoding: .utf8)

        let config = Config.load(from: envFile.path)
        XCTAssertEqual(config.beeperToken, "from-file")
        XCTAssertEqual(config.beeperURL, "http://localhost:1111")
    }

    func testMissingTokenIsNil() {
        let config = Config(env: [:])
        XCTAssertNil(config.beeperToken)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter ConfigTests`
Expected: FAIL — Config type not found

**Step 3: Implement Config**

```swift
import Foundation

struct Config {
    let beeperToken: String?
    let beeperURL: String
    let logDir: String
    let pollInterval: Int
    let stateFile: String

    init(env: [String: String]) {
        self.beeperToken = env["BEEPER_TOKEN"]
        self.beeperURL = env["BEEPER_URL"] ?? "http://localhost:23373"
        self.logDir = env["LOG_DIR"]
            ?? NSHomeDirectory() + "/beeper-message-sync/logs"
        self.pollInterval = Int(env["POLL_INTERVAL"] ?? "") ?? 5
        self.stateFile = env["STATE_FILE"]
            ?? NSHomeDirectory() + "/beeper-message-sync/state.json"
    }

    static func load(from dotEnvPath: String) -> Config {
        var env: [String: String] = [:]
        if let contents = try? String(contentsOfFile: dotEnvPath, encoding: .utf8) {
            for line in contents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                env[key] = value
            }
        }
        // Environment variables override .env file
        for (key, value) in ProcessInfo.processInfo.environment {
            env[key] = value
        }
        return Config(env: env)
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter ConfigTests`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/Config.swift Tests/BeeperMessageSyncTests/ConfigTests.swift
git commit -m "feat: add Config with .env file loading"
```

---

### Task 3: API Data Models

Define Codable structs matching the Beeper API response schemas.

**Files:**
- Create: `Sources/BeeperMessageSync/Models.swift`
- Create: `Tests/BeeperMessageSyncTests/ModelsTests.swift`

**Step 1: Write the failing test**

Test that we can decode real API response JSON. Use representative samples based on the Beeper API spec.

```swift
import XCTest
@testable import beeper_message_sync

final class ModelsTests: XCTestCase {
    let decoder = JSONDecoder()

    func testDecodeChatList() throws {
        let json = """
        {
            "items": [
                {
                    "id": "!test:beeper.com",
                    "accountID": "local-signal_ba_abc",
                    "network": "Signal",
                    "title": "Alice",
                    "type": "single",
                    "participants": {
                        "items": [
                            {"id": "user1", "fullName": "Alice", "isSelf": false},
                            {"id": "user2", "fullName": "Jesse", "isSelf": true}
                        ],
                        "hasMore": false,
                        "total": 2
                    },
                    "lastActivity": "2026-02-12T15:30:00Z",
                    "unreadCount": 3,
                    "isArchived": false,
                    "isMuted": false,
                    "isPinned": false
                }
            ],
            "hasMore": true
        }
        """.data(using: .utf8)!
        let result = try decoder.decode(ChatListResponse.self, from: json)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].id, "!test:beeper.com")
        XCTAssertEqual(result.items[0].network, "Signal")
        XCTAssertEqual(result.items[0].title, "Alice")
        XCTAssertEqual(result.items[0].participants.items.count, 2)
        XCTAssertTrue(result.hasMore)
    }

    func testDecodeMessageList() throws {
        let json = """
        {
            "items": [
                {
                    "id": "msg1",
                    "chatID": "!test:beeper.com",
                    "accountID": "local-signal_ba_abc",
                    "senderID": "user1",
                    "senderName": "Alice",
                    "timestamp": "2026-02-12T15:30:00Z",
                    "sortKey": "0001725489123456",
                    "type": "text",
                    "text": "Hello!",
                    "isSender": false,
                    "attachments": [],
                    "reactions": []
                }
            ],
            "hasMore": false
        }
        """.data(using: .utf8)!
        let result = try decoder.decode(MessageListResponse.self, from: json)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].id, "msg1")
        XCTAssertEqual(result.items[0].text, "Hello!")
        XCTAssertFalse(result.hasMore)
    }

    func testDecodeMessageWithAttachment() throws {
        let json = """
        {
            "items": [
                {
                    "id": "msg2",
                    "chatID": "!test:beeper.com",
                    "accountID": "local-signal_ba_abc",
                    "senderID": "user1",
                    "senderName": "Alice",
                    "timestamp": "2026-02-12T15:31:00Z",
                    "sortKey": "0001725489123457",
                    "type": "media",
                    "isSender": false,
                    "attachments": [
                        {
                            "id": "mxc://beeper.com/abc123",
                            "type": "img",
                            "mimeType": "image/png",
                            "fileName": "photo.png",
                            "fileSize": 12345
                        }
                    ],
                    "reactions": [
                        {"id": "r1", "reactionKey": "👍", "participantID": "user2"}
                    ]
                }
            ],
            "hasMore": false
        }
        """.data(using: .utf8)!
        let result = try decoder.decode(MessageListResponse.self, from: json)
        let msg = result.items[0]
        XCTAssertEqual(msg.attachments?.count, 1)
        XCTAssertEqual(msg.attachments?[0].id, "mxc://beeper.com/abc123")
        XCTAssertEqual(msg.attachments?[0].mimeType, "image/png")
        XCTAssertEqual(msg.reactions?.count, 1)
        XCTAssertEqual(msg.reactions?[0].reactionKey, "👍")
    }

    func testDecodeAssetDownloadResponse() throws {
        let json = """
        {"srcURL": "file:///Users/jesse/Library/Application%20Support/BeeperTexts/media/photo.png"}
        """.data(using: .utf8)!
        let result = try decoder.decode(AssetDownloadResponse.self, from: json)
        XCTAssertEqual(result.srcURL, "file:///Users/jesse/Library/Application%20Support/BeeperTexts/media/photo.png")
        XCTAssertNil(result.error)
    }
}
```

**Step 2: Run tests to verify they fail**

Run: `swift test --filter ModelsTests`
Expected: FAIL — types not found

**Step 3: Implement Models**

```swift
import Foundation

// MARK: - Chat types

struct ChatListResponse: Codable {
    let items: [Chat]
    let hasMore: Bool
}

struct Chat: Codable {
    let id: String
    let localChatID: String?
    let accountID: String
    let network: String
    let title: String
    let type: String // "single" or "group"
    let participants: Participants
    let lastActivity: String?
    let unreadCount: Int?
    let isArchived: Bool?
    let isMuted: Bool?
    let isPinned: Bool?
    let preview: Message?
}

struct Participants: Codable {
    let items: [User]
    let hasMore: Bool
    let total: Int
}

struct User: Codable {
    let id: String
    let username: String?
    let phoneNumber: String?
    let email: String?
    let fullName: String?
    let imgURL: String?
    let cannotMessage: Bool?
    let isSelf: Bool?
}

// MARK: - Message types

struct MessageListResponse: Codable {
    let items: [Message]
    let hasMore: Bool
}

struct Message: Codable {
    let id: String
    let chatID: String
    let accountID: String
    let senderID: String?
    let senderName: String?
    let timestamp: String
    let sortKey: String?
    let type: String?
    let text: String?
    let isSender: Bool?
    let attachments: [Attachment]?
    let isUnread: Bool?
    let linkedMessageID: String?
    let reactions: [Reaction]?
}

struct Attachment: Codable {
    let id: String?
    let type: String // "unknown", "img", "video", "audio"
    let srcURL: String?
    let mimeType: String?
    let fileName: String?
    let fileSize: Int?
    let isGif: Bool?
    let isSticker: Bool?
    let isVoiceNote: Bool?
    let duration: Double?
}

struct Reaction: Codable {
    let id: String
    let reactionKey: String
    let participantID: String
    let emoji: Bool?
}

// MARK: - Asset download

struct AssetDownloadRequest: Codable {
    let url: String
}

struct AssetDownloadResponse: Codable {
    let srcURL: String?
    let error: String?
}

// MARK: - Account types

struct Account: Codable {
    let accountID: String
    let network: String
    let user: User
}
```

**Step 4: Run tests**

Run: `swift test --filter ModelsTests`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/Models.swift Tests/BeeperMessageSyncTests/ModelsTests.swift
git commit -m "feat: add Codable models for Beeper API"
```

---

### Task 4: BeeperClient — HTTP Client

Wraps URLSession calls to the Beeper API with auth.

**Files:**
- Create: `Sources/BeeperMessageSync/BeeperClient.swift`
- Create: `Tests/BeeperMessageSyncTests/BeeperClientTests.swift`

**Step 1: Write integration tests against the live local API**

These tests hit the real Beeper Desktop API. They will be skipped if Beeper is not running.

```swift
import XCTest
@testable import beeper_message_sync

final class BeeperClientTests: XCTestCase {
    var client: BeeperClient!

    override func setUp() async throws {
        // Load token from project .env
        let config = Config.load(
            from: "/Users/jesse/prime-radiant/beeper-message-sync/.env"
        )
        guard let token = config.beeperToken else {
            throw XCTSkip("No BEEPER_TOKEN in .env")
        }
        client = BeeperClient(baseURL: config.beeperURL, token: token)
    }

    func testListAccounts() async throws {
        let accounts = try await client.listAccounts()
        XCTAssertFalse(accounts.isEmpty, "Should have at least one account")
        // Verify account structure
        let first = accounts[0]
        XCTAssertFalse(first.accountID.isEmpty)
        XCTAssertFalse(first.network.isEmpty)
    }

    func testListChats() async throws {
        let response = try await client.listChats()
        XCTAssertFalse(response.items.isEmpty, "Should have at least one chat")
        let chat = response.items[0]
        XCTAssertFalse(chat.id.isEmpty)
        XCTAssertFalse(chat.title.isEmpty)
    }

    func testListMessages() async throws {
        // Get first chat, then fetch its messages
        let chats = try await client.listChats()
        guard let chat = chats.items.first else {
            throw XCTSkip("No chats available")
        }
        let messages = try await client.listMessages(chatID: chat.id)
        // Chat might be empty, but the call should succeed
        XCTAssertNotNil(messages.items)
    }

    func testListChatsWithPagination() async throws {
        let page1 = try await client.listChats(limit: 2)
        XCTAssertLessThanOrEqual(page1.items.count, 2)
        if page1.hasMore, let cursor = page1.items.last?.lastActivity {
            // Just verify pagination doesn't crash — actual cursor value
            // comes from the API, we test the mechanism works
            let page2 = try await client.listChats(limit: 2, cursor: cursor)
            XCTAssertNotNil(page2)
        }
    }
}
```

**Step 2: Run to verify they fail**

Run: `swift test --filter BeeperClientTests`
Expected: FAIL — BeeperClient not found

**Step 3: Implement BeeperClient**

```swift
import Foundation

struct BeeperClient {
    let baseURL: String
    let token: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: String, token: String) {
        self.baseURL = baseURL
        self.token = token
        self.session = URLSession.shared
        self.decoder = JSONDecoder()
    }

    // MARK: - Accounts

    func listAccounts() async throws -> [Account] {
        return try await get(path: "/v1/accounts")
    }

    // MARK: - Chats

    func listChats(
        limit: Int? = nil,
        cursor: String? = nil,
        direction: String? = nil
    ) async throws -> ChatListResponse {
        var query: [(String, String)] = []
        if let limit { query.append(("limit", String(limit))) }
        if let cursor { query.append(("cursor", cursor)) }
        if let direction { query.append(("direction", direction)) }
        return try await get(path: "/v1/chats", query: query)
    }

    // MARK: - Messages

    func listMessages(
        chatID: String,
        limit: Int? = nil,
        cursor: String? = nil,
        direction: String? = nil
    ) async throws -> MessageListResponse {
        let encodedChatID = chatID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? chatID
        var query: [(String, String)] = []
        if let limit { query.append(("limit", String(limit))) }
        if let cursor { query.append(("cursor", cursor)) }
        if let direction { query.append(("direction", direction)) }
        return try await get(path: "/v1/chats/\(encodedChatID)/messages", query: query)
    }

    // MARK: - Assets

    func downloadAsset(url assetURL: String) async throws -> AssetDownloadResponse {
        return try await post(
            path: "/v1/assets/download",
            body: AssetDownloadRequest(url: assetURL)
        )
    }

    // MARK: - HTTP helpers

    private func get<T: Decodable>(
        path: String,
        query: [(String, String)] = []
    ) async throws -> T {
        var components = URLComponents(string: baseURL + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func post<T: Decodable, B: Encodable>(
        path: String,
        body: B
    ) async throws -> T {
        let url = URL(string: baseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try checkResponse(response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BeeperError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BeeperError.httpError(statusCode: http.statusCode, body: body)
        }
    }
}

enum BeeperError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Beeper API"
        case .httpError(let code, let body):
            return "Beeper API error \(code): \(body)"
        }
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter BeeperClientTests`
Expected: All tests pass (requires Beeper Desktop running)

**Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/BeeperClient.swift Tests/BeeperMessageSyncTests/BeeperClientTests.swift
git commit -m "feat: add BeeperClient HTTP wrapper"
```

---

### Task 5: StateStore — Persistence of Sync Cursors

Tracks per-chat last-seen state so we can resume after restarts.

**Files:**
- Create: `Sources/BeeperMessageSync/StateStore.swift`
- Create: `Tests/BeeperMessageSyncTests/StateStoreTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import beeper_message_sync

final class StateStoreTests: XCTestCase {
    var tmpFile: String!

    override func setUp() {
        tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpFile)
    }

    func testNewStoreIsEmpty() {
        let store = StateStore(path: tmpFile)
        XCTAssertNil(store.lastSortKey(for: "chat1"))
        XCTAssertNil(store.lastActivity(for: "chat1"))
    }

    func testUpdateAndRetrieve() throws {
        let store = StateStore(path: tmpFile)
        store.update(chatID: "chat1", lastSortKey: "sk_123", lastActivity: "2026-02-12T15:00:00Z")
        XCTAssertEqual(store.lastSortKey(for: "chat1"), "sk_123")
        XCTAssertEqual(store.lastActivity(for: "chat1"), "2026-02-12T15:00:00Z")
    }

    func testPersistAndReload() throws {
        let store = StateStore(path: tmpFile)
        store.update(chatID: "chat1", lastSortKey: "sk_456", lastActivity: "2026-02-12T16:00:00Z")
        try store.save()

        let reloaded = StateStore(path: tmpFile)
        XCTAssertEqual(reloaded.lastSortKey(for: "chat1"), "sk_456")
        XCTAssertEqual(reloaded.lastActivity(for: "chat1"), "2026-02-12T16:00:00Z")
    }

    func testMultipleChats() throws {
        let store = StateStore(path: tmpFile)
        store.update(chatID: "chat1", lastSortKey: "sk_1", lastActivity: "2026-02-12T10:00:00Z")
        store.update(chatID: "chat2", lastSortKey: "sk_2", lastActivity: "2026-02-12T11:00:00Z")
        try store.save()

        let reloaded = StateStore(path: tmpFile)
        XCTAssertEqual(reloaded.lastSortKey(for: "chat1"), "sk_1")
        XCTAssertEqual(reloaded.lastSortKey(for: "chat2"), "sk_2")
    }

    func testHasState() {
        let store = StateStore(path: tmpFile)
        XCTAssertFalse(store.hasState)
        store.update(chatID: "chat1", lastSortKey: "sk_1", lastActivity: "2026-02-12T10:00:00Z")
        XCTAssertTrue(store.hasState)
    }
}
```

**Step 2: Run to verify they fail**

Run: `swift test --filter StateStoreTests`
Expected: FAIL — StateStore not found

**Step 3: Implement StateStore**

```swift
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
        try data.write(to: url)
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter StateStoreTests`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/StateStore.swift Tests/BeeperMessageSyncTests/StateStoreTests.swift
git commit -m "feat: add StateStore for cursor persistence"
```

---

### Task 6: LogWriter — JSONL File Writing and Directory Structure

Writes message records to the correct per-chat, per-date JSONL file. Manages the `network/contact/date.jsonl` directory structure.

**Files:**
- Create: `Sources/BeeperMessageSync/LogWriter.swift`
- Create: `Tests/BeeperMessageSyncTests/LogWriterTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import beeper_message_sync

final class LogWriterTests: XCTestCase {
    var tmpDir: String!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    func testWriteCreatesDirectoryStructure() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let record = MessageRecord(
            id: "msg1",
            chatId: "!test:beeper.com",
            network: "Signal",
            chatTitle: "Alice",
            senderId: "user1",
            senderName: "Alice Smith",
            timestamp: "2026-02-12T15:30:00Z",
            text: "Hello!",
            isSender: false,
            type: "text",
            attachments: [],
            replyTo: nil
        )
        try writer.write(record: record)

        let expectedPath = "\(tmpDir!)/signal/Alice/2026-02-12.jsonl"
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPath))

        let content = try String(contentsOfFile: expectedPath, encoding: .utf8)
        XCTAssertTrue(content.contains("\"id\":\"msg1\""))
        XCTAssertTrue(content.hasSuffix("\n"))
    }

    func testMultipleMessagesAppend() throws {
        let writer = LogWriter(baseDir: tmpDir)
        for i in 1...3 {
            let record = MessageRecord(
                id: "msg\(i)",
                chatId: "!test:beeper.com",
                network: "Signal",
                chatTitle: "Alice",
                senderId: "user1",
                senderName: "Alice",
                timestamp: "2026-02-12T15:3\(i):00Z",
                text: "Message \(i)",
                isSender: false,
                type: "text",
                attachments: [],
                replyTo: nil
            )
            try writer.write(record: record)
        }

        let path = "\(tmpDir!)/signal/Alice/2026-02-12.jsonl"
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)
    }

    func testNetworkNameNormalization() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let record = MessageRecord(
            id: "msg1",
            chatId: "!test:beeper.com",
            network: "Twitter/X",
            chatTitle: "Some User",
            senderId: "user1",
            senderName: "User",
            timestamp: "2026-02-12T15:30:00Z",
            text: "Tweet",
            isSender: false,
            type: "text",
            attachments: [],
            replyTo: nil
        )
        try writer.write(record: record)

        // Slash should be sanitized
        let networkDir = "\(tmpDir!)/twitter-x"
        XCTAssertTrue(FileManager.default.fileExists(atPath: networkDir))
    }

    func testChatTitleSanitization() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let record = MessageRecord(
            id: "msg1",
            chatId: "!test:beeper.com",
            network: "WhatsApp",
            chatTitle: "Family: Mom/Dad & Kids",
            senderId: "user1",
            senderName: "Mom",
            timestamp: "2026-02-12T15:30:00Z",
            text: "Hi",
            isSender: false,
            type: "text",
            attachments: [],
            replyTo: nil
        )
        try writer.write(record: record)

        // Slashes and colons should be sanitized, but the dir should exist
        let whatsappDir = "\(tmpDir!)/whatsapp"
        let contents = try FileManager.default.contentsOfDirectory(atPath: whatsappDir)
        XCTAssertEqual(contents.count, 1)
        // The sanitized name should not contain / or :
        XCTAssertFalse(contents[0].contains("/"))
        XCTAssertFalse(contents[0].contains(":"))
    }

    func testDifferentDatesGoToDifferentFiles() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let record1 = MessageRecord(
            id: "msg1", chatId: "c1", network: "Signal", chatTitle: "Bob",
            senderId: "u1", senderName: "Bob", timestamp: "2026-02-12T10:00:00Z",
            text: "Day 1", isSender: false, type: "text", attachments: [], replyTo: nil
        )
        let record2 = MessageRecord(
            id: "msg2", chatId: "c1", network: "Signal", chatTitle: "Bob",
            senderId: "u1", senderName: "Bob", timestamp: "2026-02-13T10:00:00Z",
            text: "Day 2", isSender: false, type: "text", attachments: [], replyTo: nil
        )
        try writer.write(record: record1)
        try writer.write(record: record2)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: "\(tmpDir!)/signal/Bob/2026-02-12.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: "\(tmpDir!)/signal/Bob/2026-02-13.jsonl"))
    }
}
```

**Step 2: Run to verify they fail**

Run: `swift test --filter LogWriterTests`
Expected: FAIL — LogWriter, MessageRecord not found

**Step 3: Implement LogWriter and MessageRecord**

```swift
import Foundation

struct MessageRecord: Codable {
    let id: String
    let chatId: String
    let network: String
    let chatTitle: String
    let senderId: String?
    let senderName: String?
    let timestamp: String
    let text: String?
    let isSender: Bool
    let type: String?
    let attachments: [AttachmentRecord]
    let replyTo: String?
}

struct AttachmentRecord: Codable {
    let id: String?
    let type: String
    let localPath: String?
    let mimeType: String?
    let fileName: String?
}

class LogWriter {
    let baseDir: String
    private let encoder: JSONEncoder
    private let fm = FileManager.default

    init(baseDir: String) {
        self.baseDir = baseDir
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    func write(record: MessageRecord) throws {
        let dirPath = chatDir(network: record.network, chatTitle: record.chatTitle)
        try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)

        let date = extractDate(from: record.timestamp)
        let filePath = "\(dirPath)/\(date).jsonl"

        let data = try encoder.encode(record)
        let line = data + Data("\n".utf8)

        if fm.fileExists(atPath: filePath) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try line.write(to: URL(fileURLWithPath: filePath))
        }
    }

    func attachmentDir(network: String, chatTitle: String, date: String) -> String {
        let dir = chatDir(network: network, chatTitle: chatTitle)
        return "\(dir)/\(date)"
    }

    func chatDir(network: String, chatTitle: String) -> String {
        let sanitizedNetwork = sanitize(network).lowercased()
        let sanitizedTitle = sanitize(chatTitle)
        return "\(baseDir)/\(sanitizedNetwork)/\(sanitizedTitle)"
    }

    private func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: illegal).joined(separator: "-")
    }

    private func extractDate(from timestamp: String) -> String {
        // Timestamps are ISO 8601: "2026-02-12T15:30:00Z"
        // Extract just the date part
        if let tIndex = timestamp.firstIndex(of: "T") {
            return String(timestamp[timestamp.startIndex..<tIndex])
        }
        return String(timestamp.prefix(10))
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter LogWriterTests`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/LogWriter.swift Tests/BeeperMessageSyncTests/LogWriterTests.swift
git commit -m "feat: add LogWriter with per-chat JSONL output"
```

---

### Task 7: MetadataWriter — Per-Chat metadata.json

Writes and updates `metadata.json` for each chat directory.

**Files:**
- Create: `Sources/BeeperMessageSync/MetadataWriter.swift`
- Create: `Tests/BeeperMessageSyncTests/MetadataWriterTests.swift`

**Step 1: Write the failing test**

```swift
import XCTest
@testable import beeper_message_sync

final class MetadataWriterTests: XCTestCase {
    var tmpDir: String!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    func testWriteMetadata() throws {
        let writer = MetadataWriter()
        let metadata = ChatMetadata(
            chatId: "!test:beeper.com",
            accountId: "local-signal_ba_abc",
            network: "Signal",
            title: "Alice",
            type: "single",
            participants: [
                ParticipantInfo(id: "u1", name: "Alice", phone: "+1555", isSelf: false),
                ParticipantInfo(id: "u2", name: "Jesse", phone: nil, isSelf: true),
            ],
            firstSeen: "2026-02-12T10:00:00Z",
            lastUpdated: "2026-02-12T15:30:00Z"
        )

        let dir = "\(tmpDir!)/signal/Alice"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try writer.write(metadata: metadata, toDir: dir)

        let path = "\(dir)/metadata.json"
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode(ChatMetadata.self, from: data)
        XCTAssertEqual(decoded.chatId, "!test:beeper.com")
        XCTAssertEqual(decoded.title, "Alice")
        XCTAssertEqual(decoded.participants.count, 2)
    }

    func testUpdateMetadata() throws {
        let writer = MetadataWriter()
        let dir = "\(tmpDir!)/signal/Alice"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let original = ChatMetadata(
            chatId: "!test:beeper.com", accountId: "acc1", network: "Signal",
            title: "Alice", type: "single", participants: [],
            firstSeen: "2026-02-12T10:00:00Z", lastUpdated: "2026-02-12T10:00:00Z"
        )
        try writer.write(metadata: original, toDir: dir)

        let updated = ChatMetadata(
            chatId: "!test:beeper.com", accountId: "acc1", network: "Signal",
            title: "Alice (New Name)", type: "single", participants: [],
            firstSeen: "2026-02-12T10:00:00Z", lastUpdated: "2026-02-12T16:00:00Z"
        )
        try writer.write(metadata: updated, toDir: dir)

        let data = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/metadata.json"))
        let decoded = try JSONDecoder().decode(ChatMetadata.self, from: data)
        XCTAssertEqual(decoded.title, "Alice (New Name)")
        XCTAssertEqual(decoded.firstSeen, "2026-02-12T10:00:00Z") // preserved
    }
}
```

**Step 2: Run to verify they fail**

Run: `swift test --filter MetadataWriterTests`
Expected: FAIL — types not found

**Step 3: Implement MetadataWriter**

```swift
import Foundation

struct ChatMetadata: Codable {
    let chatId: String
    let accountId: String
    let network: String
    let title: String
    let type: String
    let participants: [ParticipantInfo]
    let firstSeen: String
    let lastUpdated: String
}

struct ParticipantInfo: Codable {
    let id: String
    let name: String?
    let phone: String?
    let isSelf: Bool
}

struct MetadataWriter {
    private let encoder: JSONEncoder

    init() {
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func write(metadata: ChatMetadata, toDir dir: String) throws {
        let path = "\(dir)/metadata.json"

        // Preserve firstSeen from existing file if it exists
        var finalMetadata = metadata
        if let existingData = FileManager.default.contents(atPath: path),
           let existing = try? JSONDecoder().decode(ChatMetadata.self, from: existingData) {
            finalMetadata = ChatMetadata(
                chatId: metadata.chatId,
                accountId: metadata.accountId,
                network: metadata.network,
                title: metadata.title,
                type: metadata.type,
                participants: metadata.participants,
                firstSeen: existing.firstSeen,
                lastUpdated: metadata.lastUpdated
            )
        }

        let data = try encoder.encode(finalMetadata)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter MetadataWriterTests`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/MetadataWriter.swift Tests/BeeperMessageSyncTests/MetadataWriterTests.swift
git commit -m "feat: add MetadataWriter for per-chat metadata.json"
```

---

### Task 8: AttachmentFetcher — Download and Store Attachments

Downloads attachments via the Beeper API and copies them to the correct date directory.

**Files:**
- Create: `Sources/BeeperMessageSync/AttachmentFetcher.swift`
- Create: `Tests/BeeperMessageSyncTests/AttachmentFetcherTests.swift`

**Step 1: Write the failing test**

Unit test for the file-copy logic, plus an integration test for the API call.

```swift
import XCTest
@testable import beeper_message_sync

final class AttachmentFetcherTests: XCTestCase {
    var tmpDir: String!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        try? FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    func testCopyAttachmentToDateDir() throws {
        // Create a fake source file
        let sourceDir = "\(tmpDir!)/source"
        try FileManager.default.createDirectory(
            atPath: sourceDir, withIntermediateDirectories: true
        )
        let sourcePath = "\(sourceDir)/photo.png"
        try Data("fake image".utf8).write(to: URL(fileURLWithPath: sourcePath))

        let destDir = "\(tmpDir!)/signal/Alice/2026-02-12"
        let result = try AttachmentFetcher.copyAttachment(
            from: sourcePath,
            toDir: destDir,
            fileName: "photo.png"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result))
        XCTAssertTrue(result.hasSuffix("/2026-02-12/photo.png"))
    }

    func testFileURLParsing() {
        let fileURL = "file:///Users/jesse/Library/Application%20Support/BeeperTexts/media/photo.png"
        let parsed = AttachmentFetcher.parseFileURL(fileURL)
        XCTAssertEqual(parsed, "/Users/jesse/Library/Application Support/BeeperTexts/media/photo.png")
    }

    func testDuplicateFileNamesGetSuffix() throws {
        let destDir = "\(tmpDir!)/attachments"
        try FileManager.default.createDirectory(
            atPath: destDir, withIntermediateDirectories: true
        )

        // Create first file
        let sourcePath = "\(tmpDir!)/photo.png"
        try Data("image1".utf8).write(to: URL(fileURLWithPath: sourcePath))
        let first = try AttachmentFetcher.copyAttachment(
            from: sourcePath, toDir: destDir, fileName: "photo.png"
        )
        XCTAssertTrue(first.hasSuffix("photo.png"))

        // Create second file with same name
        try Data("image2".utf8).write(to: URL(fileURLWithPath: sourcePath))
        let second = try AttachmentFetcher.copyAttachment(
            from: sourcePath, toDir: destDir, fileName: "photo.png"
        )
        XCTAssertTrue(second.hasSuffix("photo-1.png"))
    }
}
```

**Step 2: Run to verify they fail**

Run: `swift test --filter AttachmentFetcherTests`
Expected: FAIL — AttachmentFetcher not found

**Step 3: Implement AttachmentFetcher**

```swift
import Foundation

struct AttachmentFetcher {
    let client: BeeperClient
    let logWriter: LogWriter

    /// Download an attachment via Beeper API, copy to date directory, return relative path
    func fetch(
        attachment: Attachment,
        network: String,
        chatTitle: String,
        date: String
    ) async throws -> String? {
        guard let assetID = attachment.id else { return nil }

        // Ask Beeper to download the asset and give us a local file path
        let response = try await client.downloadAsset(url: assetID)
        guard let srcURL = response.srcURL else {
            if let error = response.error {
                print("  Warning: attachment download failed: \(error)")
            }
            return nil
        }

        let sourcePath = Self.parseFileURL(srcURL)
        let destDir = logWriter.attachmentDir(
            network: network, chatTitle: chatTitle, date: date
        )
        let fileName = attachment.fileName
            ?? URL(fileURLWithPath: sourcePath).lastPathComponent

        let destPath = try Self.copyAttachment(
            from: sourcePath, toDir: destDir, fileName: fileName
        )

        // Return path relative to chat directory
        let chatDir = logWriter.chatDir(network: network, chatTitle: chatTitle)
        if destPath.hasPrefix(chatDir) {
            return String(destPath.dropFirst(chatDir.count + 1))
        }
        return destPath
    }

    /// Parse a file:// URL to a filesystem path
    static func parseFileURL(_ urlString: String) -> String {
        if urlString.hasPrefix("file://") {
            if let url = URL(string: urlString) {
                return url.path
            }
            // Fallback: strip prefix and decode
            let stripped = String(urlString.dropFirst("file://".count))
            return stripped.removingPercentEncoding ?? stripped
        }
        return urlString
    }

    /// Copy a file to the destination directory, handling name conflicts
    @discardableResult
    static func copyAttachment(
        from sourcePath: String,
        toDir destDir: String,
        fileName: String
    ) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        var destPath = "\(destDir)/\(fileName)"
        if fm.fileExists(atPath: destPath) {
            // Add numeric suffix to avoid collision
            let name = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            var counter = 1
            repeat {
                let suffixed = ext.isEmpty ? "\(name)-\(counter)" : "\(name)-\(counter).\(ext)"
                destPath = "\(destDir)/\(suffixed)"
                counter += 1
            } while fm.fileExists(atPath: destPath)
        }

        try fm.copyItem(atPath: sourcePath, toPath: destPath)
        return destPath
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter AttachmentFetcherTests`
Expected: All tests pass

**Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/AttachmentFetcher.swift Tests/BeeperMessageSyncTests/AttachmentFetcherTests.swift
git commit -m "feat: add AttachmentFetcher for downloading and storing attachments"
```

---

### Task 9: SyncEngine — Core Polling and Sync Logic

Orchestrates the full sync loop: poll chats, fetch new messages, write logs, download attachments.

**Files:**
- Create: `Sources/BeeperMessageSync/SyncEngine.swift`
- Create: `Tests/BeeperMessageSyncTests/SyncEngineTests.swift`

**Step 1: Write integration test against live API**

```swift
import XCTest
@testable import beeper_message_sync

final class SyncEngineTests: XCTestCase {
    var tmpDir: String!
    var config: Config!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        config = Config.load(
            from: "/Users/jesse/prime-radiant/beeper-message-sync/.env"
        )
        guard config.beeperToken != nil else {
            throw XCTSkip("No BEEPER_TOKEN in .env")
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    func testSinglePollCycleCreatesFiles() async throws {
        let stateFile = "\(tmpDir!)/state.json"
        let engine = SyncEngine(
            config: Config(env: [
                "BEEPER_TOKEN": config.beeperToken!,
                "BEEPER_URL": config.beeperURL,
                "LOG_DIR": tmpDir!,
                "STATE_FILE": stateFile,
            ])
        )

        // Run one poll cycle
        try await engine.pollOnce()

        // Should have created directories and files
        let logContents = try FileManager.default
            .contentsOfDirectory(atPath: tmpDir)
            .filter { $0 != "state.json" }
        XCTAssertFalse(logContents.isEmpty, "Should have created network directories")

        // State should be saved
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile))
    }

    func testBackfillFetchesAllMessages() async throws {
        let stateFile = "\(tmpDir!)/state.json"
        let engine = SyncEngine(
            config: Config(env: [
                "BEEPER_TOKEN": config.beeperToken!,
                "BEEPER_URL": config.beeperURL,
                "LOG_DIR": tmpDir!,
                "STATE_FILE": stateFile,
            ])
        )

        // Run backfill on first chat only (to keep test fast)
        let chats = try await engine.client.listChats(limit: 1)
        guard let chat = chats.items.first else {
            throw XCTSkip("No chats available")
        }
        let count = try await engine.backfillChat(chat)
        print("Backfilled \(count) messages from \(chat.title)")
        XCTAssertGreaterThan(count, 0)
    }
}
```

**Step 2: Run to verify they fail**

Run: `swift test --filter SyncEngineTests`
Expected: FAIL — SyncEngine not found

**Step 3: Implement SyncEngine**

```swift
import Foundation

class SyncEngine {
    let client: BeeperClient
    let logWriter: LogWriter
    let metadataWriter: MetadataWriter
    let attachmentFetcher: AttachmentFetcher
    let stateStore: StateStore
    let config: Config

    init(config: Config) {
        self.config = config
        self.client = BeeperClient(
            baseURL: config.beeperURL,
            token: config.beeperToken ?? ""
        )
        self.logWriter = LogWriter(baseDir: config.logDir)
        self.metadataWriter = MetadataWriter()
        self.attachmentFetcher = AttachmentFetcher(
            client: client, logWriter: logWriter
        )
        self.stateStore = StateStore(path: config.stateFile)
    }

    /// Run a single poll cycle: check all chats for new messages
    func pollOnce() async throws {
        var cursor: String? = nil
        var allChats: [Chat] = []

        // Fetch all chats (paginate)
        repeat {
            let response = try await client.listChats(cursor: cursor)
            allChats.append(contentsOf: response.items)
            if response.hasMore, let last = response.items.last {
                cursor = last.lastActivity
            } else {
                break
            }
        } while true

        for chat in allChats {
            let storedActivity = stateStore.lastActivity(for: chat.id)

            // Skip chats that haven't changed since last poll
            if let stored = storedActivity, let current = chat.lastActivity,
               stored == current {
                continue
            }

            try await syncChat(chat)
        }

        try stateStore.save()
    }

    /// Fetch and log new messages for a single chat
    func syncChat(_ chat: Chat) async throws {
        // Update metadata
        let chatDir = logWriter.chatDir(network: chat.network, chatTitle: chat.title)
        try FileManager.default.createDirectory(
            atPath: chatDir, withIntermediateDirectories: true
        )
        let metadata = buildMetadata(from: chat)
        try metadataWriter.write(metadata: metadata, toDir: chatDir)

        // Fetch messages newer than our last seen sort key
        let lastSortKey = stateStore.lastSortKey(for: chat.id)
        var newMessages: [Message] = []
        var msgCursor: String? = lastSortKey
        let direction: String? = lastSortKey != nil ? "after" : nil

        repeat {
            let response = try await client.listMessages(
                chatID: chat.id,
                cursor: msgCursor,
                direction: direction
            )
            newMessages.append(contentsOf: response.items)
            if response.hasMore, let last = response.items.last?.sortKey {
                msgCursor = last
            } else {
                break
            }
        } while true

        // Filter out already-seen messages and sort by timestamp
        let filtered = newMessages.filter { msg in
            guard let sortKey = msg.sortKey, let last = lastSortKey else { return true }
            return sortKey > last
        }

        // Write messages
        for message in filtered {
            let date = extractDate(from: message.timestamp)

            // Download attachments
            var attachmentRecords: [AttachmentRecord] = []
            for attachment in message.attachments ?? [] {
                let localPath = try await attachmentFetcher.fetch(
                    attachment: attachment,
                    network: chat.network,
                    chatTitle: chat.title,
                    date: date
                )
                attachmentRecords.append(AttachmentRecord(
                    id: attachment.id,
                    type: attachment.type,
                    localPath: localPath,
                    mimeType: attachment.mimeType,
                    fileName: attachment.fileName
                ))
            }

            let record = MessageRecord(
                id: message.id,
                chatId: chat.id,
                network: chat.network,
                chatTitle: chat.title,
                senderId: message.senderID,
                senderName: message.senderName,
                timestamp: message.timestamp,
                text: message.text,
                isSender: message.isSender ?? false,
                type: message.type,
                attachments: attachmentRecords,
                replyTo: message.linkedMessageID
            )
            try logWriter.write(record: record)
        }

        // Update state
        if let lastMsg = filtered.last {
            stateStore.update(
                chatID: chat.id,
                lastSortKey: lastMsg.sortKey,
                lastActivity: chat.lastActivity
            )
        } else if let activity = chat.lastActivity {
            stateStore.update(
                chatID: chat.id,
                lastSortKey: nil,
                lastActivity: activity
            )
        }
    }

    /// Full backfill: paginate backward through all messages in a chat
    @discardableResult
    func backfillChat(_ chat: Chat) async throws -> Int {
        let chatDir = logWriter.chatDir(network: chat.network, chatTitle: chat.title)
        try FileManager.default.createDirectory(
            atPath: chatDir, withIntermediateDirectories: true
        )
        let metadata = buildMetadata(from: chat)
        try metadataWriter.write(metadata: metadata, toDir: chatDir)

        var allMessages: [Message] = []
        var cursor: String? = nil

        // Paginate backward (default direction) to get all history
        repeat {
            let response = try await client.listMessages(
                chatID: chat.id,
                cursor: cursor,
                direction: cursor != nil ? "before" : nil
            )
            allMessages.append(contentsOf: response.items)
            if response.hasMore, let first = response.items.last?.sortKey {
                cursor = first
            } else {
                break
            }
        } while true

        // Sort chronologically and write
        let sorted = allMessages.sorted { ($0.sortKey ?? "") < ($1.sortKey ?? "") }
        for message in sorted {
            let date = extractDate(from: message.timestamp)
            var attachmentRecords: [AttachmentRecord] = []
            for attachment in message.attachments ?? [] {
                let localPath = try await attachmentFetcher.fetch(
                    attachment: attachment,
                    network: chat.network,
                    chatTitle: chat.title,
                    date: date
                )
                attachmentRecords.append(AttachmentRecord(
                    id: attachment.id,
                    type: attachment.type,
                    localPath: localPath,
                    mimeType: attachment.mimeType,
                    fileName: attachment.fileName
                ))
            }

            let record = MessageRecord(
                id: message.id,
                chatId: chat.id,
                network: chat.network,
                chatTitle: chat.title,
                senderId: message.senderID,
                senderName: message.senderName,
                timestamp: message.timestamp,
                text: message.text,
                isSender: message.isSender ?? false,
                type: message.type,
                attachments: attachmentRecords,
                replyTo: message.linkedMessageID
            )
            try logWriter.write(record: record)
        }

        // Update state to latest message
        if let lastMsg = sorted.last {
            stateStore.update(
                chatID: chat.id,
                lastSortKey: lastMsg.sortKey,
                lastActivity: chat.lastActivity
            )
            try stateStore.save()
        }

        return sorted.count
    }

    // MARK: - Helpers

    private func buildMetadata(from chat: Chat) -> ChatMetadata {
        let now = ISO8601DateFormatter().string(from: Date())
        return ChatMetadata(
            chatId: chat.id,
            accountId: chat.accountID,
            network: chat.network,
            title: chat.title,
            type: chat.type,
            participants: chat.participants.items.map { user in
                ParticipantInfo(
                    id: user.id,
                    name: user.fullName ?? user.username,
                    phone: user.phoneNumber,
                    isSelf: user.isSelf ?? false
                )
            },
            firstSeen: now,
            lastUpdated: now
        )
    }

    private func extractDate(from timestamp: String) -> String {
        if let tIndex = timestamp.firstIndex(of: "T") {
            return String(timestamp[timestamp.startIndex..<tIndex])
        }
        return String(timestamp.prefix(10))
    }
}
```

**Step 4: Run tests**

Run: `swift test --filter SyncEngineTests`
Expected: All tests pass (requires Beeper Desktop running)

**Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/SyncEngine.swift Tests/BeeperMessageSyncTests/SyncEngineTests.swift
git commit -m "feat: add SyncEngine with polling and backfill"
```

---

### Task 10: Main Entry Point — CLI with Backfill and Daemon Modes

Wire everything together in `main.swift` with two modes: `backfill` (one-shot full history) and `watch` (continuous polling).

**Files:**
- Modify: `Sources/BeeperMessageSync/main.swift`

**Step 1: Write the entry point**

```swift
import Foundation

@main
struct BeeperMessageSyncApp {
    static func main() async throws {
        let args = CommandLine.arguments
        let mode = args.count > 1 ? args[1] : "watch"

        // Find .env relative to executable or use current directory
        let envPath = findEnvFile()
        let config = Config.load(from: envPath)

        guard config.beeperToken != nil else {
            print("Error: BEEPER_TOKEN not set. Add it to .env or set the environment variable.")
            Foundation.exit(1)
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
            Foundation.exit(1)
        }
    }

    static func runBackfill(engine: SyncEngine) async throws {
        let chats = try await fetchAllChats(engine: engine)
        print("Backfilling \(chats.count) chats...")

        for (i, chat) in chats.enumerated() {
            print("  [\(i + 1)/\(chats.count)] \(chat.network): \(chat.title)...", terminator: "")
            fflush(stdout)
            let count = try await engine.backfillChat(chat)
            print(" \(count) messages")
        }

        print("Backfill complete.")
    }

    static func runWatch(engine: SyncEngine, interval: Int) async throws {
        while true {
            do {
                try await engine.pollOnce()
            } catch {
                print("Poll error: \(error.localizedDescription)")
            }
            try await Task.sleep(for: .seconds(interval))
        }
    }

    static func fetchAllChats(engine: SyncEngine) async throws -> [Chat] {
        var allChats: [Chat] = []
        var cursor: String? = nil
        repeat {
            let response = try await engine.client.listChats(cursor: cursor)
            allChats.append(contentsOf: response.items)
            if response.hasMore, let last = response.items.last?.lastActivity {
                cursor = last
            } else {
                break
            }
        } while true
        return allChats
    }

    static func findEnvFile() -> String {
        // Check current directory first, then executable directory
        let cwd = FileManager.default.currentDirectoryPath
        let cwdEnv = "\(cwd)/.env"
        if FileManager.default.fileExists(atPath: cwdEnv) {
            return cwdEnv
        }

        let execDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        return "\(execDir)/.env"
    }
}
```

Note: Using `@main` attribute means we need to remove the old `main.swift` placeholder content and may need to rename the file or restructure slightly — the `@main` struct approach and a bare `main.swift` are mutually exclusive in Swift. Use the `@main` struct in a file named something other than `main.swift` (e.g., `App.swift`), OR keep `main.swift` with top-level code. The simplest approach: **keep `main.swift` with top-level async code** (no `@main`).

Revised — use top-level code in `main.swift`:

```swift
import Foundation

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
    let chats = try await fetchAllChats(engine: engine)
    print("Backfilling \(chats.count) chats...")

    for (i, chat) in chats.enumerated() {
        print("  [\(i + 1)/\(chats.count)] \(chat.network): \(chat.title)...", terminator: "")
        fflush(stdout)
        let count = try await engine.backfillChat(chat)
        print(" \(count) messages")
    }

    print("Backfill complete.")
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

func fetchAllChats(engine: SyncEngine) async throws -> [Chat] {
    var allChats: [Chat] = []
    var cursor: String? = nil
    repeat {
        let response = try await engine.client.listChats(cursor: cursor)
        allChats.append(contentsOf: response.items)
        if response.hasMore, let last = response.items.last?.lastActivity {
            cursor = last
        } else {
            break
        }
    } while true
    return allChats
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
```

**Step 2: Build and test manually**

Run: `swift build`
Expected: Build Succeeded

Run: `swift run beeper-message-sync backfill 2>&1 | head -20`
Expected: Shows backfill progress for real chats

**Step 3: Commit**

```bash
git add Sources/BeeperMessageSync/main.swift
git commit -m "feat: wire up main entry point with backfill and watch modes"
```

---

### Task 11: launchd Plist for Daemon Operation

Create the launchd plist and an install script.

**Files:**
- Create: `com.primeradiant.beeper-message-sync.plist`
- Create: `scripts/install.sh`

**Step 1: Create the plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.primeradiant.beeper-message-sync</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/jesse/prime-radiant/beeper-message-sync/.build/release/beeper-message-sync</string>
        <string>watch</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/jesse/prime-radiant/beeper-message-sync</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/jesse/beeper-message-sync/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/jesse/beeper-message-sync/daemon.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/jesse</string>
    </dict>
</dict>
</plist>
```

**Step 2: Create install script**

```bash
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST_NAME="com.primeradiant.beeper-message-sync.plist"
PLIST_SRC="$SCRIPT_DIR/$PLIST_NAME"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "Building release binary..."
cd "$SCRIPT_DIR"
swift build -c release

echo "Creating log directory..."
mkdir -p "$HOME/beeper-message-sync"

echo "Installing launchd plist..."
# Unload if already loaded
launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
cp "$PLIST_SRC" "$PLIST_DEST"
launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST"

echo "Done. Service is running."
echo "  Logs: $HOME/beeper-message-sync/daemon.log"
echo "  Stop: launchctl bootout gui/$(id -u)/$PLIST_NAME"
```

**Step 3: Commit**

```bash
chmod +x scripts/install.sh
git add com.primeradiant.beeper-message-sync.plist scripts/install.sh
git commit -m "feat: add launchd plist and install script"
```

---

### Task 12: Manual End-to-End Test

Run backfill on real data, verify output structure.

**Step 1: Build release**

Run: `cd /Users/jesse/prime-radiant/beeper-message-sync && swift build -c release`

**Step 2: Run backfill**

Run: `swift run beeper-message-sync backfill`
Watch the output — should show progress for each chat.

**Step 3: Verify output structure**

Run: `find ~/beeper-message-sync/logs -type f | head -30`
Expected: Files in `network/contact/date.jsonl` structure with `metadata.json` files.

Run: `head -3 ~/beeper-message-sync/logs/signal/*/2026-*.jsonl`
Expected: Valid JSONL with message records.

Run: `cat ~/beeper-message-sync/logs/signal/*/metadata.json | python3 -m json.tool | head -20`
Expected: Valid JSON with chat metadata.

**Step 4: Verify attachments**

Run: `find ~/beeper-message-sync/logs -type d -name "2026-*" | head -5`
Expected: Date directories containing downloaded attachment files.

**Step 5: Test watch mode briefly**

Run: `timeout 15 swift run beeper-message-sync watch` (let it run ~15s)
Expected: Starts watching, no errors.

**Step 6: Fix any issues found, commit**

```bash
git add -A  # after git status check
git commit -m "fix: address issues found in end-to-end testing"
```

---

### Summary

| Task | Component | Type |
|------|-----------|------|
| 1 | SPM scaffold | Setup |
| 2 | Config | Feature (TDD) |
| 3 | API Models | Feature (TDD) |
| 4 | BeeperClient | Feature (TDD) |
| 5 | StateStore | Feature (TDD) |
| 6 | LogWriter | Feature (TDD) |
| 7 | MetadataWriter | Feature (TDD) |
| 8 | AttachmentFetcher | Feature (TDD) |
| 9 | SyncEngine | Feature (TDD) |
| 10 | Main entry point | Integration |
| 11 | launchd plist | Deployment |
| 12 | End-to-end test | Verification |
