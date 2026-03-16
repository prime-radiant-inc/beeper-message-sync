import Foundation

enum FileIOError: Error, LocalizedError {
    case openFailed(path: String, errno: Int32)
    case writeFailed(path: String, errno: Int32)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path, let errno):
            return "Failed to open \(path): \(String(cString: strerror(errno)))"
        case .writeFailed(let path, let errno):
            return "Failed to write \(path): \(String(cString: strerror(errno)))"
        }
    }
}

/// Create directory and all intermediate directories using POSIX mkdir,
/// bypassing Foundation's NSFileCoordinator.
func createDirectoryWithPOSIX(atPath path: String) throws {
    var builtPath = ""
    for component in path.split(separator: "/") {
        builtPath += "/\(component)"
        let result = mkdir(builtPath, 0o755)
        if result != 0 && errno != EEXIST {
            throw FileIOError.openFailed(path: builtPath, errno: errno)
        }
    }
}

/// Write data to a file using POSIX APIs, bypassing Foundation's
/// NSFileCoordinator which deadlocks with Dropbox's File Provider (EDEADLK).
func writeDataToPath(_ data: Data, path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else {
        throw FileIOError.openFailed(path: path, errno: errno)
    }
    defer { close(fd) }
    try writeToFD(fd, data: data, path: path)
}

/// Append data to a file using POSIX APIs.
func appendDataToPath(_ data: Data, path: String) throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else {
        throw FileIOError.openFailed(path: path, errno: errno)
    }
    defer { close(fd) }
    try writeToFD(fd, data: data, path: path)
}

private func writeToFD(_ fd: Int32, data: Data, path: String) throws {
    try data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        let written = write(fd, baseAddress, bytes.count)
        if written < 0 {
            throw FileIOError.writeFailed(path: path, errno: errno)
        }
    }
}
