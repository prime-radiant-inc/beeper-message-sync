import XCTest
@testable import beeper_message_sync

final class ModelsTests: XCTestCase {
    let decoder = JSONDecoder()

    func testDecodeChatList() throws {
        let json = """
        {
            "items": [
                {
                    "id": "!test:beeper.com",
                    "accountID": "signal",
                    "title": "Alice",
                    "type": "single",
                    "participants": {
                        "items": [
                            {"id": "user1", "fullName": "Alice", "isSelf": false},
                            {"id": "user2", "fullName": "Jesse", "isSelf": true}
                        ],
                        "hasMore": false,
                        "total": 2
                    },
                    "lastActivity": "2026-02-12T15:30:00Z",
                    "unreadCount": 3,
                    "isArchived": false,
                    "isMuted": false,
                    "isPinned": false
                }
            ],
            "hasMore": true
        }
        """.data(using: .utf8)!
        let result = try decoder.decode(ChatListResponse.self, from: json)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].id, "!test:beeper.com")
        XCTAssertEqual(result.items[0].network, "signal")
        XCTAssertEqual(result.items[0].title, "Alice")
        XCTAssertEqual(result.items[0].participants.items.count, 2)
        XCTAssertTrue(result.hasMore)
    }

    func testDecodeMessageList() throws {
        let json = """
        {
            "items": [
                {
                    "id": "msg1",
                    "chatID": "!test:beeper.com",
                    "accountID": "local-signal_ba_abc",
                    "senderID": "user1",
                    "senderName": "Alice",
                    "timestamp": "2026-02-12T15:30:00Z",
                    "sortKey": "0001725489123456",
                    "type": "text",
                    "text": "Hello!",
                    "isSender": false,
                    "attachments": [],
                    "reactions": []
                }
            ],
            "hasMore": false
        }
        """.data(using: .utf8)!
        let result = try decoder.decode(MessageListResponse.self, from: json)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].id, "msg1")
        XCTAssertEqual(result.items[0].text, "Hello!")
        XCTAssertFalse(result.hasMore)
    }

    func testDecodeMessageWithAttachment() throws {
        let json = """
        {
            "items": [
                {
                    "id": "msg2",
                    "chatID": "!test:beeper.com",
                    "accountID": "local-signal_ba_abc",
                    "senderID": "user1",
                    "senderName": "Alice",
                    "timestamp": "2026-02-12T15:31:00Z",
                    "sortKey": "0001725489123457",
                    "type": "media",
                    "isSender": false,
                    "attachments": [
                        {
                            "id": "mxc://beeper.com/abc123",
                            "type": "img",
                            "mimeType": "image/png",
                            "fileName": "photo.png",
                            "fileSize": 12345
                        }
                    ],
                    "reactions": [
                        {"id": "r1", "reactionKey": "\u{1F44D}", "participantID": "user2"}
                    ]
                }
            ],
            "hasMore": false
        }
        """.data(using: .utf8)!
        let result = try decoder.decode(MessageListResponse.self, from: json)
        let msg = result.items[0]
        XCTAssertEqual(msg.attachments?.count, 1)
        XCTAssertEqual(msg.attachments?[0].id, "mxc://beeper.com/abc123")
        XCTAssertEqual(msg.attachments?[0].mimeType, "image/png")
        XCTAssertEqual(msg.reactions?.count, 1)
        XCTAssertEqual(msg.reactions?[0].reactionKey, "\u{1F44D}")
    }

    func testDecodeAssetDownloadResponse() throws {
        let json = """
        {"srcURL": "file:///Users/jesse/Library/Application%20Support/BeeperTexts/media/photo.png"}
        """.data(using: .utf8)!
        let result = try decoder.decode(AssetDownloadResponse.self, from: json)
        XCTAssertEqual(
            result.srcURL,
            "file:///Users/jesse/Library/Application%20Support/BeeperTexts/media/photo.png"
        )
        XCTAssertNil(result.error)
    }
}
