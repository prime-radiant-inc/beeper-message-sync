// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "beeper-message-sync",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "beeper-message-sync",
            path: "Sources/BeeperMessageSync",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Resources/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "BeeperMessageSyncTests",
            dependencies: ["beeper-message-sync"],
            path: "Tests/BeeperMessageSyncTests"
        ),
    ]
)
