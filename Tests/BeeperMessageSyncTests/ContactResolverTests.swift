import XCTest
@testable import beeper_message_sync

final class ContactResolverTests: XCTestCase {

    // MARK: - normalizePhoneNumber

    func testNormalizeE164Format() {
        XCTAssertEqual(ContactResolver.normalizePhoneNumber("+18579288332"), "+18579288332")
    }

    func testNormalizeFormattedUSNumber() {
        XCTAssertEqual(ContactResolver.normalizePhoneNumber("+1 857-928-8332"), "+18579288332")
    }

    func testNormalizeParenthesesFormat() {
        XCTAssertEqual(ContactResolver.normalizePhoneNumber("(857) 928-8332"), "8579288332")
    }

    func testNormalizeDotSeparated() {
        XCTAssertEqual(ContactResolver.normalizePhoneNumber("857.928.8332"), "8579288332")
    }

    func testNormalizeSpaceSeparated() {
        XCTAssertEqual(ContactResolver.normalizePhoneNumber("857 928 8332"), "8579288332")
    }

    func testNormalizeEmptyString() {
        XCTAssertEqual(ContactResolver.normalizePhoneNumber(""), "")
    }

    func testNormalizePreservesLeadingPlus() {
        XCTAssertEqual(ContactResolver.normalizePhoneNumber("+44 20 7946 0958"), "+442079460958")
    }

    // MARK: - looksLikePhoneNumber

    func testLooksLikePhoneE164() {
        XCTAssertTrue(ContactResolver.looksLikePhoneNumber("+18579288332"))
    }

    func testLooksLikePhoneFormatted() {
        XCTAssertTrue(ContactResolver.looksLikePhoneNumber("+1 857-928-8332"))
    }

    func testLooksLikePhoneParentheses() {
        XCTAssertTrue(ContactResolver.looksLikePhoneNumber("(857) 928-8332"))
    }

    func testLooksLikePhoneLocalNumber() {
        XCTAssertTrue(ContactResolver.looksLikePhoneNumber("928-8332"))
    }

    func testDoesNotLookLikePhoneName() {
        XCTAssertFalse(ContactResolver.looksLikePhoneNumber("Alice Smith"))
    }

    func testDoesNotLookLikePhoneEmoji() {
        XCTAssertFalse(ContactResolver.looksLikePhoneNumber("Family 🏠"))
    }

    func testDoesNotLookLikePhoneGroupName() {
        XCTAssertFalse(ContactResolver.looksLikePhoneNumber("Book Club"))
    }

    func testDoesNotLookLikePhoneShortNumber() {
        XCTAssertFalse(ContactResolver.looksLikePhoneNumber("12345"))
    }

    func testDoesNotLookLikePhoneEmpty() {
        XCTAssertFalse(ContactResolver.looksLikePhoneNumber(""))
    }

    func testDoesNotLookLikePhoneMixedAlphaDigits() {
        XCTAssertFalse(ContactResolver.looksLikePhoneNumber("Room 101"))
    }
}
