import XCTest
@testable import beeper_message_sync

final class KeychainHelperTests: XCTestCase {
    let testService = "com.primeradiant.beeper-message-sync.test"

    override func setUpWithError() throws {
        try super.setUpWithError()
        try skipIfKeychainUnavailable()
    }

    override func tearDown() {
        super.tearDown()
        KeychainHelper.deleteToken(service: testService)
    }

    func testSaveAndLoadToken() {
        let saved = KeychainHelper.saveToken("test-token-abc", service: testService)
        XCTAssertTrue(saved)
        let loaded = KeychainHelper.loadToken(service: testService)
        XCTAssertEqual(loaded, "test-token-abc")
    }

    func testLoadTokenReturnsNilWhenEmpty() {
        let loaded = KeychainHelper.loadToken(service: testService)
        XCTAssertNil(loaded)
    }

    func testSaveTokenOverwritesExisting() {
        KeychainHelper.saveToken("first", service: testService)
        KeychainHelper.saveToken("second", service: testService)
        let loaded = KeychainHelper.loadToken(service: testService)
        XCTAssertEqual(loaded, "second")
    }

    func testDeleteToken() {
        KeychainHelper.saveToken("to-delete", service: testService)
        KeychainHelper.deleteToken(service: testService)
        let loaded = KeychainHelper.loadToken(service: testService)
        XCTAssertNil(loaded)
    }

    func testDeleteNonexistentTokenDoesNotCrash() {
        KeychainHelper.deleteToken(service: testService)
    }

    // MARK: - Helpers

    private func skipIfKeychainUnavailable() throws {
        let probe = "keychain-probe-\(UUID().uuidString)"
        let saved = KeychainHelper.saveToken(probe, service: testService)
        if saved {
            KeychainHelper.deleteToken(service: testService)
        } else {
            throw XCTSkip("Keychain unavailable in this session (errSecInteractionNotAllowed)")
        }
    }
}
