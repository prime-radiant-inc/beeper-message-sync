// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "beeper-message-sync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "beeper-message-sync",
            path: "Sources/BeeperMessageSync"
        ),
        .testTarget(
            name: "BeeperMessageSyncTests",
            dependencies: ["beeper-message-sync"],
            path: "Tests/BeeperMessageSyncTests"
        ),
    ]
)
