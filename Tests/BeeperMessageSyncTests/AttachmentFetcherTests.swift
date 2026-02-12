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
