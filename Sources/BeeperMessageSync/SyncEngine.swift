import Foundation

class SyncEngine {
    let client: BeeperClient
    let logWriter: LogWriter
    let metadataWriter: MetadataWriter
    let attachmentFetcher: AttachmentFetcher
    let stateStore: StateStore
    let contactResolver: ContactResolver
    let config: Config

    init(config: Config, contactResolver: ContactResolver? = nil) {
        self.config = config
        self.client = BeeperClient(
            baseURL: config.beeperURL,
            token: config.beeperToken ?? ""
        )
        self.logWriter = LogWriter(baseDir: config.logDir)
        self.metadataWriter = MetadataWriter()
        self.attachmentFetcher = AttachmentFetcher(
            client: client, logWriter: logWriter
        )
        self.stateStore = StateStore(path: config.stateFile)
        self.contactResolver = contactResolver ?? ContactResolver.load()
    }

    /// Run a single poll cycle: check all chats for new messages
    func pollOnce() async throws {
        var cursor: String? = nil
        var allChats: [Chat] = []

        // Fetch all chats (paginate)
        repeat {
            let response = try await client.listChats(cursor: cursor)
            allChats.append(contentsOf: response.items)
            if response.hasMore, let last = response.items.last {
                cursor = last.lastActivity
            } else {
                break
            }
        } while true

        for chat in allChats {
            let storedActivity = stateStore.lastActivity(for: chat.id)

            // Skip chats that haven't changed since last poll
            if let stored = storedActivity, let current = chat.lastActivity,
               stored == current {
                continue
            }

            try await syncChat(chat)
        }

        try stateStore.save()
    }

    /// Fetch and log new messages for a single chat
    func syncChat(_ chat: Chat) async throws {
        let displayTitle = resolvedTitle(for: chat)

        // Update metadata
        let chatDir = logWriter.chatDir(network: chat.network, chatTitle: displayTitle)
        try FileManager.default.createDirectory(
            atPath: chatDir, withIntermediateDirectories: true
        )
        let metadata = buildMetadata(from: chat, resolvedTitle: displayTitle)
        try metadataWriter.write(metadata: metadata, toDir: chatDir)

        // Fetch messages newer than our last seen sort key
        let lastSortKey = stateStore.lastSortKey(for: chat.id)
        var newMessages: [Message] = []
        var msgCursor: String? = lastSortKey
        let direction: String? = lastSortKey != nil ? "after" : nil

        repeat {
            let response = try await client.listMessages(
                chatID: chat.id,
                cursor: msgCursor,
                direction: direction
            )
            newMessages.append(contentsOf: response.items)
            if response.hasMore, let last = response.items.last?.sortKey {
                msgCursor = last
            } else {
                break
            }
        } while true

        // Filter out already-seen messages and sort by timestamp
        let filtered = newMessages.filter { msg in
            guard let sortKey = msg.sortKey, let last = lastSortKey else { return true }
            return sortKey > last
        }

        // Write messages
        for message in filtered {
            let date = extractDate(from: message.timestamp)

            // Download attachments
            var attachmentRecords: [AttachmentRecord] = []
            for attachment in message.attachments ?? [] {
                do {
                    let localPath = try await attachmentFetcher.fetch(
                        attachment: attachment,
                        network: chat.network,
                        chatTitle: displayTitle,
                        date: date
                    )
                    attachmentRecords.append(AttachmentRecord(
                        id: attachment.id,
                        type: attachment.type,
                        localPath: localPath,
                        mimeType: attachment.mimeType,
                        fileName: attachment.fileName
                    ))
                } catch {
                    print("    WARNING: failed to download attachment \(attachment.id ?? "unknown"): \(error)")
                    attachmentRecords.append(AttachmentRecord(
                        id: attachment.id,
                        type: attachment.type,
                        localPath: nil,
                        mimeType: attachment.mimeType,
                        fileName: attachment.fileName
                    ))
                }
            }

            let record = MessageRecord(
                id: message.id,
                chatId: chat.id,
                network: chat.network,
                chatTitle: displayTitle,
                senderId: message.senderID,
                senderName: message.senderName,
                timestamp: message.timestamp,
                text: message.text,
                isSender: message.isSender ?? false,
                type: message.type,
                attachments: attachmentRecords,
                replyTo: message.linkedMessageID
            )
            try logWriter.write(record: record)
        }

        // Update state
        if let lastMsg = filtered.last {
            stateStore.update(
                chatID: chat.id,
                lastSortKey: lastMsg.sortKey,
                lastActivity: chat.lastActivity
            )
        } else if let activity = chat.lastActivity {
            stateStore.update(
                chatID: chat.id,
                lastSortKey: nil,
                lastActivity: activity
            )
        }
    }

    /// Full backfill: paginate backward through all messages in a chat
    @discardableResult
    func backfillChat(_ chat: Chat) async throws -> Int {
        let displayTitle = resolvedTitle(for: chat)

        let chatDir = logWriter.chatDir(network: chat.network, chatTitle: displayTitle)
        try FileManager.default.createDirectory(
            atPath: chatDir, withIntermediateDirectories: true
        )
        let metadata = buildMetadata(from: chat, resolvedTitle: displayTitle)
        try metadataWriter.write(metadata: metadata, toDir: chatDir)

        var allMessages: [Message] = []
        var cursor: String? = nil

        // Paginate backward (default direction) to get all history
        repeat {
            let response = try await client.listMessages(
                chatID: chat.id,
                cursor: cursor,
                direction: cursor != nil ? "before" : nil
            )
            allMessages.append(contentsOf: response.items)
            if response.hasMore, let last = response.items.last?.sortKey {
                cursor = last
            } else {
                break
            }
        } while true

        // Sort chronologically and write
        let sorted = allMessages.sorted { ($0.sortKey ?? "") < ($1.sortKey ?? "") }
        for message in sorted {
            let date = extractDate(from: message.timestamp)
            var attachmentRecords: [AttachmentRecord] = []
            for attachment in message.attachments ?? [] {
                do {
                    let localPath = try await attachmentFetcher.fetch(
                        attachment: attachment,
                        network: chat.network,
                        chatTitle: displayTitle,
                        date: date
                    )
                    attachmentRecords.append(AttachmentRecord(
                        id: attachment.id,
                        type: attachment.type,
                        localPath: localPath,
                        mimeType: attachment.mimeType,
                        fileName: attachment.fileName
                    ))
                } catch {
                    print("    WARNING: failed to download attachment \(attachment.id ?? "unknown"): \(error)")
                    attachmentRecords.append(AttachmentRecord(
                        id: attachment.id,
                        type: attachment.type,
                        localPath: nil,
                        mimeType: attachment.mimeType,
                        fileName: attachment.fileName
                    ))
                }
            }

            let record = MessageRecord(
                id: message.id,
                chatId: chat.id,
                network: chat.network,
                chatTitle: displayTitle,
                senderId: message.senderID,
                senderName: message.senderName,
                timestamp: message.timestamp,
                text: message.text,
                isSender: message.isSender ?? false,
                type: message.type,
                attachments: attachmentRecords,
                replyTo: message.linkedMessageID
            )
            try logWriter.write(record: record)
        }

        // Update state to latest message
        if let lastMsg = sorted.last {
            stateStore.update(
                chatID: chat.id,
                lastSortKey: lastMsg.sortKey,
                lastActivity: chat.lastActivity
            )
            try stateStore.save()
        }

        return sorted.count
    }

    // MARK: - Helpers

    /// Resolve chat title to contact name(s) for iMessage phone-number titles
    func resolvedTitle(for chat: Chat) -> String {
        let isIMessage = chat.network.lowercased().contains("imessage")
        guard isIMessage else { return chat.title }

        // Single chat: title is the phone number
        if chat.type == "single" && ContactResolver.looksLikePhoneNumber(chat.title) {
            if let name = contactResolver.resolve(chat.title) {
                return name
            }
        }

        // Group chat: title may be comma-separated phone numbers
        if chat.type == "group" && ContactResolver.looksLikePhoneNumber(chat.title) {
            let nonSelfParticipants = chat.participants.items.filter { !($0.isSelf ?? false) }
            let resolvedNames = nonSelfParticipants.compactMap { user -> String? in
                guard let phone = user.phoneNumber else { return user.fullName ?? user.username }
                return contactResolver.resolve(phone) ?? user.fullName ?? user.username ?? phone
            }
            if !resolvedNames.isEmpty {
                return resolvedNames.joined(separator: ", ")
            }
        }

        return chat.title
    }

    private func buildMetadata(from chat: Chat, resolvedTitle: String) -> ChatMetadata {
        let now = ISO8601DateFormatter().string(from: Date())
        let resolved = resolvedTitle != chat.title ? resolvedTitle : nil
        return ChatMetadata(
            chatId: chat.id,
            accountId: chat.accountID,
            network: chat.network,
            title: chat.title,
            resolvedTitle: resolved,
            type: chat.type,
            participants: chat.participants.items.map { user in
                ParticipantInfo(
                    id: user.id,
                    name: user.fullName ?? user.username,
                    phone: user.phoneNumber,
                    isSelf: user.isSelf ?? false
                )
            },
            firstSeen: now,
            lastUpdated: now
        )
    }

    private func extractDate(from timestamp: String) -> String {
        if let tIndex = timestamp.firstIndex(of: "T") {
            return String(timestamp[timestamp.startIndex..<tIndex])
        }
        return String(timestamp.prefix(10))
    }
}
