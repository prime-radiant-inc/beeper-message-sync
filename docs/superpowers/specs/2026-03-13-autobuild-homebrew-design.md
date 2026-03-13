# Auto-Build, Signing, Notarization & Homebrew Tap

## Overview

Add config file support with Keychain-based token storage, an interactive setup
command, a GitHub Actions pipeline that builds/signs/notarizes per-architecture
binaries on tag push, and a Homebrew formula in the prime-radiant-inc/homebrew-tap
for easy installation and service management.

## End-to-End User Experience

```
brew tap prime-radiant-inc/tap
brew install beeper-message-sync
beeper-message-sync setup
brew services start beeper-message-sync
```

## Part 1: Config File, Keychain, and Setup Command

### Config File

Location: `~/.config/beeper-message-sync/config.json`

```json
{
  "beeperURL": "http://localhost:23373",
  "logDir": "~/Dropbox/Beeper-Sync/logs",
  "stateFile": "~/Dropbox/Beeper-Sync/state.json",
  "pollInterval": 5
}
```

The Beeper token is NOT stored in this file. It lives in the macOS Keychain.

### Keychain Storage

- **Service**: `com.primeradiant.beeper-message-sync`
- **Account**: `beeper-token`
- Uses `Security.framework` (`SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`)

### Config Load Order (later wins)

1. Built-in defaults (same as current hardcoded defaults)
2. Config file (`~/.config/beeper-message-sync/config.json`)
3. Environment variables (`BEEPER_TOKEN`, `BEEPER_URL`, `LOG_DIR`, `STATE_FILE`, `POLL_INTERVAL`)

Environment variable override is preserved so advanced users and CI can still use
env vars. The `.env` file loading is removed entirely.

### Setup Command

`beeper-message-sync setup` — interactive, run from Terminal:

1. Prompt for Beeper token (input hidden with terminal echo disabled), store in Keychain
2. Ask for log directory (default: `~/Dropbox/Beeper-Sync/logs`), create if needed
3. Ask for state file path (default: `~/Dropbox/Beeper-Sync/state.json`)
4. Write `~/.config/beeper-message-sync/config.json`
5. Print: "Run `brew services start beeper-message-sync` to start syncing"

If a config file already exists, pre-populate prompts with existing values. If a
token is already in the Keychain, indicate that and ask if the user wants to
replace it.

### Source Changes

**Modified files:**
- `Config.swift` — Replace `.env` loading with JSON config file + Keychain + env
  var layering. Remove `load(from:)` and `findEnvFile()`.
- `main.swift` — Add `setup` mode to the mode switch. Remove `findEnvFile()`.

**New files:**
- `KeychainHelper.swift` — Thin wrapper around Security.framework for
  get/set/delete of the token. Functions: `saveToken(_:)`, `loadToken()`,
  `deleteToken()`.
- `SetupCommand.swift` — Interactive setup flow. Reads stdin for user input,
  writes config file, calls KeychainHelper to store token.

**Removed:**
- `.env` file discovery and parsing logic from `Config.swift` and `main.swift`

### Config.swift Design

```swift
struct Config {
    let beeperToken: String?
    let beeperURL: String
    let logDir: String
    let pollInterval: Int
    let stateFile: String

    static func load() -> Config {
        // 1. Start with defaults
        var token: String? = KeychainHelper.loadToken()
        var url = "http://localhost:23373"
        var logDir = NSHomeDirectory() + "/Dropbox/Beeper-Sync/logs"
        var pollInterval = 5
        var stateFile = NSHomeDirectory() + "/Dropbox/Beeper-Sync/state.json"

        // 2. Override from config file
        let configPath = NSHomeDirectory() + "/.config/beeper-message-sync/config.json"
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let v = json["beeperURL"] as? String { url = v }
            if let v = json["logDir"] as? String { logDir = v.expandingTildeInPath }
            if let v = json["stateFile"] as? String { stateFile = v.expandingTildeInPath }
            if let v = json["pollInterval"] as? Int { pollInterval = v }
        }

        // 3. Override from environment
        let env = ProcessInfo.processInfo.environment
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

## Part 2: GitHub Actions Build/Sign/Notarize Pipeline

### Workflow

File: `.github/workflows/release.yml`
Trigger: Push of tags matching `v*`
Runner: `macos-latest`

### Steps

1. **Checkout** — `actions/checkout@v4`

2. **Build arm64** — `swift build -c release --arch arm64`

3. **Build x86_64** — `swift build -c release --arch x86_64`

4. **Setup signing keychain** — Create temporary keychain, import Developer ID
   Application certificate from `DEVELOPER_ID_APPLICATION_CERT_BASE64` secret.
   Adapted from Clearance's release.yml.

5. **Codesign binaries** — Sign both arch binaries with hardened runtime:
   ```bash
   codesign --force --options runtime --timestamp \
     --sign "${{ secrets.DEVELOPER_ID_APPLICATION_SIGNING_IDENTITY }}" \
     .build/arm64-apple-macosx/release/beeper-message-sync
   codesign --force --options runtime --timestamp \
     --sign "${{ secrets.DEVELOPER_ID_APPLICATION_SIGNING_IDENTITY }}" \
     .build/x86_64-apple-macosx/release/beeper-message-sync
   ```

6. **Notarize** — Zip each binary, submit via `xcrun notarytool submit --wait`.
   Stapling is not possible for bare Mach-O binaries; the notarization ticket
   lives on Apple's servers and macOS checks it on first launch. This is standard
   for CLI tools.

7. **Package release artifacts** — Create tarballs:
   - `beeper-message-sync-darwin-arm64.tar.gz`
   - `beeper-message-sync-darwin-x86_64.tar.gz`

8. **Create GitHub Release** — `softprops/action-gh-release@v2` with both
   tarballs, auto-generated release notes from commits since last tag.

9. **Update Homebrew tap** — Compute sha256 of both tarballs, clone
   `prime-radiant-inc/homebrew-tap`, update formula with new version and shas,
   commit and push.

10. **Cleanup keychain** — Delete temporary keychain.

### Secrets (all org-level, already configured)

- `DEVELOPER_ID_APPLICATION_CERT_BASE64`
- `DEVELOPER_ID_APPLICATION_CERT_PASSWORD`
- `DEVELOPER_ID_APPLICATION_SIGNING_IDENTITY`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`

## Part 3: Homebrew Formula

### Formula

File: `prime-radiant-inc/homebrew-tap/Formula/beeper-message-sync.rb`

```ruby
class BeeperMessageSync < Formula
  desc "Sync Beeper chat history to local JSONL files"
  homepage "https://github.com/prime-radiant-inc/beeper-message-sync"
  version "VERSION"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/prime-radiant-inc/beeper-message-sync/releases/download/v#{version}/beeper-message-sync-darwin-arm64.tar.gz"
      sha256 "SHA256_ARM64"
    end
    on_intel do
      url "https://github.com/prime-radiant-inc/beeper-message-sync/releases/download/v#{version}/beeper-message-sync-darwin-x86_64.tar.gz"
      sha256 "SHA256_X86_64"
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
    error_log_path var/"log/beeper-message-sync.log"
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
```

### Tap Update Automation

The release workflow's step 9 handles automatic formula updates. It:
1. Computes sha256 of both tarballs
2. Clones `prime-radiant-inc/homebrew-tap`
3. Uses sed to update version and sha256 values in the formula
4. Commits and pushes

This means `brew upgrade beeper-message-sync` picks up new releases automatically.

## Testing Strategy

### Part 1 (Config/Keychain/Setup)

- **KeychainHelper**: Unit tests for save/load/delete cycle using a test-only
  Keychain service name to avoid polluting the real Keychain.
- **Config loading**: Test layering — config file values override defaults, env
  vars override config file values, Keychain token is used when no env var.
- **SetupCommand**: Test the config file writing and Keychain storage. Interactive
  prompts are hard to unit test; manual testing covers the interactive flow.

### Part 2 (CI Pipeline)

- Tag a test release (e.g., `v0.0.1-test`) to validate the full pipeline.
- Verify both architecture binaries are signed: `codesign -dv --verbose=4`
- Verify notarization: `spctl --assess --type execute`
- Verify GitHub release has both tarballs attached.

### Part 3 (Homebrew Formula)

- `brew install prime-radiant-inc/tap/beeper-message-sync` on both arm64 and
  x86_64 (or Rosetta).
- `brew services start beeper-message-sync` starts the daemon.
- `brew services stop beeper-message-sync` stops it.
- Verify `beeper-message-sync setup` works after Homebrew install.

## Migration

Existing users who use `.env` files need to run `beeper-message-sync setup` once.
The setup command handles migrating their config. Environment variable overrides
continue to work for any user who prefers them.

The existing `scripts/install.sh` and `com.primeradiant.beeper-message-sync.plist`
become obsolete once the Homebrew formula is in place. They can be removed in a
follow-up.

## Open Questions

None — all decisions have been made during brainstorming.
