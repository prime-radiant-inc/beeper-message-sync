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
        let record = makeRecord(id: "msg1", timestamp: "2026-02-12T15:30:00Z", text: "Hello!")
        let dir = writer.chatDir(network: "Signal", chatTitle: "Alice")
        try writer.write(record: record, toDir: dir)

        let expectedPath = "\(tmpDir!)/signal/Alice/2026-02-12.jsonl"
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPath))

        let content = try String(contentsOfFile: expectedPath, encoding: .utf8)
        XCTAssertTrue(content.contains("\"id\":\"msg1\""))
        XCTAssertFalse(content.contains("\"network\""))
        XCTAssertFalse(content.contains("\"chatId\""))
        XCTAssertFalse(content.contains("\"chatTitle\""))
        XCTAssertTrue(content.hasSuffix("\n"))
    }

    func testMultipleMessagesAppend() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let dir = writer.chatDir(network: "Signal", chatTitle: "Alice")
        for i in 1...3 {
            let record = makeRecord(
                id: "msg\(i)", timestamp: "2026-02-12T15:3\(i):00Z", text: "Message \(i)"
            )
            try writer.write(record: record, toDir: dir)
        }

        let path = "\(tmpDir!)/signal/Alice/2026-02-12.jsonl"
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 3)
    }

    func testNetworkNameNormalization() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let record = makeRecord(id: "msg1", timestamp: "2026-02-12T15:30:00Z", text: "Tweet")
        let dir = writer.chatDir(network: "Twitter/X", chatTitle: "Some User")
        try writer.write(record: record, toDir: dir)

        // Slash should be percent-encoded
        let networkDir = "\(tmpDir!)/twitter%2fx"
        XCTAssertTrue(FileManager.default.fileExists(atPath: networkDir))
    }

    func testChatTitleSanitization() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let record = makeRecord(id: "msg1", timestamp: "2026-02-12T15:30:00Z", text: "Hi")
        let dir = writer.chatDir(network: "WhatsApp", chatTitle: "Family: Mom/Dad & Kids")
        try writer.write(record: record, toDir: dir)

        // Slashes and colons should be percent-encoded, but the dir should exist
        let whatsappDir = "\(tmpDir!)/whatsapp"
        let contents = try FileManager.default.contentsOfDirectory(atPath: whatsappDir)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0], "Family%3A Mom%2FDad & Kids")
    }

    func testSanitizationHandlesEmojiAndSpecialChars() throws {
        let writer = LogWriter(baseDir: tmpDir)

        let cases: [(title: String, expected: String)] = [
            ("Personal Agents 🦞🦀🛫😱", "Personal Agents 🦞🦀🛫😱"),
            ("Intros <\u{2014}- start here", "Intros %3C\u{2014}- start here"),
            ("\u{65E5}\u{672C}\u{8A9E}", "\u{65E5}\u{672C}\u{8A9E}"),
            ("Family: Mom/Dad & Kids", "Family%3A Mom%2FDad & Kids"),
        ]

        for (i, testCase) in cases.enumerated() {
            let record = makeRecord(
                id: "msg\(i)", timestamp: "2026-02-12T10:00:00Z", text: "Hi"
            )
            let dir = writer.chatDir(network: "Test", chatTitle: testCase.title)
            try writer.write(record: record, toDir: dir)

            let dirName = URL(fileURLWithPath: dir).lastPathComponent
            XCTAssertEqual(dirName, testCase.expected,
                "Sanitizing '\(testCase.title)' should produce '\(testCase.expected)' but got '\(dirName)'")
        }
    }

    func testDifferentDatesGoToDifferentFiles() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let dir = writer.chatDir(network: "Signal", chatTitle: "Bob")
        let record1 = makeRecord(
            id: "msg1", timestamp: "2026-02-12T10:00:00Z", text: "Day 1"
        )
        let record2 = makeRecord(
            id: "msg2", timestamp: "2026-02-13T10:00:00Z", text: "Day 2"
        )
        try writer.write(record: record1, toDir: dir)
        try writer.write(record: record2, toDir: dir)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: "\(tmpDir!)/signal/Bob/2026-02-12.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: "\(tmpDir!)/signal/Bob/2026-02-13.jsonl"))
    }

    // MARK: - Helpers

    private func makeRecord(id: String, timestamp: String, text: String) -> MessageRecord {
        MessageRecord(
            id: id,
            senderId: "user1",
            senderName: "Test User",
            timestamp: timestamp,
            text: text,
            isSender: false,
            type: "text",
            attachments: [],
            replyTo: nil
        )
    }
}
