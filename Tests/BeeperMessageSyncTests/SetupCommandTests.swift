import XCTest
@testable import beeper_message_sync

final class SetupCommandTests: XCTestCase {
    func testWriteConfigFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configPath = tmpDir.appendingPathComponent("config.json").path

        try SetupCommand.writeConfigFile(
            beeperURL: "http://localhost:9999",
            logDir: "~/TestLogs",
            stateFile: "~/TestState/state.json",
            pollInterval: 15,
            to: configPath
        )

        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["beeperURL"] as? String, "http://localhost:9999")
        XCTAssertEqual(json["logDir"] as? String, "~/TestLogs")
        XCTAssertEqual(json["stateFile"] as? String, "~/TestState/state.json")
        XCTAssertEqual(json["pollInterval"] as? Int, 15)
    }

    func testWriteConfigFileCreatesDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nested/dir")
        defer {
            try? FileManager.default.removeItem(
                at: tmpDir.deletingLastPathComponent().deletingLastPathComponent()
            )
        }

        let configPath = tmpDir.appendingPathComponent("config.json").path
        try SetupCommand.writeConfigFile(
            beeperURL: "http://localhost:23373",
            logDir: "~/Dropbox/Beeper-Sync/logs",
            stateFile: "~/Dropbox/Beeper-Sync/state.json",
            pollInterval: 5,
            to: configPath
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath))
    }
}
