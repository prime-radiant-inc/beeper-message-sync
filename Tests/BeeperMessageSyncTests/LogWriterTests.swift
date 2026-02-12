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
