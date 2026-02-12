import XCTest
@testable import beeper_message_sync

final class SyncEngineTests: XCTestCase {
    var tmpDir: String!
    var config: Config!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).path
        config = Config.load(
            from: "/Users/jesse/prime-radiant/beeper-message-sync/.env"
        )
        guard config.beeperToken != nil else {
            throw XCTSkip("No BEEPER_TOKEN in .env")
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    func testSinglePollCycleCreatesFiles() async throws {
        let stateFile = "\(tmpDir!)/state.json"
        let engine = SyncEngine(
            config: Config(env: [
                "BEEPER_TOKEN": config.beeperToken!,
                "BEEPER_URL": config.beeperURL,
                "LOG_DIR": tmpDir!,
                "STATE_FILE": stateFile,
            ])
        )

        do {
            try await engine.pollOnce()
        } catch let error as URLError {
            throw XCTSkip("Beeper API not responding: \(error.localizedDescription)")
        }

        let logContents = try FileManager.default
            .contentsOfDirectory(atPath: tmpDir)
            .filter { $0 != "state.json" }
        XCTAssertFalse(logContents.isEmpty, "Should have created network directories")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFile))
    }

    func testBackfillFetchesAllMessages() async throws {
        let stateFile = "\(tmpDir!)/state.json"
        let engine = SyncEngine(
            config: Config(env: [
                "BEEPER_TOKEN": config.beeperToken!,
                "BEEPER_URL": config.beeperURL,
                "LOG_DIR": tmpDir!,
                "STATE_FILE": stateFile,
            ])
        )

        let chats: ChatListResponse
        do {
            chats = try await engine.client.listChats(limit: 1)
        } catch let error as URLError {
            throw XCTSkip("Beeper API not responding: \(error.localizedDescription)")
        }
        guard let chat = chats.items.first else {
            throw XCTSkip("No chats available")
        }
        let count = try await engine.backfillChat(chat)
        print("Backfilled \(count) messages from \(chat.title)")
        XCTAssertGreaterThan(count, 0)
    }
}
