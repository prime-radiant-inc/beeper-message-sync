import Foundation

struct SyncFilter: Sendable {
    let networks: Set<String>?
    let chatTitles: Set<String>?
    let since: Date?
    let until: Date?

    init(
        networks: (any Sequence<String>)? = nil,
        chatTitles: (any Sequence<String>)? = nil,
        since: Date? = nil,
        until: Date? = nil
    ) {
        self.networks = networks.map { Set($0.map { $0.lowercased() }) }
        self.chatTitles = chatTitles.map { Set($0.map { $0.lowercased() }) }
        self.since = since
        self.until = until
    }

    /// Check if a chat matches the network and title filters.
    /// When resolvedTitle is provided, title matching checks both raw and resolved titles.
    func matchesChat(_ chat: Chat, resolvedTitle: String? = nil) -> Bool {
        if let networks {
            guard networks.contains(chat.network.lowercased()) else { return false }
        }
        if let chatTitles {
            let rawLower = chat.title.lowercased()
            let resolvedLower = resolvedTitle?.lowercased()
            let matchesRaw = chatTitles.contains(where: { rawLower.contains($0) })
            let matchesResolved = resolvedLower.map { resolved in
                chatTitles.contains(where: { resolved.contains($0) })
            } ?? false
            guard matchesRaw || matchesResolved else { return false }
        }
        return true
    }

    /// Check if a timestamp falls within the since/until bounds
    func matchesTimestamp(_ timestamp: String) -> Bool {
        guard let date = parseTimestamp(timestamp) else { return false }
        if let since, date < since { return false }
        if let until, date >= until { return false }
        return true
    }

    private func parseTimestamp(_ timestamp: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }
}
