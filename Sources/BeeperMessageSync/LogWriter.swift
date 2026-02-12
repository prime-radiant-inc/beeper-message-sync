import Foundation

// MARK: - Output record types

struct MessageRecord: Codable {
    let id: String
    let chatId: String
    let network: String
    let chatTitle: String
    let senderId: String?
    let senderName: String?
    let timestamp: String
    let text: String?
    let isSender: Bool
    let type: String?
    let attachments: [AttachmentRecord]
    let replyTo: String?
}

struct AttachmentRecord: Codable {
    let id: String?
    let type: String
    let localPath: String?
    let mimeType: String?
    let fileName: String?
}

// MARK: - LogWriter

class LogWriter {
    let baseDir: String
    private let encoder: JSONEncoder
    private let fm = FileManager.default

    init(baseDir: String) {
        self.baseDir = baseDir
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    func write(record: MessageRecord) throws {
        let dirPath = chatDir(network: record.network, chatTitle: record.chatTitle)
        try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)

        let date = extractDate(from: record.timestamp)
        let filePath = "\(dirPath)/\(date).jsonl"

        let data = try encoder.encode(record)
        let line = data + Data("\n".utf8)

        if fm.fileExists(atPath: filePath) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(line)
        } else {
            try line.write(to: URL(fileURLWithPath: filePath))
        }
    }

    func attachmentDir(network: String, chatTitle: String, date: String) -> String {
        let dir = chatDir(network: network, chatTitle: chatTitle)
        return "\(dir)/\(date)"
    }

    func chatDir(network: String, chatTitle: String) -> String {
        let sanitizedNetwork = sanitize(network).lowercased()
        let sanitizedTitle = sanitize(chatTitle)
        return "\(baseDir)/\(sanitizedNetwork)/\(sanitizedTitle)"
    }

    private func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: illegal).joined(separator: "-")
    }

    private func extractDate(from timestamp: String) -> String {
        // Timestamps are ISO 8601: "2026-02-12T15:30:00Z"
        if let tIndex = timestamp.firstIndex(of: "T") {
            return String(timestamp[timestamp.startIndex..<tIndex])
        }
        return String(timestamp.prefix(10))
    }
}
