import Contacts
import Foundation

enum SetupCommand {
    private static let beeperDefaultURL = "http://localhost:23373"

    static func run() {
        print("beeper-message-sync setup")
        print("========================\n")

        // Step 1: Check Beeper Desktop is running
        print("Step 1: Checking Beeper Desktop...")
        let beeperURL = checkBeeperRunning()
        guard let beeperURL else { return }
        print("  Beeper Desktop is running at \(beeperURL)\n")

        // Step 2: Token
        print("Step 2: API token")
        let token = obtainToken(beeperURL: beeperURL)
        guard let token else { return }

        // Step 3: Log directory
        let existingConfig = Config.load()
        print("\nStep 3: Where should message logs be stored?")
        let logDir = prompt(
            "  Log directory [\(existingConfig.logDir)]: ",
            default: existingConfig.logDir
        )
        createDirectoryIfNeeded(logDir)

        // Step 4: State file
        print("\nStep 4: Where should sync state be stored?")
        print("  (This tracks which messages have been synced.)")
        let stateFile = prompt(
            "  State file [\(existingConfig.stateFile)]: ",
            default: existingConfig.stateFile
        )

        // Write config
        do {
            try writeConfigFile(
                beeperURL: beeperURL,
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

        // Save token to Keychain, unlocking if necessary
        if !saveTokenToKeychain(token) {
            return
        }

        // Step 5: Contacts access (optional, for iMessage name resolution)
        offerContactsAccess()

        print("\nSetup complete! To start syncing:")
        print("  brew services start beeper-message-sync")
        print("")
        print("Or run manually:")
        print("  beeper-message-sync          # watch mode (continuous sync)")
        print("  beeper-message-sync backfill  # one-time full history download")
    }

    // MARK: - Setup steps

    /// Check that Beeper Desktop is running and has the API enabled.
    /// Returns the base URL on success, nil on failure.
    private static func checkBeeperRunning() -> String? {
        if let info = fetchBeeperInfo(url: beeperDefaultURL) {
            return info
        }

        print("""
          Beeper Desktop doesn't appear to be running, or the API isn't enabled.

          To fix this:
            1. Download Beeper Desktop from https://www.beeper.com/download
            2. Open Beeper Desktop and sign in
            3. Go to Settings → Developers
            4. Enable "Beeper Desktop API"

          Then re-run: beeper-message-sync setup
        """)
        return nil
    }

    /// Hit /v1/info to check Beeper is running. Returns the base URL on success.
    private static func fetchBeeperInfo(url: String) -> String? {
        guard let infoURL = URL(string: "\(url)/v1/info") else { return nil }
        var request = URLRequest(url: infoURL)
        request.timeoutInterval = 3

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                success = true
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return success ? url : nil
    }

    /// Guide the user through getting and entering their API token.
    /// Returns the validated token, or nil on failure.
    private static func obtainToken(beeperURL: String) -> String? {
        let existingToken = KeychainHelper.loadToken()
        if let existingToken, validateToken(existingToken, beeperURL: beeperURL) {
            print("  A valid Beeper token is already in the Keychain.")
            let replace = prompt("  Replace it? [y/N]: ")
            if replace.lowercased() != "y" {
                return existingToken
            }
        }

        print("""
          To get your API token:
            1. Open Beeper Desktop
            2. Go to Settings → Developers
            3. Next to "Approved connections", click the + button
            4. Copy the token

        """)

        for attempt in 1...3 {
            let token = promptHidden("  Paste your token here: ")
            guard !token.isEmpty else {
                print("  Token cannot be empty.")
                if attempt < 3 { continue }
                return nil
            }
            print("  Validating token...", terminator: "")
            if validateToken(token, beeperURL: beeperURL) {
                print(" OK!")
                return token
            }
            print(" failed.")
            if attempt < 3 {
                print("  That token didn't work. Please try again.")
            } else {
                print("  Token validation failed 3 times. Check that you copied the full token.")
                return nil
            }
        }
        return nil
    }

    /// Validate a token by hitting /v1/accounts.
    private static func validateToken(_ token: String, beeperURL: String) -> Bool {
        guard let url = URL(string: "\(beeperURL)/v1/accounts") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                success = true
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return success
    }

    /// Save token to Keychain, prompting to unlock if needed. Returns true on success.
    private static func saveTokenToKeychain(_ token: String) -> Bool {
        if KeychainHelper.saveToken(token) {
            print("Token saved to Keychain.")
            return true
        }

        // Keychain is locked — unlock it ourselves
        print("\n  The macOS Keychain is locked (common in SSH sessions).")
        let password = promptHidden("  macOS login password to unlock Keychain: ")
        guard !password.isEmpty else {
            print("  Cannot save token without unlocking the Keychain.")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "unlock-keychain",
            "-p", password,
            NSHomeDirectory() + "/Library/Keychains/login.keychain-db",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("  Failed to unlock Keychain: \(error.localizedDescription)")
            return false
        }

        guard process.terminationStatus == 0 else {
            print("  Incorrect password — could not unlock the Keychain.")
            return false
        }

        // Retry the save
        if KeychainHelper.saveToken(token) {
            print("  Keychain unlocked. Token saved to Keychain.")
            return true
        }

        print("  Could not save token to Keychain even after unlocking.")
        return false
    }

    /// Offer to grant Contacts access for iMessage phone number resolution.
    private static func offerContactsAccess() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .authorized {
            return  // already granted
        }

        print("\nStep 5: Contacts access (optional)")
        print("  Allows resolving iMessage phone numbers to contact names.")
        print("  Note: this requires running from a GUI terminal (not SSH).")
        let answer = prompt("  Grant Contacts access now? [Y/n]: ", default: "y")
        guard answer.lowercased() != "n" else { return }

        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        CNContactStore().requestAccess(for: .contacts) { result, _ in
            granted = result
            semaphore.signal()
        }
        let timeout = semaphore.wait(timeout: .now() + 30)

        if timeout == .timedOut {
            print("  Timed out waiting for Contacts prompt.")
            print("  Run `beeper-message-sync grant-contacts` from Terminal.app later.")
        } else if granted {
            print("  Contacts access granted.")
        } else {
            print("  Contacts access denied or unavailable.")
            print("  You can grant it later in System Settings > Privacy & Security > Contacts,")
            print("  or run `beeper-message-sync grant-contacts` from Terminal.app.")
        }
    }

    private static func createDirectoryIfNeeded(_ path: String) {
        let expanded = NSString(string: path).expandingTildeInPath
        if !FileManager.default.fileExists(atPath: expanded) {
            do {
                try FileManager.default.createDirectory(
                    atPath: expanded,
                    withIntermediateDirectories: true
                )
                print("  Created \(expanded)")
            } catch {
                print("  Warning: could not create \(expanded): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Config file

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
