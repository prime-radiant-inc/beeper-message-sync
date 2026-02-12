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
        guard let assetID = attachment.id else { return nil }

        // Ask Beeper to download the asset and give us a local file path
        let response = try await client.downloadAsset(url: assetID)
        guard let srcURL = response.srcURL else {
            if let error = response.error {
                print("  Warning: attachment download failed: \(error)")
            }
            return nil
        }

        let sourcePath = Self.parseFileURL(srcURL)
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
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

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
