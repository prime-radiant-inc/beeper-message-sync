import Foundation

struct Config {
    let beeperToken: String?
    let beeperURL: String
    let logDir: String
    let pollInterval: Int
    let stateFile: String

    init(env: [String: String]) {
        self.beeperToken = env["BEEPER_TOKEN"]
        self.beeperURL = env["BEEPER_URL"] ?? "http://localhost:23373"
        self.logDir = env["LOG_DIR"]
            ?? NSHomeDirectory() + "/Dropbox/Beeper-Sync/logs"
        self.pollInterval = Int(env["POLL_INTERVAL"] ?? "") ?? 5
        self.stateFile = env["STATE_FILE"]
            ?? NSHomeDirectory() + "/Dropbox/Beeper-Sync/state.json"
    }

    static func load(from dotEnvPath: String) -> Config {
        var env: [String: String] = [:]
        if let contents = try? String(contentsOfFile: dotEnvPath, encoding: .utf8) {
            for line in contents.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                env[key] = value
            }
        }
        // Environment variables override .env file
        for (key, value) in ProcessInfo.processInfo.environment {
            env[key] = value
        }
        return Config(env: env)
    }
}
