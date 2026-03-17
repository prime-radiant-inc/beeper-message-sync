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
        let record = makeRecord(id: "msg1", ts: "2026-02-12T15:30:00Z", text: "Hello!")
        let dir = writer.chatDir(network: "Signal", chatTitle: "Alice")
        try writer.write(record: record, toDir: dir)

        let expectedPath = "\(tmpDir!)/signal/Alice/2026-02-12.jsonl"
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedPath))

        let content = try String(contentsOfFile: expectedPath, encoding: .utf8)
        XCTAssertTrue(content.contains("\"id\":\"msg1\""))
        XCTAssertTrue(content.contains("\"from\":{"))
        XCTAssertTrue(content.contains("\"ts\":\"2026-02-12T15:30:00Z\""))
        XCTAssertTrue(content.hasSuffix("\n"))
    }

    func testOmitsDefaultFields() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let record = makeRecord(id: "msg1", ts: "2026-02-12T15:30:00Z", text: "Hi")
        let dir = writer.chatDir(network: "Signal", chatTitle: "Alice")
        try writer.write(record: record, toDir: dir)

        let path = "\(tmpDir!)/signal/Alice/2026-02-12.jsonl"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        // TEXT type, empty attachments, nil replyTo, isSender=false should all be omitted
        XCTAssertFalse(content.contains("\"type\""), "TEXT type should be omitted")
        XCTAssertFalse(content.contains("\"attachments\""), "Empty attachments should be omitted")
        XCTAssertFalse(content.contains("\"replyTo\""), "Null replyTo should be omitted")
        XCTAssertFalse(content.contains("\"self\""), "self=false should be omitted")
    }

    func testIncludesNonDefaultFields() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let record = MessageRecord(
            id: "msg1",
            ts: "2026-02-12T15:30:00Z",
            from: Sender(id: "user1", name: "Me", self: true),
            text: nil,
            type: "MEDIA",
            attachments: [AttachmentRecord(
                id: "att1", type: "image", localPath: "photo.jpg",
                mimeType: "image/jpeg", fileName: "photo.jpg"
            )],
            replyTo: "msg0"
        )
        let dir = writer.chatDir(network: "Signal", chatTitle: "Alice")
        try writer.write(record: record, toDir: dir)

        let path = "\(tmpDir!)/signal/Alice/2026-02-12.jsonl"
        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains("\"type\":\"MEDIA\""))
        XCTAssertTrue(content.contains("\"attachments\""))
        XCTAssertTrue(content.contains("\"replyTo\":\"msg0\""))
        XCTAssertTrue(content.contains("\"self\":true"))
    }

    func testMultipleMessagesAppend() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let dir = writer.chatDir(network: "Signal", chatTitle: "Alice")
        for i in 1...3 {
            let record = makeRecord(
                id: "msg\(i)", ts: "2026-02-12T15:3\(i):00Z", text: "Message \(i)"
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
        let record = makeRecord(id: "msg1", ts: "2026-02-12T15:30:00Z", text: "Tweet")
        let dir = writer.chatDir(network: "Twitter/X", chatTitle: "Some User")
        try writer.write(record: record, toDir: dir)

        let networkDir = "\(tmpDir!)/twitter%2fx"
        XCTAssertTrue(FileManager.default.fileExists(atPath: networkDir))
    }

    func testChatTitleSanitization() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let record = makeRecord(id: "msg1", ts: "2026-02-12T15:30:00Z", text: "Hi")
        let dir = writer.chatDir(network: "WhatsApp", chatTitle: "Family: Mom/Dad & Kids")
        try writer.write(record: record, toDir: dir)

        let whatsappDir = "\(tmpDir!)/whatsapp"
        let contents = try FileManager.default.contentsOfDirectory(atPath: whatsappDir)
        XCTAssertEqual(contents.count, 1)
        XCTAssertEqual(contents[0], "Family%3A Mom%2FDad %26 Kids")
    }

    func testSanitizationHandlesEmojiAndSpecialChars() throws {
        let writer = LogWriter(baseDir: tmpDir)

        let cases: [(title: String, expected: String)] = [
            ("Personal Agents 🦞🦀🛫😱", "Personal Agents 🦞🦀🛫😱"),
            ("Intros <\u{2014}- start here", "Intros %3C\u{2014}- start here"),
            ("\u{65E5}\u{672C}\u{8A9E}", "\u{65E5}\u{672C}\u{8A9E}"),
            ("Family: Mom/Dad & Kids", "Family%3A Mom%2FDad %26 Kids"),
        ]

        for (i, testCase) in cases.enumerated() {
            let record = makeRecord(
                id: "msg\(i)", ts: "2026-02-12T10:00:00Z", text: "Hi"
            )
            let dir = writer.chatDir(network: "Test", chatTitle: testCase.title)
            try writer.write(record: record, toDir: dir)

            let dirName = URL(fileURLWithPath: dir).lastPathComponent
            XCTAssertEqual(dirName, testCase.expected,
                "Sanitizing '\(testCase.title)' should produce '\(testCase.expected)' but got '\(dirName)'")
        }
    }

    func testSanitizesAmpersandForDropbox() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let record = makeRecord(id: "msg1", ts: "2026-02-12T15:30:00Z", text: "Hi")
        let title = "+1 617-571-3000, +1 617-817-6446 & 3 others"
        let dir = writer.chatDir(network: "iMessage", chatTitle: title)
        try writer.write(record: record, toDir: dir)

        let imessageDir = "\(tmpDir!)/imessage"
        let contents = try FileManager.default.contentsOfDirectory(atPath: imessageDir)
        XCTAssertEqual(contents.count, 1)
        // & must be percent-encoded to avoid Dropbox file coordination issues
        XCTAssertFalse(contents[0].contains("&"), "Ampersand should be encoded, got: \(contents[0])")
        XCTAssertTrue(contents[0].contains("%26"), "Ampersand should be encoded as %26")
    }

    func testDifferentDatesGoToDifferentFiles() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let dir = writer.chatDir(network: "Signal", chatTitle: "Bob")
        let record1 = makeRecord(id: "msg1", ts: "2026-02-12T10:00:00Z", text: "Day 1")
        let record2 = makeRecord(id: "msg2", ts: "2026-02-13T10:00:00Z", text: "Day 2")
        try writer.write(record: record1, toDir: dir)
        try writer.write(record: record2, toDir: dir)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: "\(tmpDir!)/signal/Bob/2026-02-12.jsonl"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: "\(tmpDir!)/signal/Bob/2026-02-13.jsonl"))
    }

    func testWriteSkipsDuplicateMessageIDs() throws {
        let writer = LogWriter(baseDir: tmpDir)
        let dir = writer.chatDir(network: "Signal", chatTitle: "Alice")
        let record = makeRecord(id: "msg1", ts: "2026-02-12T15:30:00Z", text: "Hello!")
        try writer.write(record: record, toDir: dir)
        try writer.write(record: record, toDir: dir)  // duplicate

        let path = "\(tmpDir!)/signal/Alice/2026-02-12.jsonl"
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1, "Duplicate message should not be appended")
    }

    func testDeduplicatesAcrossExistingFile() throws {
        let writer1 = LogWriter(baseDir: tmpDir)
        let dir = writer1.chatDir(network: "Signal", chatTitle: "Alice")
        let record = makeRecord(id: "msg1", ts: "2026-02-12T15:30:00Z", text: "Hello!")
        try writer1.write(record: record, toDir: dir)

        // New writer instance should detect existing IDs from file
        let writer2 = LogWriter(baseDir: tmpDir)
        try writer2.write(record: record, toDir: dir)

        let path = "\(tmpDir!)/signal/Alice/2026-02-12.jsonl"
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1, "Duplicate from prior session should not be appended")
    }

    // MARK: - Helpers

    private func makeRecord(id: String, ts: String, text: String) -> MessageRecord {
        MessageRecord(
            id: id,
            ts: ts,
            from: Sender(id: "user1", name: "Test User", self: false),
            text: text,
            type: "TEXT",
            attachments: [],
            replyTo: nil
        )
    }
}
