import Foundation

class SyncEngine {
    let client: BeeperClient
    let logWriter: LogWriter
    let metadataWriter: MetadataWriter
    let attachmentFetcher: AttachmentFetcher
    let stateStore: StateStore
    let contactResolver: ContactResolver
    let filter: SyncFilter
    let config: Config

    init(config: Config, filter: SyncFilter = SyncFilter(), contactResolver: ContactResolver? = nil) {
        self.config = config
        self.filter = filter
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
        var seenIDs = Set<String>()

        // Fetch all chats (paginate, dedup overlapping pages)
        repeat {
            let response = try await client.listChats(cursor: cursor)
            for chat in response.items {
                if seenIDs.insert(chat.id).inserted {
                    allChats.append(chat)
                }
            }
            if response.hasMore, let nextCursor = response.oldestCursor {
                cursor = nextCursor
            } else {
                break
            }
        } while true

        for chat in allChats {
            // Skip chats that don't match the filter
            let resolved = resolvedTitle(for: chat)
            if !filter.matchesChat(chat, resolvedTitle: resolved) {
                continue
            }

            let storedActivity = stateStore.lastActivity(for: chat.id)

            // Skip chats that haven't changed since last poll
            if let stored = storedActivity, let current = chat.lastActivity,
               stored == current {
                continue
            }

            do {
                try await syncChat(chat)
            } catch {
                print("  Error syncing \(chat.title): \(error) [\(error as NSError)]")
            }
        }

        try stateStore.save()
    }

    /// Fetch and log new messages for a single chat
    func syncChat(_ chat: Chat) async throws {
        let displayTitle = resolvedTitle(for: chat)

        let chatDir = logWriter.chatDir(network: chat.network, chatTitle: displayTitle)
        try createDirectoryWithPOSIX(atPath: chatDir)

        // Metadata is supplementary — don't let write failures block message sync
        do {
            let metadata = buildMetadata(from: chat, resolvedTitle: displayTitle)
            try metadataWriter.write(metadata: metadata, toDir: chatDir)
        } catch {
            print("  WARNING: failed to write metadata for \(displayTitle): \(error)")
        }

        // Fetch messages newer than our last seen sort key by paginating
        // backward from the newest message until we reach lastSortKey.
        // The Beeper API always returns results in descending order,
        // so we use direction=before for pagination (not direction=after,
        // which causes an overlapping-page infinite loop).
        let lastSortKey = stateStore.lastSortKey(for: chat.id)
        var newMessages: [Message] = []
        var msgCursor: String? = nil
        var reachedStoredState = false

        repeat {
            let response = try await client.listMessages(
                chatID: chat.id,
                cursor: msgCursor,
                direction: msgCursor != nil ? "before" : nil
            )

            for message in response.items {
                if let sortKey = message.sortKey, let last = lastSortKey, sortKey <= last {
                    reachedStoredState = true
                    break
                }
                newMessages.append(message)
            }

            if reachedStoredState || !response.hasMore {
                break
            }
            if let last = response.items.last?.sortKey {
                msgCursor = last
            } else {
                break
            }
        } while true

        // Sort chronologically (API returns newest-first)
        let sorted = newMessages.sorted { ($0.sortKey ?? "") < ($1.sortKey ?? "") }

        // Apply date filter and write messages
        let dateFiltered = sorted.filter { filter.matchesTimestamp($0.timestamp) }
        for message in dateFiltered {
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
                ts: message.timestamp,
                from: Sender(
                    id: message.senderID,
                    name: message.senderName,
                    self: message.isSender
                ),
                text: message.text,
                type: message.type,
                attachments: attachmentRecords,
                replyTo: message.linkedMessageID
            )
            try logWriter.write(record: record, toDir: chatDir)
        }

        // Update state — use the last message from the full sorted set
        // (not dateFiltered) so we don't re-fetch messages we skipped
        if let lastMsg = sorted.last {
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
        try createDirectoryWithPOSIX(atPath: chatDir)

        // Metadata is supplementary — don't let write failures block message sync
        do {
            let metadata = buildMetadata(from: chat, resolvedTitle: displayTitle)
            try metadataWriter.write(metadata: metadata, toDir: chatDir)
        } catch {
            print("  WARNING: failed to write metadata for \(displayTitle): \(error)")
        }

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

            // Stop paginating if all messages in this page are before our since cutoff
            if filter.since != nil,
               !response.items.isEmpty,
               response.items.allSatisfy({ !filter.matchesTimestamp($0.timestamp) }) {
                break
            }

            if response.hasMore, let last = response.items.last?.sortKey {
                cursor = last
            } else {
                break
            }
        } while true

        // Sort chronologically, apply date filter, and write
        let sorted = allMessages
            .sorted { ($0.sortKey ?? "") < ($1.sortKey ?? "") }
            .filter { filter.matchesTimestamp($0.timestamp) }
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
                ts: message.timestamp,
                from: Sender(
                    id: message.senderID,
                    name: message.senderName,
                    self: message.isSender
                ),
                text: message.text,
                type: message.type,
                attachments: attachmentRecords,
                replyTo: message.linkedMessageID
            )
            try logWriter.write(record: record, toDir: chatDir)
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

        // Group chat: resolve participant phone numbers to names.
        // Skip if the group already has a meaningful name (not just phone numbers).
        // Title formats vary: "+1 617-571-3000, +1 617-817-6446 & 2 others"
        // but participant phones are "+16175713000". Compare by normalizing
        // the title's digit sequences against participant phone suffixes.
        if chat.type == "group" {
            let nonSelfParticipants = chat.participants.items.filter { !($0.isSelf ?? false) }
            let hasPhoneParticipants = nonSelfParticipants.contains { $0.phoneNumber != nil }
            let titleDigits = chat.title.filter(\.isNumber)
            let titleIsPhoneNumbers = hasPhoneParticipants && nonSelfParticipants.contains {
                guard let phone = $0.phoneNumber else { return false }
                let phoneDigits = phone.filter(\.isNumber)
                guard phoneDigits.count >= 7 else { return false }
                return titleDigits.contains(phoneDigits)
            }
            if titleIsPhoneNumbers {
                let resolvedNames = nonSelfParticipants.compactMap { user -> String? in
                    guard let phone = user.phoneNumber else { return user.fullName ?? user.username }
                    return contactResolver.resolve(phone) ?? user.fullName ?? user.username ?? phone
                }
                if !resolvedNames.isEmpty {
                    return resolvedNames.joined(separator: ", ")
                }
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
