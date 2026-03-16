import Foundation

struct AttachmentFetcher {
    let client: BeeperClient
    let logWriter: LogWriter

    /// Download an attachment via Beeper API, copy to date directory, return relative path
    func fetch(
        attachment: Attachment,
        network: String,
        chatTitle: String,
        date: String
    ) async throws -> String? {
        // If the attachment already has a local file URL, use it directly
        // (common for iMessage attachments stored in ~/Library/Messages/)
        let sourcePath: String
        if let src = attachment.srcURL, src.hasPrefix("file://") {
            sourcePath = Self.parseFileURL(src)
        } else if let src = attachment.srcURL, src.hasPrefix("asset://") {
            // asset:// URLs contain hex-encoded local file paths after the account ID
            if let path = Self.parseAssetURL(src) {
                sourcePath = path
            } else {
                return nil
            }
        } else {
            guard let assetID = attachment.id else { return nil }

            // Ask Beeper to download the asset and give us a local file path
            let response = try await client.downloadAsset(url: assetID)
            guard let srcURL = response.srcURL else {
                if let error = response.error {
                    print("  Warning: attachment download failed: \(error)")
                }
                return nil
            }
            sourcePath = Self.parseFileURL(srcURL)
        }
        let destDir = logWriter.attachmentDir(
            network: network, chatTitle: chatTitle, date: date
        )
        let fileName = attachment.fileName
            ?? URL(fileURLWithPath: sourcePath).lastPathComponent

        let destPath = try Self.copyAttachment(
            from: sourcePath, toDir: destDir, fileName: fileName
        )

        // Return path relative to chat directory
        let chatDir = logWriter.chatDir(network: network, chatTitle: chatTitle)
        if destPath.hasPrefix(chatDir) {
            return String(destPath.dropFirst(chatDir.count + 1))
        }
        return destPath
    }

    /// Parse an asset:// URL with hex-encoded path to a filesystem path
    /// Format: asset://<accountID>/<hex-encoded-path>
    static func parseAssetURL(_ urlString: String) -> String? {
        guard urlString.hasPrefix("asset://") else { return nil }
        let stripped = String(urlString.dropFirst("asset://".count))
        // Path is after the first /
        guard let slashIndex = stripped.firstIndex(of: "/") else { return nil }
        let hexPath = String(stripped[stripped.index(after: slashIndex)...])
        // Decode hex to bytes to string
        var bytes = [UInt8]()
        var chars = hexPath.makeIterator()
        while let hi = chars.next(), let lo = chars.next() {
            guard let byte = UInt8(String([hi, lo]), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Parse a file:// URL to a filesystem path
    static func parseFileURL(_ urlString: String) -> String {
        if urlString.hasPrefix("file://") {
            if let url = URL(string: urlString) {
                return url.path
            }
            // Fallback: strip prefix and decode
            let stripped = String(urlString.dropFirst("file://".count))
            return stripped.removingPercentEncoding ?? stripped
        }
        return urlString
    }

    /// Copy a file to the destination directory, handling name conflicts
    @discardableResult
    static func copyAttachment(
        from sourcePath: String,
        toDir destDir: String,
        fileName: String
    ) throws -> String {
        let fm = FileManager.default
        try createDirectoryWithPOSIX(atPath: destDir)

        var destPath = "\(destDir)/\(fileName)"
        if fm.fileExists(atPath: destPath) {
            // Add numeric suffix to avoid collision
            let name = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            var counter = 1
            repeat {
                let suffixed = ext.isEmpty ? "\(name)-\(counter)" : "\(name)-\(counter).\(ext)"
                destPath = "\(destDir)/\(suffixed)"
                counter += 1
            } while fm.fileExists(atPath: destPath)
        }

        try fm.copyItem(atPath: sourcePath, toPath: destPath)
        return destPath
    }
}
