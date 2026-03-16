import Foundation

// MARK: - Metadata types

struct ChatMetadata: Codable {
    let chatId: String
    let accountId: String
    let network: String
    let title: String
    let resolvedTitle: String?
    let type: String
    let participants: [ParticipantInfo]
    let firstSeen: String
    let lastUpdated: String
}

struct ParticipantInfo: Codable {
    let id: String
    let name: String?
    let phone: String?
    let isSelf: Bool
}

// MARK: - MetadataWriter

struct MetadataWriter {
    private let encoder: JSONEncoder

    init() {
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func write(metadata: ChatMetadata, toDir dir: String) throws {
        do {
            try writeOnce(metadata: metadata, toDir: dir)
        } catch {
            // Single retry — transient Dropbox file locks resolve quickly
            try writeOnce(metadata: metadata, toDir: dir)
        }
    }

    private func writeOnce(metadata: ChatMetadata, toDir dir: String) throws {
        let path = "\(dir)/metadata.json"

        // Preserve firstSeen from existing file if it exists
        var finalMetadata = metadata
        if let existingData = FileManager.default.contents(atPath: path),
           let existing = try? JSONDecoder().decode(ChatMetadata.self, from: existingData) {
            finalMetadata = ChatMetadata(
                chatId: metadata.chatId,
                accountId: metadata.accountId,
                network: metadata.network,
                title: metadata.title,
                resolvedTitle: metadata.resolvedTitle,
                type: metadata.type,
                participants: metadata.participants,
                firstSeen: existing.firstSeen,
                lastUpdated: metadata.lastUpdated
            )
        }

        let data = try encoder.encode(finalMetadata)
        try data.write(to: URL(fileURLWithPath: path))
    }
}
