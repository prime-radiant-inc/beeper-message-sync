import Foundation

// MARK: - Output record types

struct Sender: Codable {
    let id: String?
    let name: String?
    let `self`: Bool?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(name, forKey: .name)
        // Only encode self when true
        if self.`self` == true {
            try container.encode(true, forKey: .`self`)
        }
    }
}

struct MessageRecord: Encodable {
    let id: String
    let ts: String
    let from: Sender
    let text: String?
    let type: String?
    let attachments: [AttachmentRecord]
    let replyTo: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(ts, forKey: .ts)
        try container.encode(from, forKey: .from)
        try container.encodeIfPresent(text, forKey: .text)
        // Omit type when "TEXT" (the common case)
        if let type, type.uppercased() != "TEXT" {
            try container.encode(type, forKey: .type)
        }
        // Omit attachments when empty
        if !attachments.isEmpty {
            try container.encode(attachments, forKey: .attachments)
        }
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
    }

    enum CodingKeys: String, CodingKey {
        case id, ts, from, text, type, attachments, replyTo
    }
}

struct AttachmentRecord: Codable {
    let id: String?
    let type: String
    let localPath: String?
    let mimeType: String?
    let fileName: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(localPath, forKey: .localPath)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(fileName, forKey: .fileName)
    }
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

    func write(record: MessageRecord, toDir dirPath: String) throws {
        try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)

        let date = extractDate(from: record.ts)
        let filePath = "\(dirPath)/\(date).jsonl"

        let data = try encoder.encode(record)
        let line = data + Data("\n".utf8)

        if fm.fileExists(atPath: filePath) {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: filePath))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
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
        // Percent-encode only characters illegal in filenames across macOS/Windows/Dropbox
        let illegal: [Character: String] = [
            "/": "%2F", "\\": "%5C", ":": "%3A", "*": "%2A",
            "?": "%3F", "\"": "%22", "<": "%3C", ">": "%3E", "|": "%7C",
            "&": "%26", "#": "%23",
        ]
        var result = ""
        for char in name {
            if let encoded = illegal[char] {
                result += encoded
            } else if char.asciiValue != nil && char.asciiValue! < 32 {
                // Encode control characters
                result += String(format: "%%%02X", char.asciiValue!)
            } else {
                result.append(char)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func extractDate(from timestamp: String) -> String {
        // Timestamps are ISO 8601: "2026-02-12T15:30:00Z"
        if let tIndex = timestamp.firstIndex(of: "T") {
            return String(timestamp[timestamp.startIndex..<tIndex])
        }
        return String(timestamp.prefix(10))
    }
}
