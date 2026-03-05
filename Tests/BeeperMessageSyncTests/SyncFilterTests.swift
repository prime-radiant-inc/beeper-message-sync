import XCTest
@testable import beeper_message_sync

final class SyncFilterTests: XCTestCase {
    // MARK: - matchesChat: network filtering

    func testNoFilterMatchesEverything() {
        let filter = SyncFilter()
        let chat = makeChat(network: "imessage", title: "Alice")
        XCTAssertTrue(filter.matchesChat(chat))
    }

    func testNetworkFilterMatchesCaseInsensitive() {
        let filter = SyncFilter(networks: ["iMessage"])
        XCTAssertTrue(filter.matchesChat(makeChat(network: "imessage", title: "Alice")))
        XCTAssertTrue(filter.matchesChat(makeChat(network: "IMessage", title: "Bob")))
        XCTAssertFalse(filter.matchesChat(makeChat(network: "signal", title: "Carol")))
    }

    func testMultipleNetworks() {
        let filter = SyncFilter(networks: ["imessage", "signal"])
        XCTAssertTrue(filter.matchesChat(makeChat(network: "imessage", title: "Alice")))
        XCTAssertTrue(filter.matchesChat(makeChat(network: "Signal", title: "Bob")))
        XCTAssertFalse(filter.matchesChat(makeChat(network: "whatsapp", title: "Carol")))
    }

    // MARK: - matchesChat: title filtering

    func testTitleFilterSubstringMatch() {
        let filter = SyncFilter(chatTitles: ["alice"])
        XCTAssertTrue(filter.matchesChat(makeChat(network: "imessage", title: "Alice Smith")))
        XCTAssertTrue(filter.matchesChat(makeChat(network: "imessage", title: "ALICE")))
        XCTAssertFalse(filter.matchesChat(makeChat(network: "imessage", title: "Bob Jones")))
    }

    func testMultipleTitleFilters() {
        let filter = SyncFilter(chatTitles: ["alice", "bob"])
        XCTAssertTrue(filter.matchesChat(makeChat(network: "imessage", title: "Alice Smith")))
        XCTAssertTrue(filter.matchesChat(makeChat(network: "imessage", title: "Bob Jones")))
        XCTAssertFalse(filter.matchesChat(makeChat(network: "imessage", title: "Carol White")))
    }

    func testTitleFilterMatchesResolvedTitle() {
        let filter = SyncFilter(chatTitles: ["alice"])
        let chat = makeChat(network: "imessage", title: "+15551234567")
        XCTAssertFalse(filter.matchesChat(chat))
        XCTAssertTrue(filter.matchesChat(chat, resolvedTitle: "Alice Smith"))
    }

    // MARK: - matchesChat: combined network + title

    func testCombinedNetworkAndTitle() {
        let filter = SyncFilter(networks: ["imessage"], chatTitles: ["alice"])
        XCTAssertTrue(filter.matchesChat(makeChat(network: "imessage", title: "Alice")))
        XCTAssertFalse(filter.matchesChat(makeChat(network: "signal", title: "Alice")))
        XCTAssertFalse(filter.matchesChat(makeChat(network: "imessage", title: "Bob")))
    }

    // MARK: - matchesTimestamp

    func testNoDateFilterMatchesAll() {
        let filter = SyncFilter()
        XCTAssertTrue(filter.matchesTimestamp("2026-02-01T12:00:00Z"))
        XCTAssertTrue(filter.matchesTimestamp("not-a-date"))
    }

    func testFractionalSecondsTimestamp() {
        let filter = SyncFilter(since: makeDate("2026-02-05"))
        XCTAssertTrue(filter.matchesTimestamp("2026-02-06T12:00:00.123Z"))
        XCTAssertFalse(filter.matchesTimestamp("2026-02-04T23:59:59.999Z"))
    }

    func testSinceFilter() {
        let filter = SyncFilter(since: makeDate("2026-02-05"))
        XCTAssertTrue(filter.matchesTimestamp("2026-02-06T12:00:00Z"))
        XCTAssertTrue(filter.matchesTimestamp("2026-02-05T00:00:00Z"))
        XCTAssertFalse(filter.matchesTimestamp("2026-02-04T23:59:59Z"))
    }

    func testUntilFilter() {
        let filter = SyncFilter(until: makeDate("2026-02-10"))
        XCTAssertTrue(filter.matchesTimestamp("2026-02-09T23:59:59Z"))
        XCTAssertFalse(filter.matchesTimestamp("2026-02-10T00:00:00Z"))
        XCTAssertFalse(filter.matchesTimestamp("2026-02-11T12:00:00Z"))
    }

    func testSinceAndUntilFilter() {
        let filter = SyncFilter(
            since: makeDate("2026-02-05"),
            until: makeDate("2026-02-10")
        )
        XCTAssertFalse(filter.matchesTimestamp("2026-02-04T12:00:00Z"))
        XCTAssertTrue(filter.matchesTimestamp("2026-02-07T12:00:00Z"))
        XCTAssertFalse(filter.matchesTimestamp("2026-02-11T12:00:00Z"))
    }

    func testInvalidTimestampDoesNotMatch() {
        let filter = SyncFilter(since: makeDate("2026-02-05"))
        XCTAssertFalse(filter.matchesTimestamp("not-a-date"))
    }

    // MARK: - Helpers

    private func makeChat(network: String, title: String) -> Chat {
        Chat(
            id: "test-\(title)",
            localChatID: nil,
            accountID: network,
            title: title,
            type: "single",
            participants: Participants(items: [], hasMore: false, total: 0),
            lastActivity: nil,
            unreadCount: nil,
            isArchived: nil,
            isMuted: nil,
            isPinned: nil,
            preview: nil
        )
    }

    private func makeDate(_ dateString: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: dateString)!
    }
}
