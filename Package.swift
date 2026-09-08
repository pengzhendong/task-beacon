// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TaskBeacon",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TaskBeaconCore", targets: ["TaskBeaconCore"]),
        .executable(name: "taskbeacond", targets: ["taskbeacond"]),
        .executable(name: "taskbeacon", targets: ["taskbeacon"]),
        .executable(name: "taskbeacon-mcp", targets: ["taskbeacon-mcp"]),
        .executable(name: "TaskBeaconMenu", targets: ["TaskBeaconApp"]),
        .executable(name: "taskbeacon-selftest", targets: ["TaskBeaconCoreTests"]),
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"
        ),
        .target(name: "TaskBeaconCore"),
        .executableTarget(name: "taskbeacond", dependencies: ["TaskBeaconCore"]),
        .executableTarget(name: "taskbeacon", dependencies: ["TaskBeaconCore"]),
        .executableTarget(name: "taskbeacon-mcp", dependencies: ["TaskBeaconCore"]),
        .executableTarget(
            name: "TaskBeaconApp",
            dependencies: ["TaskBeaconCore", "Sparkle"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .executableTarget(name: "TaskBeaconCoreTests", dependencies: ["TaskBeaconCore"],
                          path: "Tests/TaskBeaconCoreTests"),
    ]
)
