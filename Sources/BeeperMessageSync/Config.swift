import Foundation

struct Config {
    let beeperToken: String?
    let beeperURL: String
    let logDir: String
    let pollInterval: Int
    let stateFile: String

    static let defaultConfigPath = NSHomeDirectory()
        + "/.config/beeper-message-sync/config.json"

    static func load(
        configPath: String = defaultConfigPath,
        keychainService: String = KeychainHelper.defaultService,
        environment: [String: String]? = nil
    ) -> Config {
        // 1. Start with defaults + Keychain token
        var token: String? = KeychainHelper.loadToken(service: keychainService)
        var url = "http://localhost:23373"
        var logDir = NSHomeDirectory() + "/Dropbox/Beeper-Sync/logs"
        var pollInterval = 5
        var stateFile = NSHomeDirectory() + "/Dropbox/Beeper-Sync/state.json"

        // 2. Override from config file
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let v = json["beeperURL"] as? String { url = v }
            if let v = json["logDir"] as? String {
                logDir = NSString(string: v).expandingTildeInPath
            }
            if let v = json["stateFile"] as? String {
                stateFile = NSString(string: v).expandingTildeInPath
            }
            if let v = json["pollInterval"] as? Int { pollInterval = v }
        }

        // 3. Override from environment
        let env = environment ?? ProcessInfo.processInfo.environment
        if let v = env["BEEPER_TOKEN"] { token = v }
        if let v = env["BEEPER_URL"] { url = v }
        if let v = env["LOG_DIR"] { logDir = v }
        if let v = env["POLL_INTERVAL"], let i = Int(v) { pollInterval = i }
        if let v = env["STATE_FILE"] { stateFile = v }

        return Config(beeperToken: token, beeperURL: url, logDir: logDir,
                      pollInterval: pollInterval, stateFile: stateFile)
    }
}
