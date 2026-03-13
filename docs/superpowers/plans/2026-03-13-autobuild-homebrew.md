# Auto-Build, Signing & Homebrew Tap Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace .env-based config with JSON config file + Keychain token storage, add interactive setup command, create a GitHub Actions pipeline that builds/signs/notarizes per-arch binaries on tag push, and publish via Homebrew tap.

**Architecture:** Three sequential layers — (1) config/keychain/setup changes to the Swift binary, (2) GitHub Actions release workflow adapted from Clearance's pipeline, (3) Homebrew formula in the existing prime-radiant-inc/homebrew-tap repo. Each layer builds on the previous.

**Tech Stack:** Swift 6.0, SPM, Security.framework (Keychain), GitHub Actions, Apple codesign/notarytool, Homebrew

**Spec:** `docs/superpowers/specs/2026-03-13-autobuild-homebrew-design.md`

---

## Chunk 1: Config File and Keychain Support

### Task 1: KeychainHelper

**Files:**
- Create: `Sources/BeeperMessageSync/KeychainHelper.swift`
- Create: `Tests/BeeperMessageSyncTests/KeychainHelperTests.swift`

- [ ] **Step 1: Write failing tests for KeychainHelper**

Create `Tests/BeeperMessageSyncTests/KeychainHelperTests.swift`:

```swift
import XCTest
@testable import beeper_message_sync

final class KeychainHelperTests: XCTestCase {
    // Use a test-only service name to avoid polluting the real Keychain
    let testService = "com.primeradiant.beeper-message-sync.test"

    override func tearDown() {
        super.tearDown()
        // Clean up any test tokens
        KeychainHelper.deleteToken(service: testService)
    }

    func testSaveAndLoadToken() {
        let saved = KeychainHelper.saveToken("test-token-abc", service: testService)
        XCTAssertTrue(saved)
        let loaded = KeychainHelper.loadToken(service: testService)
        XCTAssertEqual(loaded, "test-token-abc")
    }

    func testLoadTokenReturnsNilWhenEmpty() {
        let loaded = KeychainHelper.loadToken(service: testService)
        XCTAssertNil(loaded)
    }

    func testSaveTokenOverwritesExisting() {
        KeychainHelper.saveToken("first", service: testService)
        KeychainHelper.saveToken("second", service: testService)
        let loaded = KeychainHelper.loadToken(service: testService)
        XCTAssertEqual(loaded, "second")
    }

    func testDeleteToken() {
        KeychainHelper.saveToken("to-delete", service: testService)
        KeychainHelper.deleteToken(service: testService)
        let loaded = KeychainHelper.loadToken(service: testService)
        XCTAssertNil(loaded)
    }

    func testDeleteNonexistentTokenDoesNotCrash() {
        // Should not throw or crash
        KeychainHelper.deleteToken(service: testService)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter KeychainHelperTests 2>&1 | tail -20`
Expected: Compilation error — `KeychainHelper` not defined.

- [ ] **Step 3: Implement KeychainHelper**

Create `Sources/BeeperMessageSync/KeychainHelper.swift`:

```swift
import Foundation
import Security

enum KeychainHelper {
    static let defaultService = "com.primeradiant.beeper-message-sync"
    private static let account = "beeper-token"

    @discardableResult
    static func saveToken(_ token: String, service: String = defaultService) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }

        // Delete any existing item first
        deleteToken(service: service)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func loadToken(service: String = defaultService) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func deleteToken(service: String = defaultService) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter KeychainHelperTests 2>&1 | tail -20`
Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/KeychainHelper.swift Tests/BeeperMessageSyncTests/KeychainHelperTests.swift
git commit -m "Add KeychainHelper for secure token storage"
```

---

### Task 2: Rewrite Config to use JSON file + Keychain + env var layering

**Files:**
- Modify: `Sources/BeeperMessageSync/Config.swift`
- Modify: `Tests/BeeperMessageSyncTests/ConfigTests.swift`

- [ ] **Step 1: Write failing tests for new Config.load()**

Replace the contents of `Tests/BeeperMessageSyncTests/ConfigTests.swift`:

```swift
import XCTest
@testable import beeper_message_sync

final class ConfigTests: XCTestCase {
    let testService = "com.primeradiant.beeper-message-sync.test-config"

    override func tearDown() {
        super.tearDown()
        KeychainHelper.deleteToken(service: testService)
    }

    func testDefaults() {
        // No config file, no env vars, no keychain token
        let config = Config.load(configPath: "/nonexistent/config.json",
                                 keychainService: testService,
                                 environment: [:])
        XCTAssertNil(config.beeperToken)
        XCTAssertEqual(config.beeperURL, "http://localhost:23373")
        XCTAssertEqual(config.pollInterval, 5)
        XCTAssertTrue(config.logDir.hasSuffix("Beeper-Sync/logs"))
        XCTAssertTrue(config.stateFile.hasSuffix("Beeper-Sync/state.json"))
    }

    func testConfigFileOverridesDefaults() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configFile = tmpDir.appendingPathComponent("config.json")
        let json = """
        {
          "beeperURL": "http://custom:8080",
          "logDir": "/tmp/custom-logs",
          "stateFile": "/tmp/custom-state.json",
          "pollInterval": 30
        }
        """
        try json.write(to: configFile, atomically: true, encoding: .utf8)

        let config = Config.load(configPath: configFile.path,
                                 keychainService: testService,
                                 environment: [:])
        XCTAssertEqual(config.beeperURL, "http://custom:8080")
        XCTAssertEqual(config.logDir, "/tmp/custom-logs")
        XCTAssertEqual(config.stateFile, "/tmp/custom-state.json")
        XCTAssertEqual(config.pollInterval, 30)
    }

    func testEnvVarsOverrideConfigFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configFile = tmpDir.appendingPathComponent("config.json")
        try """
        { "beeperURL": "http://from-file:1111", "pollInterval": 10 }
        """.write(to: configFile, atomically: true, encoding: .utf8)

        let env = [
            "BEEPER_URL": "http://from-env:2222",
            "POLL_INTERVAL": "60",
        ]

        let config = Config.load(configPath: configFile.path,
                                 keychainService: testService,
                                 environment: env)
        XCTAssertEqual(config.beeperURL, "http://from-env:2222")
        XCTAssertEqual(config.pollInterval, 60)
    }

    func testKeychainTokenUsedWhenNoEnvVar() {
        KeychainHelper.saveToken("keychain-token", service: testService)

        let config = Config.load(configPath: "/nonexistent",
                                 keychainService: testService,
                                 environment: [:])
        XCTAssertEqual(config.beeperToken, "keychain-token")
    }

    func testEnvVarTokenOverridesKeychain() {
        KeychainHelper.saveToken("keychain-token", service: testService)

        let config = Config.load(configPath: "/nonexistent",
                                 keychainService: testService,
                                 environment: ["BEEPER_TOKEN": "env-token"])
        XCTAssertEqual(config.beeperToken, "env-token")
    }

    func testConfigFileTildeExpansion() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configFile = tmpDir.appendingPathComponent("config.json")
        try """
        { "logDir": "~/CustomLogs", "stateFile": "~/CustomState/state.json" }
        """.write(to: configFile, atomically: true, encoding: .utf8)

        let config = Config.load(configPath: configFile.path,
                                 keychainService: testService,
                                 environment: [:])
        XCTAssertTrue(config.logDir.hasPrefix("/"))
        XCTAssertFalse(config.logDir.contains("~"))
        XCTAssertTrue(config.stateFile.hasPrefix("/"))
        XCTAssertFalse(config.stateFile.contains("~"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ConfigTests 2>&1 | tail -20`
Expected: Compilation error — `Config.load(configPath:keychainService:environment:)` not defined.

- [ ] **Step 3: Rewrite Config.swift**

Replace `Sources/BeeperMessageSync/Config.swift` with:

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ConfigTests 2>&1 | tail -20`
Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/Config.swift Tests/BeeperMessageSyncTests/ConfigTests.swift
git commit -m "Rewrite Config: JSON file + Keychain + env var layering"
```

---

### Task 3: SetupCommand and main.swift integration

**Files:**
- Create: `Sources/BeeperMessageSync/SetupCommand.swift`
- Modify: `Sources/BeeperMessageSync/main.swift`

- [ ] **Step 1: Write failing test for SetupCommand config file writing**

Create `Tests/BeeperMessageSyncTests/SetupCommandTests.swift`:

```swift
import XCTest
@testable import beeper_message_sync

final class SetupCommandTests: XCTestCase {
    let testService = "com.primeradiant.beeper-message-sync.test-setup"

    override func tearDown() {
        super.tearDown()
        KeychainHelper.deleteToken(service: testService)
    }

    func testWriteConfigFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let configPath = tmpDir.appendingPathComponent("config.json").path

        try SetupCommand.writeConfigFile(
            beeperURL: "http://localhost:9999",
            logDir: "~/TestLogs",
            stateFile: "~/TestState/state.json",
            pollInterval: 15,
            to: configPath
        )

        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["beeperURL"] as? String, "http://localhost:9999")
        XCTAssertEqual(json["logDir"] as? String, "~/TestLogs")
        XCTAssertEqual(json["stateFile"] as? String, "~/TestState/state.json")
        XCTAssertEqual(json["pollInterval"] as? Int, 15)
    }

    func testWriteConfigFileCreatesDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("nested/dir")
        defer {
            try? FileManager.default.removeItem(
                at: tmpDir.deletingLastPathComponent().deletingLastPathComponent()
            )
        }

        let configPath = tmpDir.appendingPathComponent("config.json").path
        try SetupCommand.writeConfigFile(
            beeperURL: "http://localhost:23373",
            logDir: "~/Dropbox/Beeper-Sync/logs",
            stateFile: "~/Dropbox/Beeper-Sync/state.json",
            pollInterval: 5,
            to: configPath
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: configPath))
    }

}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SetupCommandTests 2>&1 | tail -20`
Expected: Compilation error — `SetupCommand` not defined.

- [ ] **Step 3: Implement SetupCommand**

Create `Sources/BeeperMessageSync/SetupCommand.swift`:

```swift
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
                saveToken(token)
                print("Token saved to Keychain.")
            }
        } else {
            let token = promptHidden("Beeper token: ")
            guard !token.isEmpty else {
                print("Error: token cannot be empty.")
                return
            }
            saveToken(token)
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

    static func saveToken(_ token: String, service: String = KeychainHelper.defaultService) {
        KeychainHelper.saveToken(token, service: service)
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

        // Disable terminal echo for password input
        var oldTermios = termios()
        tcgetattr(STDIN_FILENO, &oldTermios)
        var newTermios = oldTermios
        newTermios.c_lflag &= ~UInt(ECHO)
        tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)

        let input = readLine() ?? ""

        // Restore terminal echo
        tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
        print() // newline after hidden input

        return input
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SetupCommandTests 2>&1 | tail -20`
Expected: All 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/SetupCommand.swift Tests/BeeperMessageSyncTests/SetupCommandTests.swift
git commit -m "Add SetupCommand for interactive config and Keychain setup"
```

---

### Task 4: Update main.swift to use new Config and setup mode

**Files:**
- Modify: `Sources/BeeperMessageSync/main.swift`

- [ ] **Step 1: Verify no other callers of old Config API**

Run: `grep -rn 'Config(env:\|Config.load(from:\|findEnvFile' Sources/ Tests/`
Expected: Only `main.swift` references `findEnvFile` and `Config.load(from:)`. `ConfigTests.swift`
was already rewritten in Task 2. If any other files reference these, update them too.

- [ ] **Step 2: Update main.swift**

Make these specific changes:

1. Delete lines 14-15 (`let envPath = findEnvFile()` and `let config = Config.load(from: envPath)`)
2. Delete the `findEnvFile()` function (lines 184-192)
3. Add `setup` mode check and new config loading in their place
4. Update the error message and usage text

Note: `parseArgs()` already handles `"setup"` correctly — it treats any non-flag
argument as the mode string, so no changes needed there.

The new top section of `main.swift` becomes:

```swift
import Contacts
import Foundation

setbuf(stdout, nil)

let (mode, filter) = parseArgs()

// Handle modes that don't need a Beeper connection
if mode == "grant-contacts" {
    try await grantContacts()
    exit(0)
}

if mode == "setup" {
    SetupCommand.run()
    exit(0)
}

let config = Config.load()

guard config.beeperToken != nil else {
    print("Error: BEEPER_TOKEN not set. Run `beeper-message-sync setup` to configure.")
    exit(1)
}
```

And update the usage text in the default switch case:

```swift
default:
    print("Usage: beeper-message-sync [watch|backfill|setup|grant-contacts] [options]")
    print("  watch           - Poll for new messages (default). Runs backfill first if no state.")
    print("  backfill        - Full historical backfill, then exit.")
    print("  setup           - Interactive setup wizard (token, paths, config file).")
    print("  grant-contacts  - Request Contacts access (run interactively from Terminal).")
```

Delete `findEnvFile()` (lines 184-192).

- [ ] **Step 3: Run all tests to verify nothing is broken**

Run: `swift test 2>&1 | tail -30`
Expected: All tests pass. No compilation errors. Any tests that referenced `Config(env:)` or `Config.load(from:)` were already updated in Task 2.

- [ ] **Step 4: Build and verify the binary runs**

Run: `swift build -c release 2>&1 | tail -5`
Then: `.build/release/beeper-message-sync --help 2>&1` (should show updated usage with `setup`)

- [ ] **Step 5: Commit**

```bash
git add Sources/BeeperMessageSync/main.swift
git commit -m "Wire up Config.load() and setup command in main.swift"
```

---

## Chunk 2: GitHub Actions Release Pipeline

### Task 5: Create release workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create HOMEBREW_TAP_TOKEN org secret**

The default `GITHUB_TOKEN` is scoped to the current repo and cannot push to
`homebrew-tap`. Create a Personal Access Token (classic) with `repo` scope, or
a fine-grained token with write access to `prime-radiant-inc/homebrew-tap`, and
store it as an org secret:

```bash
# Create the token at https://github.com/settings/tokens/new
# Then store it:
echo -n "<TOKEN_VALUE>" | gh secret set HOMEBREW_TAP_TOKEN --org prime-radiant-inc --visibility all
```

- [ ] **Step 2: Create the workflow file**

Create `.github/workflows/release.yml`:

```yaml
name: Build and Release

on:
  push:
    tags:
      - "v*"

permissions:
  contents: write

jobs:
  release:
    runs-on: macos-latest
    env:
      ARTIFACTS_DIR: ${{ github.workspace }}/dist
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Build arm64
        run: swift build -c release --arch arm64

      - name: Build x86_64
        run: swift build -c release --arch x86_64

      - name: Setup Signing Keychain
        env:
          DEVELOPER_ID_APPLICATION_CERT_BASE64: ${{ secrets.DEVELOPER_ID_APPLICATION_CERT_BASE64 }}
          DEVELOPER_ID_APPLICATION_CERT_PASSWORD: ${{ secrets.DEVELOPER_ID_APPLICATION_CERT_PASSWORD }}
        run: |
          set -euo pipefail

          KEYCHAIN_PATH="$RUNNER_TEMP/build.keychain-db"
          CERT_PATH="$RUNNER_TEMP/developer-id-application.p12"

          echo "$DEVELOPER_ID_APPLICATION_CERT_BASE64" | base64 --decode > "$CERT_PATH"

          security create-keychain -p "$RUNNER_TEMP" "$KEYCHAIN_PATH"
          security default-keychain -s "$KEYCHAIN_PATH"
          security unlock-keychain -p "$RUNNER_TEMP" "$KEYCHAIN_PATH"
          security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
          security import "$CERT_PATH" -k "$KEYCHAIN_PATH" \
            -P "$DEVELOPER_ID_APPLICATION_CERT_PASSWORD" \
            -T /usr/bin/codesign -T /usr/bin/security
          security set-key-partition-list -S apple-tool:,apple: \
            -s -k "$RUNNER_TEMP" "$KEYCHAIN_PATH"

      - name: Codesign Binaries
        env:
          DEVELOPER_ID_APPLICATION_SIGNING_IDENTITY: ${{ secrets.DEVELOPER_ID_APPLICATION_SIGNING_IDENTITY }}
        run: |
          set -euo pipefail
          SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION_SIGNING_IDENTITY"

          codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" \
            .build/arm64-apple-macosx/release/beeper-message-sync

          codesign --force --options runtime --timestamp \
            --sign "$SIGN_IDENTITY" \
            .build/x86_64-apple-macosx/release/beeper-message-sync

          echo "Verifying signatures..."
          codesign -dv --verbose=2 .build/arm64-apple-macosx/release/beeper-message-sync
          codesign -dv --verbose=2 .build/x86_64-apple-macosx/release/beeper-message-sync

      - name: Notarize Binaries
        env:
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_APP_SPECIFIC_PASSWORD: ${{ secrets.APPLE_APP_SPECIFIC_PASSWORD }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
        run: |
          set -euo pipefail

          for ARCH in arm64 x86_64; do
            BINARY=".build/${ARCH}-apple-macosx/release/beeper-message-sync"
            ZIP="$RUNNER_TEMP/beeper-message-sync-${ARCH}-notarize.zip"

            zip -j "$ZIP" "$BINARY"

            echo "Submitting $ARCH binary for notarization..."
            SUBMIT_OUTPUT="$RUNNER_TEMP/notary-${ARCH}.json"
            xcrun notarytool submit "$ZIP" \
              --apple-id "$APPLE_ID" \
              --password "$APPLE_APP_SPECIFIC_PASSWORD" \
              --team-id "$APPLE_TEAM_ID" \
              --wait \
              --output-format json > "$SUBMIT_OUTPUT"

            STATUS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status',''))" "$SUBMIT_OUTPUT")
            if [ "$STATUS" != "Accepted" ]; then
              echo "Notarization failed for $ARCH (status: $STATUS)"
              SUBMISSION_ID=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('id',''))" "$SUBMIT_OUTPUT")
              xcrun notarytool log "$SUBMISSION_ID" \
                --apple-id "$APPLE_ID" \
                --password "$APPLE_APP_SPECIFIC_PASSWORD" \
                --team-id "$APPLE_TEAM_ID" || true
              exit 1
            fi

            echo "$ARCH binary notarized successfully."
          done

      - name: Package Release Artifacts
        run: |
          set -euo pipefail

          VERSION="${GITHUB_REF_NAME#v}"
          mkdir -p "$ARTIFACTS_DIR"

          for ARCH in arm64 x86_64; do
            BINARY=".build/${ARCH}-apple-macosx/release/beeper-message-sync"
            ARTIFACT_NAME="beeper-message-sync-darwin-${ARCH}"

            cp "$BINARY" "$ARTIFACTS_DIR/$ARTIFACT_NAME"
            cd "$ARTIFACTS_DIR"
            tar czf "${ARTIFACT_NAME}.tar.gz" "$ARTIFACT_NAME"
            rm "$ARTIFACT_NAME"
            cd -
          done

          echo "Artifacts:"
          ls -la "$ARTIFACTS_DIR"

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            ${{ env.ARTIFACTS_DIR }}/beeper-message-sync-darwin-arm64.tar.gz
            ${{ env.ARTIFACTS_DIR }}/beeper-message-sync-darwin-x86_64.tar.gz
          generate_release_notes: true

      - name: Update Homebrew Tap
        env:
          GH_TOKEN: ${{ secrets.HOMEBREW_TAP_TOKEN }}
        run: |
          set -euo pipefail

          VERSION="${GITHUB_REF_NAME#v}"
          SHA_ARM64=$(shasum -a 256 "$ARTIFACTS_DIR/beeper-message-sync-darwin-arm64.tar.gz" | awk '{print $1}')
          SHA_X86_64=$(shasum -a 256 "$ARTIFACTS_DIR/beeper-message-sync-darwin-x86_64.tar.gz" | awk '{print $1}')

          cd "$RUNNER_TEMP"
          gh repo clone prime-radiant-inc/homebrew-tap homebrew-tap
          cd homebrew-tap
          gh auth setup-git

          # Rewrite the formula with correct version and shas using Ruby
          # (avoids fragile sed patterns on BSD sed)
          ruby -e '
            formula = File.read("Formula/beeper-message-sync.rb")
            formula.sub!(/version ".*?"/, %Q{version "#{ARGV[0]}"})
            shas = formula.scan(/sha256 ".*?"/)
            formula.sub!(shas[0], %Q{sha256 "#{ARGV[1]}"}) if shas[0]
            formula.sub!(shas[1], %Q{sha256 "#{ARGV[2]}"}) if shas[1]
            File.write("Formula/beeper-message-sync.rb", formula)
          ' "$VERSION" "$SHA_ARM64" "$SHA_X86_64"

          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add "Formula/beeper-message-sync.rb"
          git commit -m "Update beeper-message-sync to $VERSION"
          git push

      - name: Cleanup Keychain
        if: always()
        run: security delete-keychain "$RUNNER_TEMP/build.keychain-db" || true
```

- [ ] **Step 3: Verify YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))" 2>&1`
Expected: No output (valid YAML). If python3 yaml module not available, use: `ruby -ryaml -e "YAML.load_file('.github/workflows/release.yml')"`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "Add GitHub Actions release pipeline: build, sign, notarize"
```

---

## Chunk 3: Homebrew Formula and Test Release

### Task 6: Create initial Homebrew formula

**Files:**
- Create: `Formula/beeper-message-sync.rb` (in homebrew-tap repo, but we push via the release workflow; create the initial version manually)

- [ ] **Step 1: Push the initial formula to homebrew-tap**

The formula needs to exist before the first release can update it. Create it with placeholder values:

```bash
cd /tmp/homebrew-tap

cat > Formula/beeper-message-sync.rb << 'FORMULA'
class BeeperMessageSync < Formula
  desc "Sync Beeper chat history to local JSONL files"
  homepage "https://github.com/prime-radiant-inc/beeper-message-sync"
  version "0.0.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/prime-radiant-inc/beeper-message-sync/releases/download/v#{version}/beeper-message-sync-darwin-arm64.tar.gz"
      sha256 "PLACEHOLDER"
    end
    on_intel do
      url "https://github.com/prime-radiant-inc/beeper-message-sync/releases/download/v#{version}/beeper-message-sync-darwin-x86_64.tar.gz"
      sha256 "PLACEHOLDER"
    end
  end

  def install
    on_macos do
      on_arm do
        bin.install "beeper-message-sync-darwin-arm64" => "beeper-message-sync"
      end
      on_intel do
        bin.install "beeper-message-sync-darwin-x86_64" => "beeper-message-sync"
      end
    end
  end

  service do
    run [opt_bin/"beeper-message-sync", "watch"]
    keep_alive true
    log_path var/"log/beeper-message-sync.log"
    error_log_path var/"log/beeper-message-sync-error.log"
  end

  def caveats
    <<~EOS
      Before starting the service, run the setup wizard:
        beeper-message-sync setup

      Then start the service:
        brew services start beeper-message-sync
    EOS
  end
end
FORMULA

git add Formula/beeper-message-sync.rb
git commit -m "Add beeper-message-sync formula (placeholder for first release)"
git push
```

- [ ] **Step 2: Verify formula was pushed**

Run: `gh api repos/prime-radiant-inc/homebrew-tap/contents/Formula/beeper-message-sync.rb --jq .name`
Expected: `beeper-message-sync.rb`

- [ ] **Step 3: Commit**

No commit needed in beeper-message-sync repo for this task — the commit was in homebrew-tap.

---

### Task 7: Push all changes and do a test release

- [ ] **Step 1: Push all beeper-message-sync changes to GitHub**

```bash
cd /Users/jesse/prime-radiant/beeper-message-sync
git push origin main
```

- [ ] **Step 2: Tag and push a test release**

```bash
git tag v0.1.0
git push origin v0.1.0
```

- [ ] **Step 3: Monitor the release workflow**

Run: `gh run list --limit 1` to find the run, then `gh run watch` to monitor.
Expected: All steps succeed — build, sign, notarize, release, tap update.

- [ ] **Step 4: Verify the release artifacts**

Run: `gh release view v0.1.0`
Expected: Release exists with two tarballs attached.

- [ ] **Step 5: Verify the Homebrew tap was updated**

Run: `gh api repos/prime-radiant-inc/homebrew-tap/commits --jq '.[0].commit.message'`
Expected: "Update beeper-message-sync to 0.1.0"

- [ ] **Step 6: Test Homebrew installation**

```bash
brew tap prime-radiant-inc/tap
brew install beeper-message-sync
beeper-message-sync setup
brew services start beeper-message-sync
brew services stop beeper-message-sync
```

Verify each step works. If Keychain access fails with the signed binary, an entitlements plist may be needed — refer to the "Keychain Entitlement Note" in the spec.

- [ ] **Step 7: Commit any fixes discovered during testing**

If any adjustments are needed, fix them, commit, and potentially tag a v0.1.1 to re-test the pipeline.
