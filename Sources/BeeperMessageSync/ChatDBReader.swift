import Foundation
import SQLite3

/// Reads iMessage history directly from ~/Library/Messages/chat.db
struct ChatDBReader {
    let dbPath: String

    /// Apple's Core Data epoch: 2001-01-01 00:00:00 UTC
    private static let appleEpochOffset: TimeInterval = 978307200

    struct ChatDBChat {
        let rowID: Int
        let chatIdentifier: String
        let displayName: String?
        let serviceName: String
        let participantIDs: [String]
        let messageCount: Int
    }

    struct ChatDBMessage {
        let guid: String
        let text: String?
        let isFromMe: Bool
        let senderID: String?
        let timestamp: String  // ISO 8601
        let attachments: [ChatDBAttachment]
        let replyToGuid: String?
        let isReaction: Bool
    }

    struct ChatDBAttachment {
        let filename: String?
        let mimeType: String?
        let transferName: String?
    }

    init(dbPath: String? = nil) {
        self.dbPath = dbPath ?? NSHomeDirectory() + "/Library/Messages/chat.db"
    }

    /// List all iMessage chats with participant info and message counts
    func listChats() throws -> [ChatDBChat] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = """
            SELECT c.ROWID, c.chat_identifier, c.display_name, c.service_name,
                   (SELECT COUNT(*) FROM chat_message_join WHERE chat_id = c.ROWID) as msg_count
            FROM chat c
            ORDER BY c.ROWID
            """
        var chats: [ChatDBChat] = []
        try query(db, sql: sql) { stmt in
            let rowID = Int(sqlite3_column_int64(stmt, 0))
            let chatIdentifier = string(stmt, col: 1) ?? ""
            let displayName = string(stmt, col: 2).flatMap { $0.isEmpty ? nil : $0 }
            let serviceName = string(stmt, col: 3) ?? "iMessage"
            let messageCount = Int(sqlite3_column_int(stmt, 4))

            // Get participants
            let participants = try getParticipants(db, chatID: rowID)

            chats.append(ChatDBChat(
                rowID: rowID,
                chatIdentifier: chatIdentifier,
                displayName: displayName,
                serviceName: serviceName,
                participantIDs: participants,
                messageCount: messageCount
            ))
        }
        return chats
    }

    /// Get all messages for a chat, ordered chronologically
    func listMessages(chatRowID: Int) throws -> [ChatDBMessage] {
        let db = try openDB()
        defer { sqlite3_close(db) }

        let sql = """
            SELECT m.guid, m.text, m.is_from_me, h.id,
                   m.date, m.cache_has_attachments,
                   m.reply_to_guid, m.associated_message_type,
                   m.attributedBody
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id = ?
            ORDER BY m.date ASC
            """
        var messages: [ChatDBMessage] = []
        try query(db, sql: sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(chatRowID))
        }) { stmt in
            let guid = string(stmt, col: 0) ?? ""
            var text = string(stmt, col: 1)
            let isFromMe = sqlite3_column_int(stmt, 2) == 1
            let senderID = string(stmt, col: 3)
            let dateNano = sqlite3_column_int64(stmt, 4)
            let hasAttachments = sqlite3_column_int(stmt, 5) == 1
            let replyToGuid = string(stmt, col: 6)
            let associatedType = sqlite3_column_int(stmt, 7)

            // Skip reactions, tapbacks, and other associated messages
            if associatedType != 0 { return }

            // Extract text from attributedBody when text column is NULL
            if text == nil, let blobPtr = sqlite3_column_blob(stmt, 8) {
                let blobLen = Int(sqlite3_column_bytes(stmt, 8))
                let data = Data(bytes: blobPtr, count: blobLen)
                text = Self.extractTextFromAttributedBody(data)
            }

            // Skip empty messages with no text and no attachments
            if text == nil && !hasAttachments { return }

            let timestamp = Self.formatDate(dateNano)

            var attachments: [ChatDBAttachment] = []
            if hasAttachments {
                attachments = (try? getAttachments(db, messageGuid: guid)) ?? []
            }

            messages.append(ChatDBMessage(
                guid: guid,
                text: text,
                isFromMe: isFromMe,
                senderID: isFromMe ? nil : senderID,
                timestamp: timestamp,
                attachments: attachments,
                replyToGuid: replyToGuid,
                isReaction: false
            ))
        }
        return messages
    }

    // MARK: - Helpers

    private func getParticipants(_ db: OpaquePointer, chatID: Int) throws -> [String] {
        let sql = """
            SELECT h.id FROM handle h
            JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
            WHERE chj.chat_id = ?
            """
        var participants: [String] = []
        try query(db, sql: sql, bind: { stmt in
            sqlite3_bind_int64(stmt, 1, Int64(chatID))
        }) { stmt in
            if let id = string(stmt, col: 0) {
                participants.append(id)
            }
        }
        return participants
    }

    private func getAttachments(_ db: OpaquePointer, messageGuid: String) throws -> [ChatDBAttachment] {
        let sql = """
            SELECT a.filename, a.mime_type, a.transfer_name
            FROM attachment a
            JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
            JOIN message m ON m.ROWID = maj.message_id
            WHERE m.guid = ?
            """
        var attachments: [ChatDBAttachment] = []
        try query(db, sql: sql, bind: { stmt in
            sqlite3_bind_text(stmt, 1, messageGuid, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }) { stmt in
            let filename = string(stmt, col: 0)
            let mimeType = string(stmt, col: 1)
            let transferName = string(stmt, col: 2)

            // Skip plugin payload attachments (invisible to users)
            if let name = transferName ?? filename,
               name.hasSuffix(".pluginPayloadAttachment") {
                return
            }

            attachments.append(ChatDBAttachment(
                filename: filename,
                mimeType: mimeType,
                transferName: transferName
            ))
        }
        return attachments
    }

    static func formatDate(_ appleNanoseconds: Int64) -> String {
        let seconds = Double(appleNanoseconds) / 1_000_000_000.0 + appleEpochOffset
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Extract plain text from a typedstream-encoded NSAttributedString blob.
    /// Uses the deprecated NSUnarchiver because the blob is in typedstream format,
    /// not NSKeyedArchiver's plist format.
    static func extractTextFromAttributedBody(_ data: Data) -> String? {
        let unarchiver = NSUnarchiver(forReadingWith: data)
        guard let attrStr = unarchiver?.decodeObject() as? NSAttributedString else {
            return nil
        }
        let text = attrStr.string
        return text.isEmpty ? nil : text
    }

    // MARK: - SQLite helpers

    private func openDB() throws -> OpaquePointer {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let db else {
            throw ChatDBError.openFailed(path: dbPath)
        }
        return db
    }

    private func query(
        _ db: OpaquePointer,
        sql: String,
        bind: ((OpaquePointer) -> Void)? = nil,
        row: (OpaquePointer) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let err = String(cString: sqlite3_errmsg(db))
            throw ChatDBError.queryFailed(sql: sql, error: err)
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt!)
        while sqlite3_step(stmt) == SQLITE_ROW {
            try row(stmt!)
        }
    }

    private func string(_ stmt: OpaquePointer, col: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: cStr)
    }
}

enum ChatDBError: Error, LocalizedError {
    case openFailed(path: String)
    case queryFailed(sql: String, error: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path):
            return "Failed to open Messages database at \(path)"
        case .queryFailed(let sql, let error):
            return "Query failed: \(error) (SQL: \(sql.prefix(80)))"
        }
    }
}
