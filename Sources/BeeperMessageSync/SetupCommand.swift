import Foundation

enum SetupCommand {
    static func run() {
        print("beeper-message-sync setup")
        print("========================\n")

        // Load existing config if present
        let existingConfig = Config.load()

        // Token
        let existingToken = KeychainHelper.loadToken()
        if existingToken != nil {
            print("A Beeper token is already stored in the Keychain.")
            let replace = prompt("Replace it? [y/N]: ")
            if replace.lowercased() == "y" {
                let token = promptHidden("Beeper token: ")
                guard !token.isEmpty else {
                    print("Error: token cannot be empty.")
                    return
                }
                KeychainHelper.saveToken(token)
                print("Token saved to Keychain.")
            }
        } else {
            let token = promptHidden("Beeper token: ")
            guard !token.isEmpty else {
                print("Error: token cannot be empty.")
                return
            }
            KeychainHelper.saveToken(token)
            print("Token saved to Keychain.")
        }

        // Log directory
        let logDir = prompt(
            "Log directory [\(existingConfig.logDir)]: ",
            default: existingConfig.logDir
        )

        // Create log directory if needed
        let expandedLogDir = NSString(string: logDir).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: expandedLogDir) {
            do {
                try FileManager.default.createDirectory(
                    atPath: expandedLogDir,
                    withIntermediateDirectories: true
                )
                print("Created \(expandedLogDir)")
            } catch {
                print("Warning: could not create \(expandedLogDir): \(error.localizedDescription)")
            }
        }

        // State file
        let stateFile = prompt(
            "State file [\(existingConfig.stateFile)]: ",
            default: existingConfig.stateFile
        )

        // Write config
        do {
            try writeConfigFile(
                beeperURL: existingConfig.beeperURL,
                logDir: logDir,
                stateFile: stateFile,
                pollInterval: existingConfig.pollInterval,
                to: Config.defaultConfigPath
            )
            print("\nConfig written to \(Config.defaultConfigPath)")
        } catch {
            print("Error writing config: \(error.localizedDescription)")
            return
        }

        print("\nSetup complete. Run `brew services start beeper-message-sync` to start syncing.")
    }

    static func writeConfigFile(
        beeperURL: String,
        logDir: String,
        stateFile: String,
        pollInterval: Int,
        to path: String
    ) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        let config: [String: Any] = [
            "beeperURL": beeperURL,
            "logDir": logDir,
            "stateFile": stateFile,
            "pollInterval": pollInterval,
        ]

        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - Interactive prompts

    private static func prompt(_ message: String, default defaultValue: String? = nil) -> String {
        print(message, terminator: "")
        guard let line = readLine(), !line.isEmpty else {
            return defaultValue ?? ""
        }
        return line
    }

    private static func promptHidden(_ message: String) -> String {
        print(message, terminator: "")

        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)
        var newTermios = oldTermios
        newTermios.c_lflag &= ~UInt(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)

        let input = readLine() ?? ""

        tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
        print()

        return input
    }
}
