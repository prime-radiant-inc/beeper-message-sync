import XCTest
@testable import beeper_message_sync

final class BeeperClientTests: XCTestCase {
    var client: BeeperClient!

    override func setUp() async throws {
        let config = Config.load(environment: ProcessInfo.processInfo.environment)
        guard let token = config.beeperToken else {
            throw XCTSkip("No BEEPER_TOKEN configured")
        }
        client = BeeperClient(baseURL: config.beeperURL, token: token)
    }

    func testListAccounts() async throws {
        let accounts = try await skipOnNetworkError {
            try await client.listAccounts()
        }
        XCTAssertFalse(accounts.isEmpty, "Should have at least one account")
        let first = accounts[0]
        XCTAssertFalse(first.accountID.isEmpty)
        XCTAssertFalse(first.network.isEmpty)
    }

    func testListChats() async throws {
        let response = try await skipOnNetworkError {
            try await client.listChats()
        }
        XCTAssertFalse(response.items.isEmpty, "Should have at least one chat")
        let chat = response.items[0]
        XCTAssertFalse(chat.id.isEmpty)
        XCTAssertFalse(chat.title.isEmpty)
    }

    func testListMessages() async throws {
        let chats = try await skipOnNetworkError {
            try await client.listChats()
        }
        guard let chat = chats.items.first else {
            throw XCTSkip("No chats available")
        }
        let messages = try await skipOnNetworkError {
            try await client.listMessages(chatID: chat.id)
        }
        XCTAssertNotNil(messages.items)
    }

    func testListChatsWithPagination() async throws {
        let page1 = try await skipOnNetworkError {
            try await client.listChats(limit: 2)
        }
        XCTAssertFalse(page1.items.isEmpty)
        if page1.hasMore, let cursor = page1.items.last?.lastActivity {
            let page2 = try await skipOnNetworkError {
                try await client.listChats(limit: 2, cursor: cursor)
            }
            XCTAssertNotNil(page2)
        }
    }

    // MARK: - Helpers

    /// Runs a closure and skips the test if a network error occurs.
    /// Integration tests should skip (not fail) when the API is unreachable.
    private func skipOnNetworkError<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch let error as URLError {
            throw XCTSkip("Beeper API unavailable: \(error.localizedDescription)")
        }
    }
}
