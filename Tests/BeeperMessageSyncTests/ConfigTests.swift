import XCTest
@testable import beeper_message_sync

final class ConfigTests: XCTestCase {
    let testService = "com.primeradiant.beeper-message-sync.test-config"

    override func tearDown() {
        super.tearDown()
        KeychainHelper.deleteToken(service: testService)
    }

    func testDefaults() {
        let config = Config.load(configPath: "/nonexistent/config.json",
                                 keychainService: testService,
                                 environment: [:])
        XCTAssertNil(config.beeperToken)
        XCTAssertEqual(config.beeperURL, "http://localhost:23373")
        XCTAssertEqual(config.pollInterval, 5)
        XCTAssertTrue(config.logDir.hasSuffix("Beeper-Sync/logs"))
        XCTAssertTrue(config.stateFile.hasSuffix("Beeper-Sync/state.json"))
    }

    func testConfigFileOverridesDefaults() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configFile = tmpDir.appendingPathComponent("config.json")
        let json = """
        {
          "beeperURL": "http://custom:8080",
          "logDir": "/tmp/custom-logs",
          "stateFile": "/tmp/custom-state.json",
          "pollInterval": 30
        }
        """
        try json.write(to: configFile, atomically: true, encoding: .utf8)

        let config = Config.load(configPath: configFile.path,
                                 keychainService: testService,
                                 environment: [:])
        XCTAssertEqual(config.beeperURL, "http://custom:8080")
        XCTAssertEqual(config.logDir, "/tmp/custom-logs")
        XCTAssertEqual(config.stateFile, "/tmp/custom-state.json")
        XCTAssertEqual(config.pollInterval, 30)
    }

    func testEnvVarsOverrideConfigFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configFile = tmpDir.appendingPathComponent("config.json")
        try """
        { "beeperURL": "http://from-file:1111", "pollInterval": 10 }
        """.write(to: configFile, atomically: true, encoding: .utf8)

        let env = [
            "BEEPER_URL": "http://from-env:2222",
            "POLL_INTERVAL": "60",
        ]

        let config = Config.load(configPath: configFile.path,
                                 keychainService: testService,
                                 environment: env)
        XCTAssertEqual(config.beeperURL, "http://from-env:2222")
        XCTAssertEqual(config.pollInterval, 60)
    }

    func testKeychainTokenUsedWhenNoEnvVar() throws {
        try skipIfKeychainUnavailable()
        KeychainHelper.saveToken("keychain-token", service: testService)

        let config = Config.load(configPath: "/nonexistent",
                                 keychainService: testService,
                                 environment: [:])
        XCTAssertEqual(config.beeperToken, "keychain-token")
    }

    func testEnvVarTokenOverridesKeychain() throws {
        try skipIfKeychainUnavailable()
        KeychainHelper.saveToken("keychain-token", service: testService)

        let config = Config.load(configPath: "/nonexistent",
                                 keychainService: testService,
                                 environment: ["BEEPER_TOKEN": "env-token"])
        XCTAssertEqual(config.beeperToken, "env-token")
    }

    func testConfigFileTildeExpansion() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configFile = tmpDir.appendingPathComponent("config.json")
        try """
        { "logDir": "~/CustomLogs", "stateFile": "~/CustomState/state.json" }
        """.write(to: configFile, atomically: true, encoding: .utf8)

        let config = Config.load(configPath: configFile.path,
                                 keychainService: testService,
                                 environment: [:])
        XCTAssertTrue(config.logDir.hasPrefix("/"))
        XCTAssertFalse(config.logDir.contains("~"))
        XCTAssertTrue(config.stateFile.hasPrefix("/"))
        XCTAssertFalse(config.stateFile.contains("~"))
    }

    // MARK: - Helpers

    private func skipIfKeychainUnavailable() throws {
        let probe = "keychain-probe-\(UUID().uuidString)"
        let saved = KeychainHelper.saveToken(probe, service: testService)
        if saved {
            KeychainHelper.deleteToken(service: testService)
        } else {
            throw XCTSkip("Keychain unavailable in this session")
        }
    }
}
