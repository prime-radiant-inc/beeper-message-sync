import Foundation

// MARK: - Chat types

struct ChatListResponse: Codable {
    let items: [Chat]
    let hasMore: Bool
    let oldestCursor: String?
    let newestCursor: String?
}

struct Chat: Codable {
    let id: String
    let localChatID: String?
    let accountID: String
    let title: String
    let type: String
    let participants: Participants
    let lastActivity: String?
    let unreadCount: Int?
    let isArchived: Bool?
    let isMuted: Bool?
    let isPinned: Bool?
    let preview: Message?

    /// The Beeper API uses accountID as the network identifier
    var network: String { accountID }
}

struct Participants: Codable {
    let items: [User]
    let hasMore: Bool
    let total: Int
}

struct User: Codable {
    let id: String
    let username: String?
    let phoneNumber: String?
    let email: String?
    let fullName: String?
    let imgURL: String?
    let cannotMessage: Bool?
    let isSelf: Bool?
}

// MARK: - Message types

struct MessageListResponse: Codable {
    let items: [Message]
    let hasMore: Bool
    let oldestCursor: String?
    let newestCursor: String?
}

struct Message: Codable {
    let id: String
    let chatID: String
    let accountID: String
    let senderID: String?
    let senderName: String?
    let timestamp: String
    let sortKey: String?
    let type: String?
    let text: String?
    let isSender: Bool?
    let attachments: [Attachment]?
    let isUnread: Bool?
    let linkedMessageID: String?
    let reactions: [Reaction]?
}

struct Attachment: Codable {
    let id: String?
    let type: String
    let srcURL: String?
    let mimeType: String?
    let fileName: String?
    let fileSize: Int?
    let isGif: Bool?
    let isSticker: Bool?
    let isVoiceNote: Bool?
    let duration: Double?
}

struct Reaction: Codable {
    let id: String
    let reactionKey: String
    let participantID: String
    let emoji: Bool?
}

// MARK: - Asset download

struct AssetDownloadRequest: Codable {
    let url: String
}

struct AssetDownloadResponse: Codable {
    let srcURL: String?
    let error: String?
}

// MARK: - Account types

struct Account: Codable {
    let accountID: String
    let network: String
    let user: User
}
