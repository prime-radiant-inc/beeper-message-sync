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
