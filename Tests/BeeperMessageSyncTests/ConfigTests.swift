import XCTest
@testable import beeper_message_sync

final class ConfigTests: XCTestCase {
    func testDefaultValues() {
        let config = Config(env: [:])
        XCTAssertEqual(config.beeperURL, "http://localhost:23373")
        XCTAssertEqual(config.pollInterval, 5)
        XCTAssertTrue(config.logDir.hasSuffix("Beeper-Sync/logs"))
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
