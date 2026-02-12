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
